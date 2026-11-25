-- LEXAIR GEO · estilo flex de osm2pgsql (>= 2.0)
-- Importa SOLO las capas necesarias para el renderizado de mosaicos y el
-- catálogo de geocodificación. Se ejecuta en la máquina de PREPARACIÓN,
-- nunca en el servidor de producción de 8 GB.
-- Datos: © OpenStreetMap contributors, ODbL 1.0.

local srid = 4326
local tables = {}

tables.roads = osm2pgsql.define_way_table('osm_roads', {
  { column = 'highway', type = 'text', not_null = true },
  { column = 'name', type = 'text' },
  { column = 'ref', type = 'text' },
  { column = 'layer', type = 'int' },
  { column = 'geom', type = 'linestring', projection = srid, not_null = true },
})

tables.rail = osm2pgsql.define_way_table('osm_rail', {
  { column = 'railway', type = 'text' },
  { column = 'name', type = 'text' },
  { column = 'geom', type = 'linestring', projection = srid, not_null = true },
})

tables.waterways = osm2pgsql.define_way_table('osm_waterways', {
  { column = 'waterway', type = 'text' },
  { column = 'name', type = 'text' },
  { column = 'geom', type = 'linestring', projection = srid, not_null = true },
})

tables.areas = osm2pgsql.define_area_table('osm_areas', {
  { column = 'kind', type = 'text', not_null = true },
  { column = 'name', type = 'text' },
  { column = 'geom', type = 'geometry', projection = srid, not_null = true },
})

tables.buildings = osm2pgsql.define_area_table('osm_buildings', {
  { column = 'housenumber', type = 'text' },
  { column = 'street', type = 'text' },
  { column = 'geom', type = 'geometry', projection = srid, not_null = true },
})

tables.places = osm2pgsql.define_node_table('osm_places', {
  { column = 'place', type = 'text', not_null = true },
  { column = 'name', type = 'text', not_null = true },
  { column = 'population', type = 'text' },
  { column = 'geom', type = 'point', projection = srid, not_null = true },
})

tables.pois = osm2pgsql.define_table({
  name = 'osm_pois',
  ids = { type = 'any', id_column = 'osm_id', type_column = 'osm_type' },
  columns = {
    { column = 'category', type = 'text', not_null = true },
    { column = 'name', type = 'text', not_null = true },
    { column = 'geom', type = 'point', projection = srid, not_null = true },
  },
})

tables.addresses = osm2pgsql.define_table({
  name = 'osm_addresses',
  ids = { type = 'any', id_column = 'osm_id', type_column = 'osm_type' },
  columns = {
    { column = 'street', type = 'text', not_null = true },
    { column = 'housenumber', type = 'text', not_null = true },
    { column = 'geom', type = 'point', projection = srid, not_null = true },
  },
})

tables.admin = osm2pgsql.define_relation_table('osm_admin', {
  { column = 'admin_level', type = 'int' },
  { column = 'name', type = 'text' },
  { column = 'geom', type = 'multipolygon', projection = srid, not_null = true },
})

local area_kinds = {
  natural = { water = 'water', wood = 'wood', wetland = 'wetland', beach = 'beach', scrub = 'scrub',
              grassland = 'grass', sand = 'beach', mangrove = 'wetland' },
  landuse = { residential = 'residential', industrial = 'industrial', farmland = 'farmland',
              forest = 'wood', meadow = 'grass', grass = 'grass', commercial = 'commercial',
              retail = 'commercial', cemetery = 'cemetery', reservoir = 'water', basin = 'water',
              orchard = 'farmland', military = 'military' },
  leisure = { park = 'park', pitch = 'pitch', stadium = 'pitch', garden = 'park' },
  amenity = { hospital = 'hospital', school = 'school', university = 'school' },
  aeroway = { aerodrome = 'aerodrome' },
}

local poi_keys = { 'amenity', 'shop', 'tourism', 'historic', 'leisure', 'office', 'healthcare' }

local function area_kind(tags)
  for key, map in pairs(area_kinds) do
    local v = tags[key]
    if v and map[v] then return map[v] end
  end
  if tags.waterway == 'riverbank' then return 'water' end
  return nil
end

local function poi_category(tags)
  for _, k in ipairs(poi_keys) do
    if tags[k] then return k .. '=' .. tags[k] end
  end
  return nil
end

function osm2pgsql.process_node(object)
  local t = object.tags
  if t.place and t.name then
    tables.places:insert({ place = t.place, name = t.name, population = t.population,
                           geom = object:as_point() })
  end
  local cat = poi_category(t)
  if cat and t.name then
    tables.pois:insert({ category = cat, name = t.name, geom = object:as_point() })
  end
  if t['addr:street'] and t['addr:housenumber'] then
    tables.addresses:insert({ street = t['addr:street'], housenumber = t['addr:housenumber'],
                              geom = object:as_point() })
  end
end

function osm2pgsql.process_way(object)
  local t = object.tags
  if t.highway and t.area ~= 'yes' then
    tables.roads:insert({ highway = t.highway, name = t.name, ref = t.ref,
                          layer = tonumber(t.layer), geom = object:as_linestring() })
  end
  if t.railway == 'rail' or t.railway == 'narrow_gauge' then
    tables.rail:insert({ railway = t.railway, name = t.name, geom = object:as_linestring() })
  end
  if t.waterway == 'river' or t.waterway == 'stream' or t.waterway == 'canal' then
    tables.waterways:insert({ waterway = t.waterway, name = t.name, geom = object:as_linestring() })
  end
  if object.is_closed then
    local kind = area_kind(t)
    if kind then tables.areas:insert({ kind = kind, name = t.name, geom = object:as_polygon() }) end
    if t.building then
      tables.buildings:insert({ housenumber = t['addr:housenumber'], street = t['addr:street'],
                                geom = object:as_polygon() })
      if t['addr:street'] and t['addr:housenumber'] then
        tables.addresses:insert({ street = t['addr:street'], housenumber = t['addr:housenumber'],
                                  geom = object:as_polygon():centroid() })
      end
    end
    local cat = poi_category(t)
    if cat and t.name then
      tables.pois:insert({ category = cat, name = t.name, geom = object:as_polygon():centroid() })
    end
  end
end

function osm2pgsql.process_relation(object)
  local t = object.tags
  if t.type == 'boundary' and t.boundary == 'administrative' then
    local lvl = tonumber(t.admin_level)
    if lvl and lvl >= 4 and lvl <= 8 then
      tables.admin:insert({ admin_level = lvl, name = t.name, geom = object:as_multipolygon() })
    end
    return
  end
  if t.type == 'multipolygon' then
    local kind = area_kind(t)
    if kind then tables.areas:insert({ kind = kind, name = t.name, geom = object:as_multipolygon() }) end
  end
end
