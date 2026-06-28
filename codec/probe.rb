# probe.rb -- inspect one real map and check round-trip fidelity at 3 levels.
#   level 1: Table blob byte-fidelity     (_dump(_load(b)) == b)
#   level 2: whole-file semantic round-trip (load->dump->load deep-equal)
#   level 3: whole-file byte round-trip     (Marshal.dump(load(file)) == file bytes)
require_relative 'rgss'

path = ARGV[0] || File.join(__dir__, '..', 'corpus', 'Map001.rxdata')
raw  = File.binread(path)
map  = Marshal.load(raw)

puts "== #{File.basename(path)} (#{raw.bytesize} bytes) =="
puts "class: #{map.class}"
puts "ivars: #{map.instance_variables.sort.inspect}"
if map.instance_variable_defined?(:@data)
  t = map.instance_variable_get(:@data)
  puts "tiles: Table #{t.xsize}x#{t.ysize}x#{t.zsize} dim=#{t.dim} size=#{t.size} (data len #{t.data.size})"
end
ev = map.instance_variable_get(:@events) rescue nil
puts "events: #{ev.is_a?(Hash) ? ev.size : 'n/a'}"

# ---- level 1: Table blob fidelity ----
if t
  blob = t._dump
  reblob = Table._load(blob)._dump
  orig_t_ok = (reblob == blob)
  puts "\n[L1] Table _dump->_load->_dump stable: #{orig_t_ok}"
end

# ---- level 3: whole-file byte round-trip ----
redump = Marshal.dump(map)
byte_ok = (redump == raw)
puts "[L3] Marshal.dump(load(file)) == original bytes: #{byte_ok} (#{redump.bytesize} vs #{raw.bytesize})"

# ---- level 2: semantic round-trip ----
map2 = Marshal.load(redump)
# Re-dump both through a canonical pass and compare; deep structural equality via
# a second dump is the practical proof the engine loads identical data.
sem_ok = (Marshal.dump(map2) == redump)
puts "[L2] semantic round-trip stable (dump==dump): #{sem_ok}"

unless byte_ok
  # locate first divergence to diagnose whether it's Marshal framing or real data
  n = [redump.bytesize, raw.bytesize].min
  i = 0
  i += 1 while i < n && redump.getbyte(i) == raw.getbyte(i)
  puts "\nfirst byte diff at offset #{i} of #{n}"
  lo = [i - 8, 0].max
  puts "  orig:   #{raw[lo, 24].bytes.map { |b| '%02x' % b }.join(' ')}"
  puts "  redump: #{redump[lo, 24].bytes.map { |b| '%02x' % b }.join(' ')}"
end
