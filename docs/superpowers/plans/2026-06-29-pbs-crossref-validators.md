# PBS Cross-Ref Validators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the M3 V-surface by validating a map's wild-encounter table against the Essentials PBS data, plus a separate map-independent PBS internal-integrity check.

**Architecture:** A new read-only `codec/pbs.rb` loader parses the Essentials v21.1 PBS text files (`pokemon/moves/abilities/types/encounters.txt`) into plain Ruby hashes. `codec/validators.rb` gains an encounter cross-ref folded into the per-map `validate()` (via an optional `pbs:` arg) and a standalone `validate_pbs(pbs)` graph check. The CLI auto-loads PBS when `<data_dir>/PBS/` exists and gains a `validate-pbs` verb; a Pi tool and the synthetic test fixture follow the existing patterns.

**Tech Stack:** Ruby 3.3 (codec + validators + tests), TypeScript (Pi extension), the repo's integration-test-script convention (a `.rb` that prints `PASS/FAIL` and sets exit code).

---

## File Structure

- Create: `codec/pbs.rb` — read-only PBS loader + v21.1 constants (`ENCOUNTER_TYPES`, `MAX_LEVEL`). One responsibility: turn PBS text into hashes.
- Modify: `codec/validators.rb` — add `warn` helper, `check_encounters`, `validate_pbs`; wire `pbs:` into `validate()`.
- Modify: `codec/cli.rb` — auto-load PBS in `validate`; add `validate-pbs` verb; update usage text.
- Modify: `tools/make_sample.rb` — emit a synthetic `sample/PBS/` (all-original species/moves/abilities/types + an encounters table for the sample maps).
- Modify: `tests/m3_validate.rb` — add Part C (encounter cross-ref: clean passes, sabotaged flags the right codes).
- Create: `tests/m3_pbs.rb` — `validate_pbs` acceptance (clean synthetic PBS passes; seeded dangling refs flag the right codes).
- Modify: `.pi/extensions/rmxp.ts` — add `rmxp_validate_pbs` tool; note encounter pickup in `rmxp_validate` description.
- Modify: `docs/SKILL.md`, `docs/writeup.md` — document the new verb/tool; flip the "PBS cross-refs" line from stubbed to shipped.

Conventions to match (from the existing code): module functions with `issue = {'code','severity','detail'}`, `err/info` helpers returning string-keyed hashes, validators never mutate, graceful degradation when a registry is absent (mirrors `valid_map_ids`/`map_dims`).

---

## Task 1: Synthetic PBS fixture

Generate the fixture FIRST so every later task can load real files. The fixture is all-original (no real Pokemon names), matching the "every byte synthesized" discipline that replaced the copyrighted corpus. It must be internally consistent so `validate_pbs` passes clean, and map 1 must have a valid encounter table.

**Files:**
- Modify: `tools/make_sample.rb` (append a PBS emitter + call it)

- [ ] **Step 1: Append the PBS emitter to `tools/make_sample.rb`**

Add this before the final `puts` line:

