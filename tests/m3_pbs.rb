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
