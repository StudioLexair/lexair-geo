#!/usr/bin/env python3
"""Carga el límite administrativo OSM real de Villa Clara para el render.

Solo se ejecuta en CI/preparación. Rechaza límites incompletos o fuera de
la provincia; nunca sustituye el límite por un rectángulo inventado.
"""
import json
import sys

import psycopg2


def main():
    with open(sys.argv[1], encoding="utf-8") as source:
        collection = json.load(source)
    matches = [f for f in collection["features"]
               if f.get("properties", {}).get("name") == "Villa Clara"
               and str(f.get("properties", {}).get("admin_level")) == "4"
               and f.get("geometry", {}).get("type") in ("Polygon", "MultiPolygon")]
    if len(matches) != 1:
        raise RuntimeError(f"Se esperaba un límite provincial real; encontrados: {len(matches)}")
    with psycopg2.connect(sys.argv[2]) as conn, conn.cursor() as cur:
        cur.execute("CREATE TABLE vc_boundary (geom geometry(MultiPolygon, 4326) NOT NULL)")
        cur.execute("""INSERT INTO vc_boundary (geom)
            SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)), 3))""",
                    (json.dumps(matches[0]["geometry"]),))
        cur.execute("""SELECT ST_IsValid(geom), ST_IsEmpty(geom),
            ST_XMin(geom), ST_YMin(geom), ST_XMax(geom), ST_YMax(geom) FROM vc_boundary""")
        valid, empty, west, south, east, north = cur.fetchone()
        if not valid or empty or not (-81.2 < west < -80 and 21 < south < 22.5
                                      and -79.5 < east < -78 and 22.5 < north < 24):
            raise RuntimeError("Límite provincial inválido o fuera de la zona esperada")
        print(f"Límite OSM cargado: {west:.4f}, {south:.4f}, {east:.4f}, {north:.4f}")


if __name__ == "__main__":
    main()