```ruby
# ---- synthetic PBS (original data; validators target Essentials v21.1 format) ----
def write_pbs(out)
  pbs = File.join(out, 'PBS')
  FileUtils.mkdir_p(pbs)

  File.write(File.join(pbs, 'types.txt'), <<~TXT)
    # Synthetic types for the harness test fixture.
    #-------------------------------
    [FLORA]
    Name = Flora
    Weaknesses = EMBER
    #-------------------------------
    [EMBER]
    Name = Ember
    Resistances = FLORA
    #-------------------------------
    [STONE]
    Name = Stone
  TXT

  File.write(File.join(pbs, 'abilities.txt'), <<~TXT)
    # Synthetic abilities.
    #-------------------------------
    [GUTSY]
    Name = Gutsy
    Description = A spirited ability.
    #-------------------------------
    [STONESKIN]
    Name = Stoneskin
    Description = Tough as rock.
  TXT

  File.write(File.join(pbs, 'moves.txt'), <<~TXT)
    # Synthetic moves.
    #-------------------------------
    [BONK]
    Name = Bonk
    Type = STONE
    Category = Physical
    Power = 40
    #-------------------------------
    [SCORCH]
    Name = Scorch
    Type = EMBER
    Category = Special
    Power = 50
    #-------------------------------
    [SPROUT]
    Name = Sprout
    Type = FLORA
    Category = Status
  TXT

  File.write(File.join(pbs, 'pokemon.txt'), <<~TXT)
    # Synthetic species.
    #-------------------------------
    [FOOMON]
    Name = Foomon
    Types = FLORA
    Abilities = GUTSY
    Moves = 1,SPROUT,5,BONK
    TutorMoves = SCORCH
    Evolutions = BARMON,Level,16
    #-------------------------------
    [BARMON]
    Name = Barmon
    Types = FLORA,EMBER
    Abilities = GUTSY
    HiddenAbilities = STONESKIN
    Moves = 1,SPROUT,5,SCORCH
    EggMoves = BONK
  TXT

  # map 1 (Sample Town) gets a wild table; map 2 (interior) has none.
  File.write(File.join(pbs, 'encounters.txt'), <<~TXT)
    # Synthetic encounters keyed by map id.
    #-------------------------------
    [001] # Sample Town
    Land,21
        60,FOOMON,3,6
        40,BARMON,4,7
  TXT
end
write_pbs(OUT)
```

- [ ] **Step 2: Update the final `puts` line to mention PBS**

Replace:

```ruby
puts "wrote sample fixture to #{OUT}: Tilesets, MapInfos, Map001 (10x8), Map002 (8x7)"
```

with:

```ruby
puts "wrote sample fixture to #{OUT}: Tilesets, MapInfos, Map001 (10x8), Map002 (8x7), PBS/"
```

- [ ] **Step 3: Regenerate the fixture**

Run: `"$RMXP_RUBY" tools/make_sample.rb` (where `RMXP_RUBY=C:/Ruby33-x64/bin/ruby.exe`)
Expected stdout ends with `..., PBS/`

- [ ] **Step 4: Verify the files exist**

Run: `ls sample/PBS/`
Expected: `abilities.txt  encounters.txt  moves.txt  pokemon.txt  types.txt`

- [ ] **Step 5: Commit**

```bash
git add tools/make_sample.rb sample/PBS/
git commit -m "Test fixture: synthetic PBS (species/moves/abilities/types/encounters)"
```

---

## Task 2: PBS loader (`codec/pbs.rb`)

Read-only loader. Parses only validator-relevant fields; missing files yield empty tables.

**Files:**
- Create: `codec/pbs.rb`
- Test: inline in `tests/m3_pbs.rb` Step is in Task 4; here we smoke-test from the shell.

- [ ] **Step 1: Write `codec/pbs.rb`**

