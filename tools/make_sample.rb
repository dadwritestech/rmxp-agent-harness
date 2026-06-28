# make_sample.rb -- generate an ORIGINAL, self-contained RMXP test fixture.
# Produces sample/Tilesets.rxdata, sample/MapInfos.rxdata, sample/Map001.rxdata,
# sample/Map002.rxdata. No game assets: every byte here is synthesized, so the
# fixture is safe to publish and lets the test suite run without an Essentials
# install. Pair with tools/make_sample_png.py for the matching tileset sheet.
$LOAD_PATH.unshift File.expand_path('../codec', __dir__)
require 'rgss'
require 'fileutils'

OUT = File.expand_path('../sample', __dir__)
FileUtils.mkdir_p(OUT)

def tile_table(w, h, layers = 3)
  t = Table.new(w, h, layers)
  t
end

# ---- Tileset (id 1) referencing the generated "Sample" sheet ----
CEIL = 448                                  # ids 384..447 valid (64 tiles, 8x8 sheet)
def build_tileset
  ts = RPG::Tileset.allocate
  set = ->(k, v) { ts.instance_variable_set(k, v) }
  set.call(:@id, 1)
  set.call(:@name, 'Sample')
  set.call(:@tileset_name, 'Sample')
  set.call(:@autotile_names, Array.new(7, ''))
  set.call(:@panorama_name, '')
  set.call(:@panorama_hue, 0)
  set.call(:@fog_name, '')
  set.call(:@fog_hue, 0); set.call(:@fog_opacity, 64); set.call(:@fog_blend_type, 0)
  set.call(:@fog_zoom, 200); set.call(:@fog_sx, 0); set.call(:@fog_sy, 0)
  set.call(:@battleback_name, '')
  passages = Table.new(CEIL); priorities = Table.new(CEIL); terrain = Table.new(CEIL)
  set.call(:@passages, passages)            # all 0 -> all passable (fully walkable map)
  set.call(:@priorities, priorities)
  set.call(:@terrain_tags, terrain)
  [nil, ts]                                 # array index 0 is nil in RMXP
end

# ---- a Map ----
def build_map(id:, w:, h:, fill:, event: nil)
  m = RPG::Map.allocate
  s = ->(k, v) { m.instance_variable_set(k, v) }
  data = tile_table(w, h)
  (0...h).each { |y| (0...w).each { |x| data.set(x, y, 0, fill) } }
  s.call(:@tileset_id, 1)
  s.call(:@width, w); s.call(:@height, h)
  s.call(:@autoplay_bgm, false); s.call(:@bgm, nil)
  s.call(:@autoplay_bgs, false); s.call(:@bgs, nil)
  s.call(:@encounter_list, []); s.call(:@encounter_step, 30)
  s.call(:@data, data)
  events = {}
  if event
    events[event.instance_variable_get(:@id)] = event
  end
  s.call(:@events, events)
  m
end

# ---- a warp event (Transfer Player, code 201) ----
def warp_event(id:, name:, x:, y:, target:, tx:, ty:)
  ev = RPG::Event.allocate
  ev.instance_variable_set(:@id, id)
  ev.instance_variable_set(:@name, name)
  ev.instance_variable_set(:@x, x); ev.instance_variable_set(:@y, y)
  cmd201 = RPG::EventCommand.allocate
  cmd201.instance_variable_set(:@code, 201)
  cmd201.instance_variable_set(:@indent, 0)
  cmd201.instance_variable_set(:@parameters, [0, target, tx, ty, 0, 0])
  term = RPG::EventCommand.allocate
  term.instance_variable_set(:@code, 0)
  term.instance_variable_set(:@indent, 0)
  term.instance_variable_set(:@parameters, [])
  page = RPG::Event::Page.allocate
  page.instance_variable_set(:@list, [cmd201, term])
  ev.instance_variable_set(:@pages, [page])
  ev
end

# ---- MapInfos ----
def map_info(name, order)
  mi = RPG::MapInfo.allocate
  mi.instance_variable_set(:@name, name)
  mi.instance_variable_set(:@parent_id, 0)
  mi.instance_variable_set(:@order, order)
  mi.instance_variable_set(:@expanded, false)
  mi.instance_variable_set(:@scroll_x, 0); mi.instance_variable_set(:@scroll_y, 0)
  mi
end

door = warp_event(id: 1, name: 'Door to House', x: 5, y: 4, target: 2, tx: 2, ty: 6)
map1 = build_map(id: 1, w: 10, h: 8, fill: 384, event: door)
back = warp_event(id: 1, name: 'Exit', x: 2, y: 6, target: 1, tx: 5, ty: 5)
map2 = build_map(id: 2, w: 8, h: 7, fill: 392, event: back)
infos = { 1 => map_info('Sample Town', 1), 2 => map_info('Sample House', 2) }

File.binwrite(File.join(OUT, 'Tilesets.rxdata'), Marshal.dump(build_tileset))
File.binwrite(File.join(OUT, 'MapInfos.rxdata'), Marshal.dump(infos))
File.binwrite(File.join(OUT, 'Map001.rxdata'), Marshal.dump(map1))
File.binwrite(File.join(OUT, 'Map002.rxdata'), Marshal.dump(map2))
puts "wrote sample fixture to #{OUT}: Tilesets, MapInfos, Map001 (10x8), Map002 (8x7)"
