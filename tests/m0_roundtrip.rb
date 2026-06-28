# m0_roundtrip.rb -- THE GATE.
# For each real map: load -> IR -> JSON string -> IR -> rebuild -> Marshal.dump.
# Assert the handover's M0 acceptance: all non-opaque fields, and the Table tile
# data exactly, must survive. Also report the stronger full-byte-identity result.
$LOAD_PATH.unshift File.expand_path('../codec', __dir__)
require 'codec'
require 'json'

MAPS = Dir[File.expand_path('../sample/Map[0-9][0-9][0-9].rxdata', __dir__)].sort
abort "no corpus maps found" if MAPS.empty?

def tile_equal?(a, b)
  a.dim == b.dim && a.xsize == b.xsize && a.ysize == b.ysize &&
    a.zsize == b.zsize && a.size == b.size && a.data == b.data
end

all_pass = true
MAPS.each do |path|
  raw   = File.binread(path)
  orig  = Marshal.load(raw)

  # full chain incl. a real JSON serialization hop (proves IR is JSON-clean)
  ir    = Codec.map_to_ir(orig)
  json  = JSON.generate(ir)
  ir2   = JSON.parse(json)
  rebuilt = Codec.ir_to_map(ir2)
  redump  = Marshal.dump(rebuilt)

  checks = {}
  # --- non-opaque scalar fields ---
  %i[@width @height @tileset_id @encounter_step].each do |iv|
    checks["scalar #{iv}"] =
      orig.instance_variable_get(iv) == rebuilt.instance_variable_get(iv)
  end
  # --- Table tile data exact ---
  checks['Table exact'] =
    tile_equal?(orig.instance_variable_get(:@data),
                rebuilt.instance_variable_get(:@data))
  # --- events: positions + opaque pages preserved ---
  oev = orig.instance_variable_get(:@events) || {}
  rev = rebuilt.instance_variable_get(:@events) || {}
  ev_ok = (oev.keys.sort == rev.keys.sort)
  oev.each do |id, e|
    r = rev[id]
    ev_ok &&= r &&
      e.instance_variable_get(:@x) == r.instance_variable_get(:@x) &&
      e.instance_variable_get(:@y) == r.instance_variable_get(:@y) &&
      e.instance_variable_get(:@name) == r.instance_variable_get(:@name) &&
      Marshal.dump(e.instance_variable_get(:@pages)) ==
        Marshal.dump(r.instance_variable_get(:@pages))
  end
  checks['events (pos+opaque pages)'] = ev_ok

  # --- full-file byte identity through the IR (hard requirement) ---
  checks['byte-identical-through-IR'] = (redump == raw)
  byte_identical = checks['byte-identical-through-IR']

  map_pass = checks.values.all?
  all_pass &&= map_pass
  json_kb = (json.bytesize / 1024.0).round(1)
  puts "#{File.basename(path)}  [#{map_pass ? 'PASS' : 'FAIL'}]  " \
       "byte-identical-through-IR=#{byte_identical}  IR-JSON=#{json_kb}KB"
  checks.reject { |_, v| v }.each { |k, _| puts "    MISS: #{k}" }
end

puts "\nM0 #{all_pass ? 'PASS -- codec round-trip is lossless on the corpus.' : 'FAIL'}"
exit(all_pass ? 0 : 1)