```ruby
# pbs.rb -- read-only loader for Pokemon Essentials v21.1 PBS text files, plus
# the version-specific constants the cross-ref validators need. This is NOT a
# round-trip codec: it parses only the fields the validators check and ignores
# the rest. A missing file yields an empty table so checks degrade gracefully.
require 'set'

module PBS
  module_function

  # Verified against Essentials v21.1 compiled Data/Scripts.rxdata
  # (GameData::EncounterType registrations). v21.1 has NO per-type slot count;
  # encounter lists are arbitrary-length weighted lists, so we only validate the
  # type name, not a slot count.
  ENCOUNTER_TYPES = %w[
    Land LandDay LandNight LandMorning LandAfternoon LandEvening PokeRadar
    Cave CaveDay CaveNight CaveMorning CaveAfternoon CaveEvening
    Water WaterDay WaterNight WaterMorning WaterAfternoon WaterEvening
    RockSmash BugContest
  ].to_set
  MAX_LEVEL = 100   # Settings::MAXIMUM_LEVEL in v21.1

  def load(dir)
    {
      species:    parse_species(File.join(dir, 'pokemon.txt')),
      moves:      parse_moves(File.join(dir, 'moves.txt')),
      abilities:  parse_existence(File.join(dir, 'abilities.txt')),
      types:      parse_types(File.join(dir, 'types.txt')),
      encounters: parse_encounters(File.join(dir, 'encounters.txt'))
    }
  end

  # Generic [ID]/Key=Value block reader -> { id => { 'Key' => 'raw value' } }.
  # [ID] or [ID,form] both key on ID (form variants share the base id here).
  def parse_blocks(path)
    out = {}
    cur = nil
    return out unless File.exist?(path)
    File.foreach(path, encoding: 'bom|utf-8') do |line|
      line = line.rstrip
      next if line.empty? || line.start_with?('#')
      if (m = line.match(/\A\[(.+?)\]/))
        cur = m[1].split(',').first.strip
        out[cur] = {}
      elsif cur && (m = line.match(/\A\s*(\w+)\s*=\s*(.*)\z/))
        out[cur][m[1]] = m[2].strip
      end
    end
    out
  end

  def split_list(s)
    return [] if s.nil? || s.empty?
    s.split(',').map(&:strip).reject(&:empty?)
  end

  def parse_existence(path)
    parse_blocks(path).keys.each_with_object({}) { |k, h| h[k] = {} }
  end

  def parse_types(path)
    parse_blocks(path).transform_values do |f|
      { weaknesses:  split_list(f['Weaknesses']),
        resistances: split_list(f['Resistances']),
        immunities:  split_list(f['Immunities']) }
    end
  end

  def parse_moves(path)
    parse_blocks(path).transform_values { |f| { type: f['Type'] } }
  end

  def parse_species(path)
    parse_blocks(path).transform_values do |f|
      # Moves is "level,MOVE,level,MOVE,..." -> take every move name
      level_moves = split_list(f['Moves'])
      moves = level_moves.each_slice(2).map { |_lvl, mv| mv }.compact
      # Evolutions is "SPECIES,Method,Param,..." triples -> take species names
      evolutions = split_list(f['Evolutions']).each_slice(3).map { |sp, _m, _p| sp }.compact
      { types:      split_list(f['Types']),
        abilities:  split_list(f['Abilities']),
        hidden:     split_list(f['HiddenAbilities']),
        moves:      moves,
        tutor:      split_list(f['TutorMoves']),
        egg:        split_list(f['EggMoves']),
        evolutions: evolutions }
    end
  end

  # encounters.txt: [mapID] / [mapID,version] -> "Type[,step_chance]" headers ->
  # indented "prob,SPECIES,min[,max]" slot lines. Returns { map_id => [section] }.
  def parse_encounters(path)
    out = {}
    return out unless File.exist?(path)
    map_id = nil
    sec = nil
    File.foreach(path, encoding: 'bom|utf-8') do |raw|
      line = raw.strip
      next if line.empty? || line.start_with?('#')
      if (m = line.match(/\A\[(\d+)/))
        map_id = m[1].to_i
        sec = nil
      elsif map_id && line =~ /\A\d/
        prob, species, min, max = line.split(',')
        next unless species && sec
        sec[:slots] << { prob: prob.to_i, species: species.strip,
                         min: min.to_i, max: (max ? max.to_i : min.to_i) }
      elsif map_id
        name, chance = line.split(',')
        sec = { type: name.strip, step_chance: (chance ? chance.to_i : nil), slots: [] }
        (out[map_id] ||= []) << sec
      end
    end
    out
  end
end
```

- [ ] **Step 2: Smoke-test the loader against the fixture**

Run:
```bash
"$RMXP_RUBY" -e 'require_relative "codec/pbs"; p PBS.load("sample/PBS")[:encounters]; p PBS.load("sample/PBS")[:species]["FOOMON"]'
```
Expected output (order may vary):
```
{1=>[{:type=>"Land", :step_chance=>21, :slots=>[{:prob=>60, :species=>"FOOMON", :min=>3, :max=>6}, {:prob=>40, :species=>"BARMON", :min=>4, :max=>7}]}]}
{:types=>["FLORA"], :abilities=>["GUTSY"], :hidden=>[], :moves=>["SPROUT", "BONK"], :tutor=>["SCORCH"], :egg=>[], :evolutions=>["BARMON"]}
```

- [ ] **Step 3: Verify a missing directory degrades gracefully**

