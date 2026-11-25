"""LEXAIR GEO · Estilos cartográficos Mapnik (estándar, oscuro, alto contraste).

Genera el XML de Mapnik a partir de una paleta. Las capas proceden de las
tablas osm_* importadas con osm2pgsql_lexair.lua y de los polígonos de
tierra calculados con osmcoastline a partir del MISMO extracto OSM.
"""
from xml.sax.saxutils import escape

S0 = 559082264.028  # denominador de escala en zoom 0 (256 px, 0.28 mm/px)


def scale(z):
    return S0 / (2 ** z)


PALETTES = {
    "standard": dict(
        sea="#aad3df", land="#f2efe9", farmland="#eef0d5", residential="#e0dfdf", wood="#add19e",
        grass="#cdebb0", park="#c8facc", water="#aad3df", industrial="#ebdbe8", commercial="#f2dad9",
        wetland="#d6e7d2", sand="#f5e9c6", military="#f3d6d6", cemetery="#aacbaf", school="#ffffe5",
        hospital="#f6eeb7", aerodrome="#e9e7e2", building="#d9d0c9", building_line="#c4b6ab",
        motorway="#e892a2", trunk="#f9b29c", primary="#fcd6a4", secondary="#f7fabf", tertiary="#ffffff",
        minor="#ffffff", service="#ffffff", path="#fa8072", casing="#a8a8a8", rail="#707070",
        waterway="#7fb5d1", admin6="#9e7aa6", admin4="#7d4f8a", text="#2b2b2b", halo="#ffffff",
        place_text="#1f1f1f", water_text="#3b6e8f",
    ),
    "dark": dict(
        sea="#17263a", land="#262a31", farmland="#2a3029", residential="#30333a", wood="#23342a",
        grass="#26352a", park="#26392c", water="#1d3550", industrial="#352d38", commercial="#3a3034",
        wetland="#253331", sand="#3a3628", military="#3b2b2b", cemetery="#2c3a30", school="#34342a",
        hospital="#3a3628", aerodrome="#2f3036", building="#3c4049", building_line="#4a4f59",
        motorway="#c98a4b", trunk="#b8834f", primary="#9c7d55", secondary="#7f7a63", tertiary="#5d6270",
        minor="#4d525d", service="#454a54", path="#8a5a55", casing="#14171b", rail="#7c7f86",
        waterway="#2f5f88", admin6="#8d79a8", admin4="#b39ad1", text="#d9dce1", halo="#15181c",
        place_text="#eef0f3", water_text="#7fa8cf",
    ),
    "high_contrast": dict(
        sea="#0047ab", land="#ffffff", farmland="#ffffff", residential="#e6e6e6", wood="#c9e8c0",
        grass="#ffffff", park="#d9f2d0", water="#0047ab", industrial="#e6e6e6", commercial="#e6e6e6",
        wetland="#ffffff", sand="#ffffff", military="#ffffff", cemetery="#ffffff", school="#ffffff",
        hospital="#ffffff", aerodrome="#ffffff", building="#bdbdbd", building_line="#000000",
        motorway="#000000", trunk="#000000", primary="#000000", secondary="#1a1a1a", tertiary="#333333",
        minor="#4d4d4d", service="#666666", path="#8b0000", casing="#000000", rail="#000000",
        waterway="#0047ab", admin6="#b000b0", admin4="#b000b0", text="#000000", halo="#ffffff",
        place_text="#000000", water_text="#00307a",
    ),
}

AREA_KINDS = ["farmland", "residential", "wood", "grass", "park", "industrial", "commercial", "wetland",
              "military", "cemetery", "school", "hospital", "aerodrome", "pitch", "scrub", "beach"]
AREA_COLOR = {"pitch": "park", "scrub": "wood", "beach": "sand"}

# clase -> (zoom mínimo, anchos por zoom 6..18, clave de color, ¿con borde?)
ROADS = [
    ("path", ["footway", "path", "steps", "pedestrian", "bridleway", "corridor"], 15, "path", False),
    ("service", ["service", "track"], 14, "service", True),
    ("minor", ["residential", "unclassified", "living_street", "road"], 13, "minor", True),
    ("tertiary", ["tertiary", "tertiary_link"], 11, "tertiary", True),
    ("secondary", ["secondary", "secondary_link"], 9, "secondary", True),
    ("primary", ["primary", "primary_link"], 8, "primary", True),
    ("trunk", ["trunk", "trunk_link"], 6, "trunk", True),
    ("motorway", ["motorway", "motorway_link"], 6, "motorway", True),
]
WIDTH = {  # ancho del relleno por zoom
    "motorway": {6: 1.2, 8: 1.6, 10: 2.4, 12: 3.5, 13: 5, 14: 7, 15: 9, 16: 12, 17: 16, 18: 20},
    "trunk": {6: 1.0, 8: 1.4, 10: 2.2, 12: 3.2, 13: 4.5, 14: 6.5, 15: 8.5, 16: 11, 17: 15, 18: 19},
    "primary": {8: 1.0, 10: 1.8, 12: 2.8, 13: 4, 14: 6, 15: 8, 16: 10, 17: 14, 18: 18},
    "secondary": {9: 0.8, 10: 1.4, 12: 2.4, 13: 3.5, 14: 5.5, 15: 7.5, 16: 9.5, 17: 13, 18: 17},
    "tertiary": {11: 0.8, 12: 1.6, 13: 2.6, 14: 4.5, 15: 6.5, 16: 8.5, 17: 12, 18: 16},
    "minor": {13: 1.2, 14: 2.6, 15: 4.5, 16: 6.5, 17: 10, 18: 14},
    "service": {14: 1.0, 15: 1.8, 16: 3, 17: 5, 18: 7},
    "path": {15: 0.8, 16: 1.0, 17: 1.4, 18: 1.8},
}

