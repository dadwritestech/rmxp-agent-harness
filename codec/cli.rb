# cli.rb -- thin command line over the codec. The seed of the M4 tool layer.
#
#   ruby codec/cli.rb to-ir   <map.rxdata>            > map.ir.json
#   ruby codec/cli.rb to-rxdata <map.ir.json> <out.rxdata>
#
# to-ir is byte-faithful round-trippable: to-rxdata(to-ir(x)) == x on the corpus.
require_relative 'codec'
require_relative 'validators'
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
  report  = Validators.validate(map, tileset, map_id: map_id,
                                valid_map_ids: valid_ids, map_dims: dims)
  STDOUT.write(JSON.pretty_generate(report))
  exit(report['ok'] ? 0 : 1)
else
  warn "usage: cli.rb to-ir <map.rxdata> | to-rxdata <ir.json> <out.rxdata> | " \
       "dump-tilesets <Tilesets.rxdata> | validate <data_dir> <map.rxdata>"
  exit 2
end