Run:
```bash
"$RMXP_RUBY" -e 'require_relative "codec/pbs"; p PBS.load("sample/NOPE")'
```
Expected: `{:species=>{}, :moves=>{}, :abilities=>{}, :types=>{}, :encounters=>{}}`

- [ ] **Step 4: Commit**

```bash
git add codec/pbs.rb
git commit -m "Codec: read-only PBS loader (v21.1) with verified encounter-type constants"
```

---

## Task 3: Encounter + PBS-integrity validators (`codec/validators.rb`)

**Files:**
- Modify: `codec/validators.rb`

- [ ] **Step 1: Require the loader**

At the top, change:

```ruby
require_relative 'rgss'
```

to:

```ruby
require_relative 'rgss'
require_relative 'pbs'
```

- [ ] **Step 2: Add a `warn` issue helper**

Next to the existing `err`/`info` helpers at the bottom of the module, add:

```ruby
  def warn(code, detail, **extra) { 'code' => code, 'severity' => 'WARN', 'detail' => detail }.merge(extra.transform_keys(&:to_s)) end
```

(Inside the module this shadows `Kernel#warn`; validators only build issue hashes, so that is intended.)

- [ ] **Step 3: Wire `pbs:` into `validate()`**

Change the signature:

```ruby
  def validate(map, tileset, map_id:, valid_map_ids: nil, map_dims: {})
```

to:

```ruby
  def validate(map, tileset, map_id:, valid_map_ids: nil, map_dims: {}, pbs: nil)
```

and after the existing `check_reachability(issues, map, tileset, w, h)` line add:

```ruby
    check_encounters(issues, map_id, pbs) if pbs
```

- [ ] **Step 4: Add `check_encounters`**

Add after `check_reachability`:

```ruby
  # Cross-ref a map's wild-encounter table (from encounters.txt) against species
  # existence and level sanity. No section for a map id = no wild Pokemon = skip.
  def check_encounters(issues, map_id, pbs)
    sections = pbs[:encounters][map_id]
    return unless sections
    species = pbs[:species]
    sections.each do |sec|
      unless PBS::ENCOUNTER_TYPES.include?(sec[:type])
        issues << warn('ENCOUNTER_TYPE_UNKNOWN',
                       "map #{map_id} uses unknown encounter type #{sec[:type]}",
                       type: sec[:type])
      end
      sec[:slots].each do |slot|
        unless species.key?(slot[:species])
          issues << err('ENCOUNTER_SPECIES_MISSING',
                        "map #{map_id} encounter references unknown species #{slot[:species]}",
                        species: slot[:species], type: sec[:type])
        end
        lo, hi = slot[:min], slot[:max]
        if lo > hi || lo < 1 || hi > PBS::MAX_LEVEL
          issues << err('ENCOUNTER_LEVEL_RANGE',
                        "map #{map_id} #{slot[:species]} level #{lo}-#{hi} outside 1..#{PBS::MAX_LEVEL}",
                        species: slot[:species])
        end
      end
    end
  end
```

- [ ] **Step 5: Add `validate_pbs`**

Add after `check_encounters`:

```ruby
  # Map-independent PBS internal-integrity check. Returns the same report shape
  # as validate(), keyed by category counts instead of a map id.
  def validate_pbs(pbs)
    issues = []
    species   = pbs[:species]
    moves     = pbs[:moves]
    abilities = pbs[:abilities]
    types     = pbs[:types]

    species.each do |id, s|
      (s[:moves] + s[:tutor] + s[:egg]).uniq.each do |mv|
        next if moves.key?(mv)
        issues << err('PBS_MOVE_MISSING', "species #{id} references unknown move #{mv}", species: id, move: mv)
      end
      (s[:abilities] + s[:hidden]).uniq.each do |ab|
        next if abilities.key?(ab)
        issues << err('PBS_ABILITY_MISSING', "species #{id} references unknown ability #{ab}", species: id, ability: ab)
      end
      s[:types].each do |ty|
        next if types.key?(ty)
        issues << err('PBS_TYPE_MISSING', "species #{id} has unknown type #{ty}", species: id, type: ty)
      end
      s[:evolutions].each do |ev|
        next if species.key?(ev)
        issues << err('PBS_EVOLUTION_MISSING', "species #{id} evolves into unknown species #{ev}", species: id, target: ev)
      end
    end

    moves.each do |id, m|
      next if m[:type].nil? || types.key?(m[:type])
      issues << err('PBS_TYPE_MISSING', "move #{id} has unknown type #{m[:type]}", move: id, type: m[:type])
    end

    types.each do |id, t|
      (t[:weaknesses] + t[:resistances] + t[:immunities]).uniq.each do |r|
        next if types.key?(r)
        issues << warn('PBS_TYPE_RELATION_MISSING', "type #{id} references unknown type #{r}", type: id, ref: r)
      end
    end

    {
      'scope'  => 'pbs',
      'ok'     => issues.none? { |i| i['severity'] == 'ERROR' },
      'counts' => issues.group_by { |i| i['severity'] }.transform_values(&:size),
      'issues' => issues
    }
  end
```

