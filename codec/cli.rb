# cli.rb -- thin command line over the codec. The seed of the M4 tool layer.
#
#   ruby codec/cli.rb to-ir   <map.rxdata>            > map.ir.json
#   ruby codec/cli.rb to-rxdata <map.ir.json> <out.rxdata>
#
# to-ir is byte-faithful round-trippable: to-rxdata(to-ir(x)) == x on the corpus.
require_relative 'codec'
require_relative 'validators'
require_relative 'pbs'
require_relative 'ops'
require 'json'

cmd = ARGV[0]
case cmd
when 'to-ir'
  map = Marshal.load(File.binread(ARGV[1]))
  STDOUT.write(JSON.pretty_generate(Codec.map_to_ir(map)))
when 'to-rxdata'
  ir = JSON.parse(File.read(ARGV[1]))
  File.binwrite(ARGV[2], Marshal.dump(Codec.ir_to_map(ir)))
  warn "wrote #{ARGV[2]}"
when 'dump-tilesets'
  # Export the bits of Tilesets.rxdata the renderer needs, keyed by tileset id.
  arr = Marshal.load(File.binread(ARGV[1]))
  out = {}
  arr.each_with_index do |t, i|
    next if t.nil?
    g = ->(s) { t.instance_variable_get(s) }
    out[i.to_s] = {
      'id'             => g.call(:@id),
      'name'           => g.call(:@name),
      'tileset_name'   => g.call(:@tileset_name),
      'autotile_names' => g.call(:@autotile_names),
      'panorama_name'  => g.call(:@panorama_name)
    }
  end
  STDOUT.write(JSON.pretty_generate(out))
when 'validate'
  # validate <data_dir> <Mapxxx.rxdata>
  data_dir, map_path = ARGV[1], ARGV[2]
  tilesets = Marshal.load(File.binread(File.join(data_dir, 'Tilesets.rxdata')))
  map = Marshal.load(File.binread(map_path))
  map_id = File.basename(map_path)[/Map0*(\d+)\.rxdata/, 1].to_i

  # MapInfos is the authoritative registry of existing map ids (warp existence)
  valid_ids = Marshal.load(File.binread(File.join(data_dir, 'MapInfos.rxdata'))).keys

  # build map_id -> [w,h] from whatever map files are on disk (warp bounds)
  dims = {}
  Dir[File.join(data_dir, 'Map[0-9]*.rxdata')].each do |p|
    id = File.basename(p)[/Map0*(\d+)\.rxdata/, 1].to_i
    m  = Marshal.load(File.binread(p))
    dims[id] = [m.instance_variable_get(:@width), m.instance_variable_get(:@height)]
  end

  tileset = tilesets[map.instance_variable_get(:@tileset_id)]
  pbs_dir = File.join(data_dir, 'PBS')
  pbs     = Dir.exist?(pbs_dir) ? PBS.load(pbs_dir) : nil
  report  = Validators.validate(map, tileset, map_id: map_id,
                                valid_map_ids: valid_ids, map_dims: dims, pbs: pbs)
  STDOUT.write(JSON.pretty_generate(report))
  exit(report['ok'] ? 0 : 1)
when 'validate-pbs'
  # validate-pbs <pbs_dir>  -- map-independent PBS internal-integrity report
  report = Validators.validate_pbs(PBS.load(ARGV[1]))
  STDOUT.write(JSON.pretty_generate(report))
  exit(report['ok'] ? 0 : 1)
when 'snapshot'
  # snapshot <map.rxdata> [Tilesets.rxdata] -- bounded summary, never full tiles
  map = Marshal.load(File.binread(ARGV[1]))
  t   = map.instance_variable_get(:@data)
  tsname = nil
  if ARGV[2] && File.exist?(ARGV[2])
    ts = Marshal.load(File.binread(ARGV[2]))[map.instance_variable_get(:@tileset_id)]
    tsname = ts&.instance_variable_get(:@tileset_name)
  end
  layers = (0...t.zsize).map do |z|
    ids = Hash.new(0)
    (0...t.ysize).each { |y| (0...t.xsize).each { |x| v = t.get(x, y, z); ids[v] += 1 if v != 0 } }
    { 'layer' => z, 'nonempty' => ids.values.sum, 'distinct_ids' => ids.size,
      'top_ids' => ids.sort_by { |_, n| -n }.first(5).map { |id, n| { 'id' => id, 'count' => n } } }
  end
  events = (map.instance_variable_get(:@events) || {}).map do |key, ev|
    pages = ev.instance_variable_get(:@pages) || []
    warps = []
    Validators.each_warp(map) { |k, _pi, p| warps << { 'target_map' => p[1], 'x' => p[2], 'y' => p[3] } if k == key }
    { 'id' => key, 'name' => ev.instance_variable_get(:@name),
      'x' => ev.instance_variable_get(:@x), 'y' => ev.instance_variable_get(:@y),
      'pages' => pages.size, 'warps' => warps }
  end
  STDOUT.write(JSON.pretty_generate({
    'map'        => File.basename(ARGV[1]),
    'dimensions' => [map.instance_variable_get(:@width), map.instance_variable_get(:@height)],
    'tileset_id' => map.instance_variable_get(:@tileset_id),
    'tileset'    => tsname,
    'layers'     => layers,
    'event_count' => events.size,
    'events'     => events
  }))
when 'read'
  # read <map.rxdata> region <x> <y> <w> <h> <layer>
  map = Marshal.load(File.binread(ARGV[1]))
  t   = map.instance_variable_get(:@data)
  if ARGV[2] == 'region'
    x, y, w, h, z = ARGV[3, 5].map(&:to_i)
    rows = (y...(y + h)).map { |yy| (x...(x + w)).map { |xx| t.get(xx, yy, z) } }
    STDOUT.write(JSON.pretty_generate({ 'x' => x, 'y' => y, 'w' => w, 'h' => h, 'layer' => z, 'tiles' => rows }))
  else
    warn 'usage: read <map.rxdata> region <x> <y> <w> <h> <layer>'; exit 2
  end
when 'act'
  # act <map.rxdata> <op.json> <out.rxdata>  (op.json may be a single op or an array)
  map = Marshal.load(File.binread(ARGV[1]))
  ops = JSON.parse(File.read(ARGV[2]))
  ops = [ops] unless ops.is_a?(Array)
  results = ops.map { |o| Ops.apply(map, o) }
  File.binwrite(ARGV[3], Marshal.dump(map))
  STDOUT.write(JSON.pretty_generate({ 'wrote' => ARGV[3], 'applied' => results }))
else
  warn "usage: cli.rb <cmd> ...\n" \
       "  to-ir <map.rxdata> | to-rxdata <ir.json> <out.rxdata>\n" \
       "  dump-tilesets <Tilesets.rxdata> | validate <data_dir> <map.rxdata>\n" \
       "  validate-pbs <pbs_dir>\n" \
       "  snapshot <map.rxdata> [Tilesets.rxdata] | read <map.rxdata> region <x> <y> <w> <h> <layer>\n" \
       "  act <map.rxdata> <op.json> <out.rxdata>"
  exit 2
end
