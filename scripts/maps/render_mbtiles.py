#!/usr/bin/python3
"""LEXAIR GEO · Renderiza mosaicos raster PNG a MBTiles con Mapnik.

SOLO para la máquina de preparación o un runner de CI: nunca en el servidor
de producción de 8 GB. Usa metamosaicos (8x8) para que las etiquetas no se
corten y renderiza únicamente los que cortan la provincia + margen.
Los mosaicos idénticos (mar, campo vacío) se almacenan una sola vez
(esquema MBTiles map/images con vista `tiles`).

Uso:
  render_mbtiles.py --dsn "host=... dbname=lexair_prep user=..." --land coast.db \
      --style standard --minzoom 6 --maxzoom 15 --out standard.mbtiles
"""
import argparse
import hashlib
import math
import os
import sqlite3
import sys
import time

import mapnik
import psycopg2
from psycopg2.extensions import parse_dsn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lexair_styles import PALETTES, build_xml  # noqa: E402

EARTH = 20037508.342789244
META = 8


def tile_bounds_3857(z, x, y, n=1):
    size = 2 * EARTH / (2 ** z)
    return (-EARTH + x * size, EARTH - (y + n) * size, -EARTH + (x + n) * size, EARTH - y * size)


def open_mbtiles(path, meta, resume=False):
    if resume and os.path.exists(path):
        db = sqlite3.connect(path)
        db.execute("PRAGMA synchronous = OFF")
        db.executemany("INSERT OR REPLACE INTO metadata VALUES (?, ?)", meta.items())
        return db
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.executescript("""
      PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA page_size = 4096;
      CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE images (tile_id TEXT PRIMARY KEY, tile_data BLOB);
      CREATE TABLE map (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_id TEXT);
      CREATE UNIQUE INDEX map_index ON map (zoom_level, tile_column, tile_row);
      CREATE VIEW tiles AS SELECT map.zoom_level, map.tile_column, map.tile_row, images.tile_data
        FROM map JOIN images ON images.tile_id = map.tile_id;
    """)
    db.executemany("INSERT INTO metadata VALUES (?, ?)", meta.items())
    return db


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True, help="cadena libpq de la base de preparación")
    ap.add_argument("--land", required=True, help="land polygons (osmcoastline, SQLite/Spatialite)")
    ap.add_argument("--style", required=True, choices=sorted(PALETTES))
    ap.add_argument("--minzoom", type=int, default=6)
    ap.add_argument("--maxzoom", type=int, default=15)
    ap.add_argument("--clip-sql", default="SELECT ST_Transform(ST_Buffer(geom::geography, 3000)::geometry, 3857) FROM vc_boundary")
    ap.add_argument("--out", required=True)
    ap.add_argument("--resume", action="store_true", help="conservar niveles de zoom ya completos")
    ap.add_argument("--attribution", default="© OpenStreetMap contributors")
    a = ap.parse_args()

    mapnik.register_plugins()
    mapnik.register_fonts("/usr/share/fonts/truetype/dejavu")
    conn = {k: v for k, v in parse_dsn(a.dsn).items() if k in ("host", "port", "dbname", "user", "password")}
    xml = build_xml(a.style, conn, os.path.abspath(a.land))
    m = mapnik.Map(256 * META, 256 * META)
    mapnik.load_map_from_string(m, xml)
    m.buffer_size = 128

    pg = psycopg2.connect(a.dsn)
    cur = pg.cursor()
    clip_cte = f"WITH c AS (SELECT g FROM ({a.clip_sql}) s(g))"
    cur.execute(f"{clip_cte} SELECT ST_XMin(e), ST_YMin(e), ST_XMax(e), ST_YMax(e) "
                "FROM (SELECT ST_Transform(ST_SetSRID(ST_Extent(g)::geometry, 3857), 4326) AS e FROM c) q")
    bounds = cur.fetchone()
    # Polígono de recorte subdividido e indexado: las pruebas de intersección por
    # metamosaico son baratas incluso en z15+.
    cur.execute(f"CREATE TEMP TABLE clip_parts AS SELECT ST_Subdivide(g, 64) AS g FROM ({a.clip_sql}) s(g)")
    cur.execute("CREATE INDEX ON clip_parts USING gist (g); ANALYZE clip_parts")
    db = open_mbtiles(a.out, {
        "name": f"lexair-villa-clara-{a.style}", "format": "png", "type": "baselayer", "version": "1",
        "minzoom": str(a.minzoom), "maxzoom": str(a.maxzoom), "attribution": a.attribution,
        "bounds": ",".join(f"{v:.5f}" for v in bounds),
        "description": "Villa Clara (Cuba). Datos © OpenStreetMap contributors, ODbL 1.0.",
    }, resume=a.resume)

    t0, rendered, stored = time.time(), 0, 0
    for z in range(a.minzoom, a.maxzoom + 1):
        n = min(META, 2 ** z)
        # Un metamosaico n×n en el zoom z es exactamente el mosaico (mx, my) del zoom z - log2(n).
        mz = z - int(math.log2(n))
        span = f"(2 * {EARTH} / 2 ^ {mz})"
        cur.execute(
            f"WITH e AS (SELECT ST_Extent(g) AS b FROM clip_parts) "
            f"SELECT mx, my FROM e, "
            f" generate_series(floor((ST_XMin(e.b) + {EARTH}) / {span})::int,"
            f"                 floor((ST_XMax(e.b) + {EARTH}) / {span})::int) mx,"
            f" generate_series(floor(({EARTH} - ST_YMax(e.b)) / {span})::int,"
            f"                 floor(({EARTH} - ST_YMin(e.b)) / {span})::int) my"
            f" WHERE EXISTS (SELECT 1 FROM clip_parts p WHERE ST_Intersects(p.g, ST_TileEnvelope({mz}, mx, my)))"
            f" ORDER BY 1, 2")
        metas = cur.fetchall()
        have = db.execute("SELECT count(*) FROM map WHERE zoom_level = ?", (z,)).fetchone()[0]
        if a.resume and have >= len(metas) * n * n:
            stored += have
            print(f"z{z}: ya completo ({have} mosaicos), se conserva", flush=True)
            continue
        done_z = 0
        for mx, my in metas:
            m.resize(256 * n, 256 * n)
            x0, y0 = mx * n, my * n
            m.zoom_to_box(mapnik.Box2d(*tile_bounds_3857(z, x0, y0, n)))
            im = mapnik.Image(256 * n, 256 * n)
            mapnik.render(m, im)
            rendered += 1
            rows = []
            for dx in range(n):
                for dy in range(n):
                    data = im.view(dx * 256, dy * 256, 256, 256).tostring("png256:z=9")
                    tid = hashlib.sha1(data).hexdigest()
                    db.execute("INSERT OR IGNORE INTO images VALUES (?, ?)", (tid, data))
                    rows.append((z, x0 + dx, (2 ** z - 1) - (y0 + dy), tid))
            db.executemany("INSERT OR REPLACE INTO map VALUES (?, ?, ?, ?)", rows)
            stored += len(rows)
            done_z += 1
            if done_z % 25 == 0:
                db.commit()
                print(f"  z{z}: {done_z}/{len(metas)} metamosaicos · {time.time() - t0:.0f} s", flush=True)
        db.commit()
        print(f"z{z}: {len(metas)} metamosaicos · {stored} mosaicos acumulados · {time.time() - t0:.0f} s", flush=True)

    uniq = db.execute("SELECT count(*) FROM images").fetchone()[0]
    db.execute("ANALYZE")
    db.commit()
    db.close()
    print(f"OK {a.out}: {stored} mosaicos ({uniq} únicos), {rendered} metamosaicos, {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()