- [ ] **Step 6: Smoke-test both validators against the clean fixture**

Run:
```bash
"$RMXP_RUBY" -e '
$LOAD_PATH.unshift "codec"; require "validators"
pbs = PBS.load("sample/PBS")
rep = Validators.validate_pbs(pbs)
puts "pbs ok=#{rep["ok"]} issues=#{rep["issues"].map{|i| i["code"]}.inspect}"
map = Marshal.load(File.binread("sample/Map001.rxdata"))
ts  = Marshal.load(File.binread("sample/Tilesets.rxdata"))[map.instance_variable_get(:@tileset_id)]
m   = Validators.validate(map, ts, map_id: 1, pbs: pbs)
puts "map1 encounter issues=#{m["issues"].select{|i| i["code"].start_with?("ENCOUNTER")}.map{|i| i["code"]}.inspect}"
'
```
Expected:
```
pbs ok=true issues=[]
map1 encounter issues=[]
```

- [ ] **Step 7: Commit**

```bash
git add codec/validators.rb
git commit -m "Validators: encounter cross-ref + PBS internal-integrity checks"
```

---

## Task 4: `tests/m3_pbs.rb` (validate_pbs acceptance)

**Files:**
- Create: `tests/m3_pbs.rb`

- [ ] **Step 1: Write the test (clean passes; seeded dangling refs flag codes)**

```ruby
# m3_pbs.rb -- acceptance for the PBS internal-integrity validator.
#   Part A: the synthetic sample/PBS is internally consistent (no ERROR).
#   Part B: deliberately dangling refs raise exactly the expected codes.
$LOAD_PATH.unshift File.expand_path('../codec', __dir__)
require 'validators'

DIR = File.expand_path('../sample/PBS', __dir__)
fails = []

# ---- Part A: clean ----
clean = Validators.validate_pbs(PBS.load(DIR))
if clean['ok'] && clean['issues'].empty?
  puts 'A sample/PBS  [PASS] internally consistent'
else
  fails << "sample PBS should be clean but raised #{clean['issues'].map { |i| i['code'] }}"
  puts "A sample/PBS  [FAIL] #{clean['issues'].map { |i| i['code'] }}"
end

# ---- Part B: sabotage a deep copy of the loaded structure ----
pbs = PBS.load(DIR)
pbs[:species]['BROKMON'] = {
  types: ['GHOSTLY'],            # PBS_TYPE_MISSING
  abilities: ['NOPEABILITY'],    # PBS_ABILITY_MISSING
  hidden: [],
  moves: ['NOTAMOVE'],           # PBS_MOVE_MISSING
  tutor: [], egg: [],
  evolutions: ['NOSUCHMON']      # PBS_EVOLUTION_MISSING
}
rep = Validators.validate_pbs(pbs)
got  = rep['issues'].map { |i| i['code'] }.uniq.sort
want = %w[PBS_ABILITY_MISSING PBS_EVOLUTION_MISSING PBS_MOVE_MISSING PBS_TYPE_MISSING]
missing = want - got
if missing.empty? && rep['ok'] == false
  puts "B broken-pbs  [PASS] flagged #{got.inspect}"
else
  fails << "broken PBS: missing=#{missing} ok=#{rep['ok']}"
  puts "B broken-pbs  [FAIL] got #{got.inspect} missing #{missing.inspect}"
end

puts "\nM3-PBS #{fails.empty? ? 'PASS -- clean PBS clean, broken PBS flagged.' : 'FAIL'}"
fails.each { |f| puts "  - #{f}" }
exit(fails.empty? ? 0 : 1)
```

