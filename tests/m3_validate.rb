# m3_validate.rb -- M3 acceptance.
#   Part A: known-good corpus maps raise no ERROR (clean).
#   Part B: a deliberately broken map raises exactly the expected codes.
$LOAD_PATH.unshift File.expand_path('../codec', __dir__)
require 'codec'
require 'validators'

DATA = File.expand_path('../corpus', __dir__)
TILESETS  = Marshal.load(File.binread(File.join(DATA, 'Tilesets.rxdata')))
VALID_IDS = Marshal.load(File.binread(File.join(DATA, 'MapInfos.rxdata'))).keys
DIMS = {}
Dir[File.join(DATA, 'Map[0-9]*.rxdata')].each do |p|
  id = File.basename(p)[/Map0*(\d+)\.rxdata/, 1].to_i
  m  = Marshal.load(File.binread(p))
  DIMS[id] = [m.instance_variable_get(:@width), m.instance_variable_get(:@height)]
end

def validate(map, id)
  ts = TILESETS[map.instance_variable_get(:@tileset_id)]
  Validators.validate(map, ts, map_id: id, valid_map_ids: VALID_IDS, map_dims: DIMS)
end

fails = []

# ---- Part A: known-good ----
%w[Map001 Map003 Map007 Map013].each do |name|
  id  = name[/\d+/].to_i
  rep = validate(Marshal.load(File.binread(File.join(DATA, "#{name}.rxdata"))), id)
  errs = rep['issues'].select { |i| i['severity'] == 'ERROR' }
  if errs.empty?
    puts "A #{name}  [PASS] clean (info=#{rep['counts']['INFO'] || 0})"
  else
    fails << "#{name} should be clean but raised #{errs.map { |e| e['code'] }}"
    puts "A #{name}  [FAIL] #{errs.map { |e| e['code'] }}"
  end
end

# ---- Part B: deliberately broken (deep copy of Map007, then sabotage) ----
broken = Marshal.load(Marshal.dump(Marshal.load(File.binread(File.join(DATA, 'Map007.rxdata')))))
broken.instance_variable_get(:@data).data[0] = 99_999          # TILE_RANGE
broken.instance_variable_set(:@width, broken.instance_variable_get(:@width) + 3)  # TABLE_DIMS
first_ev = broken.instance_variable_get(:@events).values.first
first_ev.instance_variable_set(:@x, 9_999)                     # EVENT_OOB
# inject two Transfer Player (201) commands into an event page
page = first_ev.instance_variable_get(:@pages).first
mk = lambda do |mapid, x, y|
  c = RPG::EventCommand.allocate
  c.instance_variable_set(:@code, 201)
  c.instance_variable_set(:@indent, 0)
  c.instance_variable_set(:@parameters, [0, mapid, x, y, 0, 0])
  c
end
list = page.instance_variable_get(:@list)
list.unshift(mk.call(9_999, 1, 1))   # WARP_TARGET_MISSING (map 9999 not in registry)
list.unshift(mk.call(1, 999, 999))   # WARP_OOB (map 1 exists, coords outside)

rep = validate(broken, 7)
got = rep['issues'].map { |i| i['code'] }.uniq.sort
want = %w[EVENT_OOB TABLE_DIMS TILE_RANGE WARP_OOB WARP_TARGET_MISSING]
missing = want - got
extra_unexpected = got - want - %w[REACH_ISOLATED]
if missing.empty? && extra_unexpected.empty? && rep['ok'] == false
  puts "B broken-map  [PASS] flagged #{got.inspect}"
else
  fails << "broken map: missing=#{missing} unexpected=#{extra_unexpected} ok=#{rep['ok']}"
  puts "B broken-map  [FAIL] got #{got.inspect} missing #{missing.inspect}"
end

puts "\nM3 #{fails.empty? ? 'PASS -- clean maps clean, broken map flagged with correct codes.' : 'FAIL'}"
fails.each { |f| puts "  - #{f}" }
exit(fails.empty? ? 0 : 1)
