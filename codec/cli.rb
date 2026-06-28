# cli.rb -- thin command line over the codec. The seed of the M4 tool layer.
#
#   ruby codec/cli.rb to-ir   <map.rxdata>            > map.ir.json
#   ruby codec/cli.rb to-rxdata <map.ir.json> <out.rxdata>
#
# to-ir is byte-faithful round-trippable: to-rxdata(to-ir(x)) == x on the corpus.
require_relative 'codec'
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
else
  warn "usage: cli.rb to-ir <map.rxdata> | to-rxdata <ir.json> <out.rxdata>"
  exit 2
end