- [ ] **Step 2: Run it**

Run: `"$RMXP_RUBY" tests/m3_pbs.rb`
Expected: ends with `M3-PBS PASS -- clean PBS clean, broken PBS flagged.` and exit 0

- [ ] **Step 3: Commit**

```bash
git add tests/m3_pbs.rb
git commit -m "Tests: m3_pbs acceptance for PBS internal-integrity validator"
```

---

## Task 5: Encounter cases in `tests/m3_validate.rb`

**Files:**
- Modify: `tests/m3_validate.rb`

- [ ] **Step 1: Load PBS at the top of the test**

After the `DIMS` block (around line 16), add:

```ruby
PBS_DIR = File.join(DATA, 'PBS')
PBS_DATA = Dir.exist?(PBS_DIR) ? PBS.load(PBS_DIR) : nil
```

- [ ] **Step 2: Pass `pbs:` through the local `validate` helper**

Change:

```ruby
def validate(map, id)
  ts = TILESETS[map.instance_variable_get(:@tileset_id)]
  Validators.validate(map, ts, map_id: id, valid_map_ids: VALID_IDS, map_dims: DIMS)
end
```

to:

```ruby
def validate(map, id)
  ts = TILESETS[map.instance_variable_get(:@tileset_id)]
  Validators.validate(map, ts, map_id: id, valid_map_ids: VALID_IDS, map_dims: DIMS, pbs: PBS_DATA)
end
```

- [ ] **Step 3: Add Part C before the final summary block**

Insert before the `puts "\nM3 ...` line:

```ruby
# ---- Part C: encounter cross-ref ----
# C1: map 1 has a clean synthetic encounter table -> no ENCOUNTER_* errors.
rep_c1 = validate(Marshal.load(File.binread(File.join(DATA, 'Map001.rxdata'))), 1)
enc_errs = rep_c1['issues'].select { |i| i['code'].to_s.start_with?('ENCOUNTER') }
if enc_errs.empty?
  puts 'C1 map1 encounters  [PASS] clean'
else
  fails << "map1 encounters should be clean but raised #{enc_errs.map { |e| e['code'] }}"
  puts "C1 map1 encounters  [FAIL] #{enc_errs.map { |e| e['code'] }}"
end

# C2: sabotage the loaded encounter table for map 1 and re-validate.
if PBS_DATA
  saboteur = Marshal.load(Marshal.dump(PBS_DATA))
  saboteur[:encounters][1] = [
    { type: 'Land', step_chance: 21, slots: [
      { prob: 100, species: 'GHOSTMON', min: 3, max: 6 },   # ENCOUNTER_SPECIES_MISSING
      { prob: 50,  species: 'FOOMON',   min: 9, max: 2 }    # ENCOUNTER_LEVEL_RANGE (min>max)
    ] },
    { type: 'Moonlight', step_chance: nil, slots: [] }       # ENCOUNTER_TYPE_UNKNOWN
  ]
  ts = TILESETS[1]
  map1 = Marshal.load(File.binread(File.join(DATA, 'Map001.rxdata')))
  rep_c2 = Validators.validate(map1, ts, map_id: 1, valid_map_ids: VALID_IDS, map_dims: DIMS, pbs: saboteur)
  got_c2  = rep_c2['issues'].map { |i| i['code'] }.uniq
  want_c2 = %w[ENCOUNTER_SPECIES_MISSING ENCOUNTER_LEVEL_RANGE ENCOUNTER_TYPE_UNKNOWN]
  missing_c2 = want_c2 - got_c2
  if missing_c2.empty?
    puts "C2 broken encounters  [PASS] flagged #{(got_c2 & want_c2).sort.inspect}"
  else
    fails << "broken encounters missing=#{missing_c2}"
    puts "C2 broken encounters  [FAIL] missing #{missing_c2.inspect}"
  end
end
```