FONT = "DejaVu Sans Book"
FONT_BOLD = "DejaVu Sans Bold"


def _width(cls, z):
    table = WIDTH[cls]
    keys = sorted(k for k in table if k <= z)
    return table[keys[-1]] if keys else None


def _zrule(z, body, flt=None):
    lo = scale(z) / 1.4142
    hi = scale(z) * 1.4142
    f = f"<Filter>{escape(flt)}</Filter>" if flt else ""
    return (f"<Rule>{f}<MaxScaleDenominator>{hi:.1f}</MaxScaleDenominator>"
            f"<MinScaleDenominator>{lo:.1f}</MinScaleDenominator>{body}</Rule>")


def _minzoom_rule(zmin, body, flt=None, zmax=None):
    f = f"<Filter>{escape(flt)}</Filter>" if flt else ""
    mx = f"<MaxScaleDenominator>{scale(zmin) * 1.4142:.1f}</MaxScaleDenominator>"
    mn = f"<MinScaleDenominator>{scale(zmax) / 1.4142:.1f}</MinScaleDenominator>" if zmax else ""
    return f"<Rule>{f}{mx}{mn}{body}</Rule>"


def _pg(conn, sql, geom="geom"):
    params = "".join(f'<Parameter name="{k}">{escape(str(v))}</Parameter>' for k, v in conn.items())
    return (f'<Datasource><Parameter name="type">postgis</Parameter>{params}'
            f'<Parameter name="table">({escape(sql)}) AS t</Parameter>'
            f'<Parameter name="geometry_field">{geom}</Parameter><Parameter name="srid">3857</Parameter>'
            f'<Parameter name="extent">-9000000,2400000,-8700000,2700000</Parameter>'
            f'<Parameter name="estimate_extent">false</Parameter></Datasource>')


def _q(table, cols, where="true"):
    return (f"SELECT ST_Transform(geom, 3857) AS geom, {cols} FROM {table} "
            f"WHERE geom && ST_Transform(!bbox!, 4326) AND ({where})")


