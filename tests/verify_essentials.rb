# verify_essentials.rb -- reproduce the full byte-exact round-trip claim against a
# real Pokemon Essentials install (not redistributed here).
#
#   ruby tests/verify_essentials.rb "/path/to/Pokemon Essentials/Data"
#
# Checks that every Map*.rxdata round-trips load -> IR -> JSON -> rebuild -> dump
# byte-for-byte. Game data stays on your machine; nothing is copied into the repo.
$LOAD_PATH.unshift File.expand_path('../codec', __dir__)
require 'codec'
require 'json'

data = ARGV[0] or abort 'usage: verify_essentials.rb <Essentials Data dir>'
maps = Dir[File.join(data, 'Map[0-9]*.rxdata')].sort
abort "no Map*.rxdata in #{data}" if maps.empty?

pass = 0
fails = []
maps.each do |p|
  raw = File.binread(p)
  begin
    red = Marshal.dump(Codec.ir_to_map(JSON.parse(JSON.generate(Codec.map_to_ir(Marshal.load(raw))))))
    red == raw ? pass += 1 : fails << File.basename(p)
  rescue => e
    fails << "#{File.basename(p)} (#{e.class})"
  end
end

puts "byte-identical: #{pass}/#{maps.size}"
puts "FAILURES:\n  #{fails.join("\n  ")}" unless fails.empty?
exit(fails.empty? ? 0 : 1)