- [ ] **Step 4: Run it**

Run: `"$RMXP_RUBY" tests/m3_validate.rb`
Expected: Part A/B still pass, plus `C1 ... [PASS]` and `C2 ... [PASS]`, ending `M3 PASS ...`, exit 0

- [ ] **Step 5: Commit**

```bash
git add tests/m3_validate.rb
git commit -m "Tests: m3_validate Part C exercises encounter cross-ref (clean + sabotaged)"
```

---

## Task 6: CLI wiring (`codec/cli.rb`)

**Files:**
- Modify: `codec/cli.rb`

- [ ] **Step 1: Require the loader**

Change:

```ruby
require_relative 'codec'
require_relative 'validators'
require_relative 'ops'
require 'json'
```

to:

```ruby
require_relative 'codec'
require_relative 'validators'
require_relative 'pbs'
require_relative 'ops'
require 'json'
```

- [ ] **Step 2: Auto-load PBS in the `validate` verb**

In the `when 'validate'` branch, change:

```ruby
  tileset = tilesets[map.instance_variable_get(:@tileset_id)]
  report  = Validators.validate(map, tileset, map_id: map_id,
                                valid_map_ids: valid_ids, map_dims: dims)
```

to:

```ruby
  tileset = tilesets[map.instance_variable_get(:@tileset_id)]
  pbs_dir = File.join(data_dir, 'PBS')
  pbs     = Dir.exist?(pbs_dir) ? PBS.load(pbs_dir) : nil
  report  = Validators.validate(map, tileset, map_id: map_id,
                                valid_map_ids: valid_ids, map_dims: dims, pbs: pbs)
```

- [ ] **Step 3: Add the `validate-pbs` verb**

After the `when 'validate' ... exit(...)` block and before `when 'snapshot'`, add:

```ruby
when 'validate-pbs'
  # validate-pbs <pbs_dir>  -- map-independent PBS internal-integrity report
  report = Validators.validate_pbs(PBS.load(ARGV[1]))
  STDOUT.write(JSON.pretty_generate(report))
  exit(report['ok'] ? 0 : 1)
```

- [ ] **Step 4: Update the usage text**

In the `else` branch, change the `dump-tilesets ...` usage line:

```ruby
       "  dump-tilesets <Tilesets.rxdata> | validate <data_dir> <map.rxdata>\n" \
```

to:

```ruby
       "  dump-tilesets <Tilesets.rxdata> | validate <data_dir> <map.rxdata>\n" \
       "  validate-pbs <pbs_dir>\n" \
```

- [ ] **Step 5: Verify both CLI paths**

Run: `"$RMXP_RUBY" codec/cli.rb validate-pbs sample/PBS`
Expected: JSON with `"scope": "pbs"`, `"ok": true`, empty `"issues"`, exit 0

Run: `"$RMXP_RUBY" codec/cli.rb validate sample sample/Map001.rxdata`
Expected: JSON report for map 1 with no `ENCOUNTER_*` issues (auto-picked up PBS), exit 0

- [ ] **Step 6: Commit**

```bash
git add codec/cli.rb
git commit -m "CLI: auto-load PBS in validate; add validate-pbs verb"
```

---

## Task 7: Pi tool + docs

**Files:**
- Modify: `.pi/extensions/rmxp.ts`
- Modify: `docs/SKILL.md`
- Modify: `docs/writeup.md`

- [ ] **Step 1: Extend the `rmxp_validate` description**

In `.pi/extensions/rmxp.ts`, change the `rmxp_validate` description string:

```ts
      "Run deterministic validators on a map (tile-range, table dims, event bounds, " +
      "warp integrity vs MapInfos, reachability). Returns a JSON report; ERROR issues " +
      "mean the map is broken. Always validate after acting.",
```

to:

```ts
      "Run deterministic validators on a map (tile-range, table dims, event bounds, " +
      "warp integrity vs MapInfos, reachability, and wild-encounter cross-ref vs PBS " +
      "when a PBS/ dir sits beside the map). Returns a JSON report; ERROR issues mean " +
      "the map is broken. Always validate after acting.",
```

