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