def build_xml(style_id, conn, land_db):
    p = PALETTES[style_id]
    styles, layers = [], []

    def layer(name, style_names, ds):
        st = "".join(f"<StyleName>{s}</StyleName>" for s in style_names)
        layers.append(f'<Layer name="{name}" srs="epsg:3857">{st}{ds}</Layer>')

    # Tierra (osmcoastline) sobre fondo de mar.
    styles.append(f'<Style name="land"><Rule><PolygonSymbolizer fill="{p["land"]}"/></Rule></Style>')
    layers.append(
        '<Layer name="land" srs="epsg:4326"><StyleName>land</StyleName>'
        f'<Datasource><Parameter name="type">sqlite</Parameter><Parameter name="file">{escape(land_db)}</Parameter>'
        '<Parameter name="table">land_polygons</Parameter><Parameter name="geometry_field">GEOMETRY</Parameter>'
        '<Parameter name="wkb_format">spatialite</Parameter><Parameter name="use_spatial_index">true</Parameter>'
        '</Datasource></Layer>')

    rules = []
    for kind in AREA_KINDS:
        color = p[AREA_COLOR.get(kind, kind)]
        zmin = 10 if kind in ("farmland", "wood", "wetland", "military", "aerodrome", "residential") else 12
        rules.append(_minzoom_rule(zmin, f'<PolygonSymbolizer fill="{color}"/>', f"[kind] = '{kind}'"))
    rules.append(_minzoom_rule(6, f'<PolygonSymbolizer fill="{p["water"]}"/>', "[kind] = 'water'"))
    styles.append(f'<Style name="areas">{"".join(rules)}</Style>')
    layer("areas", ["areas"], _pg(conn, _q("osm_areas", "kind, ST_Area(geom) AS a") + " ORDER BY a DESC"))

    styles.append(
        '<Style name="waterways">'
        + _minzoom_rule(10, f'<LineSymbolizer stroke="{p["waterway"]}" stroke-width="1.6"/>', "[waterway] = 'river'")
        + _minzoom_rule(13, f'<LineSymbolizer stroke="{p["waterway"]}" stroke-width="1"/>', "[waterway] != 'river'")
        + "</Style>")
    layer("waterways", ["waterways"], _pg(conn, _q("osm_waterways", "waterway")))

    bsym = (f'<PolygonSymbolizer fill="{p["building"]}"/>'
            f'<LineSymbolizer stroke="{p["building_line"]}" stroke-width="0.5"/>')
    styles.append(f'<Style name="buildings">{_minzoom_rule(15, bsym)}</Style>')
    layer("buildings", ["buildings"], _pg(conn, _q("osm_buildings", "1 AS b")))

    styles.append(
        '<Style name="admin">'
        + _minzoom_rule(9, f'<LineSymbolizer stroke="{p["admin6"]}" stroke-width="1" stroke-dasharray="6,3" '
                           'stroke-opacity="0.8"/>', "[admin_level] = 6")
        + _minzoom_rule(6, f'<LineSymbolizer stroke="{p["admin4"]}" stroke-width="2" stroke-dasharray="8,3,2,3" '
                           'stroke-opacity="0.8"/>', "[admin_level] = 4")
        + "</Style>")
    layer("admin", ["admin"], _pg(conn, "SELECT ST_Transform(ST_Boundary(geom), 3857) AS geom, admin_level FROM osm_admin "
                                        "WHERE admin_level IN (4, 6) AND geom && ST_Transform(!bbox!, 4326)"))

    rsym = f'<LineSymbolizer stroke="{p["rail"]}" stroke-width="1.2" stroke-dasharray="5,3"/>'
    styles.append(f'<Style name="rail">{_minzoom_rule(10, rsym)}</Style>')
    layer("rail", ["rail"], _pg(conn, _q("osm_rail", "1 AS r")))

    casing, fill = [], []
    for cls, highways, zmin, ckey, has_casing in ROADS:
        flt = "[cls] = '" + cls + "'"
        for z in range(zmin, 19):
            w = _width(cls, z)
            if w is None:
                continue
            dash = ' stroke-dasharray="2,2"' if cls == "path" else ""
            fill.append(_zrule(z, f'<LineSymbolizer stroke="{p[ckey]}" stroke-width="{w}"{dash} '
                                  'stroke-linecap="round" stroke-linejoin="round"/>', flt))
            if has_casing and z >= 12:
                casing.append(_zrule(z, f'<LineSymbolizer stroke="{p["casing"]}" stroke-width="{w + 1.5}" '
                                        'stroke-linecap="round" stroke-linejoin="round"/>', flt))
    styles.append(f'<Style name="road_casing">{"".join(casing)}</Style>')
    styles.append(f'<Style name="road_fill">{"".join(fill)}</Style>')
    case = " ".join(f"WHEN highway IN ({', '.join(repr(h) for h in hw)}) THEN '{c}'" for c, hw, *_ in ROADS)
    order = " ".join(f"WHEN '{c}' THEN {i}" for i, (c, *_r) in enumerate(ROADS))
    road_sql = (f"SELECT * FROM (SELECT ST_Transform(geom, 3857) AS geom, name, CASE {case} END AS cls "
                f"FROM osm_roads WHERE geom && ST_Transform(!bbox!, 4326)) r WHERE cls IS NOT NULL "
                f"ORDER BY CASE cls {order} END")
    layer("road_casing", ["road_casing"], _pg(conn, road_sql))
    layer("road_fill", ["road_fill"], _pg(conn, road_sql))

    text = (f'face-name="{FONT}" fill="{p["text"]}" halo-fill="{p["halo"]}" halo-radius="1.5"')
    styles.append(
        '<Style name="road_labels">'
        + _minzoom_rule(15, f'<TextSymbolizer {text} size="10" placement="line" spacing="300" '
                            'max-char-angle-delta="30">[name]</TextSymbolizer>', "[name] != ''")
        + "</Style>")
    layer("road_labels", ["road_labels"], _pg(conn, road_sql.replace("cls IS NOT NULL", "cls IS NOT NULL AND name IS NOT NULL")))

    ptext = f'fill="{p["place_text"]}" halo-fill="{p["halo"]}" halo-radius="2" wrap-width="80"'
    place_rules = [
        (8, "city", FONT_BOLD, 15), (10, "town", FONT_BOLD, 12), (12, "village", FONT, 11),
        (13, "suburb", FONT, 11), (14, "hamlet", FONT, 10), (15, "neighbourhood", FONT, 10),
    ]
    rules = "".join(_minzoom_rule(z, f'<TextSymbolizer face-name="{f}" size="{s}" {ptext}>[name]</TextSymbolizer>',
                                  f"[place] = '{pl}'") for z, pl, f, s in place_rules)
    styles.append(f'<Style name="places">{rules}</Style>')
    layer("places", ["places"], _pg(conn, _q("osm_places", "place, name",
                                             "name IS NOT NULL AND place IN ('city','town','village','suburb',"
                                             "'hamlet','neighbourhood')")
                                    + " ORDER BY CASE place WHEN 'city' THEN 0 WHEN 'town' THEN 1 ELSE 2 END"))

    return ('<?xml version="1.0" encoding="utf-8"?>'
            f'<Map srs="epsg:3857" background-color="{p["sea"]}">'
            + "".join(styles) + "".join(layers) + "</Map>")