- [ ] **Step 2: Register the `rmxp_validate_pbs` tool**

In `.pi/extensions/rmxp.ts`, after the `rmxp_validate` tool registration block (before `// ---- act (C) ----`), add:

```ts
  // ---- validate PBS (V, data layer) ----
  pi.registerTool({
    name: "rmxp_validate_pbs",
    label: "RMXP validate PBS",
    description:
      "Check Pokemon Essentials PBS data for internal integrity: species referencing " +
      "unknown moves/abilities/types/evolutions, and type relations referencing unknown " +
      "types. Map-independent. Returns a JSON report; ERROR issues mean the data is broken.",
    promptSnippet: "Validate Essentials PBS data integrity (species/moves/types)",
    parameters: Type.Object({ pbs_dir: Type.String({ description: "path to a PBS/ directory" }) }),
    async execute(_id, p, signal, _u, ctx) {
      const dir = resolve(ctx.cwd, p.pbs_dir.replace(/^@/, ""));
      const res = await spawn(RUBY, [CODEC_CLI, "validate-pbs", dir], { cwd: ctx.cwd, signal });
      return text(res.stdout || res.stderr);
    },
  });
```

- [ ] **Step 3: Update the `session_start` notify line**

Change:

```ts
    ctx.ui.notify("RMXP harness tools loaded: snapshot, read, validate, act, render", "info");
```

to:

```ts
    ctx.ui.notify("RMXP harness tools loaded: snapshot, read, validate, validate_pbs, act, render", "info");
```

- [ ] **Step 4: Update `docs/SKILL.md` tool table and verb list**

In the Tools table, change the `rmxp_validate` row to mention encounters, and add a `rmxp_validate_pbs` row directly under it:

```markdown
| `rmxp_validate {map}` | V | Deterministic report: tile-range, table dims, event bounds, warp integrity, reachability, and wild-encounter cross-ref vs PBS (when `PBS/` is beside the map). |
| `rmxp_validate_pbs {pbs_dir}` | V | PBS internal integrity: species->moves/abilities/types/evolutions and type relations all resolve. Map-independent. |
```

In the "Verbs without Pi" code block, add after the `validate` line:

```
ruby codec/cli.rb validate-pbs <pbs_dir>                  # PBS internal integrity
```

- [ ] **Step 5: Flip the writeup's stubbed-PBS line**

In `docs/writeup.md`, find the line describing PBS cross-refs as stubbed/future and replace it with a shipped description. Run first to locate it:

Run: `grep -n -i "pbs\|cross-ref\|encounter\|stub" docs/writeup.md`

Then edit the matched line(s) so they state that encounter cross-ref (map vs PBS) and PBS internal-integrity validators are implemented, deterministic, and test-backed (`tests/m3_pbs.rb`, `tests/m3_validate.rb` Part C). Keep the no-em-dash, no-filler house style. If no such line exists, add one sentence to the validators/V-layer section noting the PBS cross-ref validators ship and are exercised by those two tests.

- [ ] **Step 6: Full test sweep**

Run each and confirm exit 0:
```bash
"$RMXP_RUBY" tests/m3_validate.rb
"$RMXP_RUBY" tests/m3_pbs.rb
```
Expected: both end in `PASS`.

- [ ] **Step 7: Commit**

```bash
git add .pi/extensions/rmxp.ts docs/SKILL.md docs/writeup.md
git commit -m "Pi+docs: rmxp_validate_pbs tool; document PBS cross-ref V-layer"
```

---

## Self-Review notes (for the implementer)

- The `warn` helper deliberately shadows `Kernel#warn` inside the `Validators` module; nothing in that file calls `Kernel#warn`.
- `parse_blocks` keys `[ID,form]` on the base `ID`, which is sufficient for existence checks (the validators only need to know an id exists / what it references).
- v21.1 has no per-type encounter slot count and probabilities are relative weights, so there is intentionally NO slot-count or prob-sum check. Do not add one.
- Map ids with no encounter section are valid (most maps have no wild Pokemon); `check_encounters` returns early, never flags.
