# validators.rb -- M3 deterministic map validators (the V surface).
#
# Each check appends an issue {code, severity, detail, ...}. ERROR = the map is
# broken/unsafe; WARN = suspicious but maybe intentional; INFO = advisory.
# Validators never mutate the map.
#
# Passability model (RMXP): @passages[id] is a direction bitfield
#   0x01 down, 0x02 left, 0x04 right, 0x08 up blocked; 0x0f = fully impassable.
# A cell is a wall if any layer holds a ground tile (priority 0) that is fully
# impassable. Reachability flood-fills 4-connected over non-wall cells.

require_relative 'rgss'
require_relative 'pbs'

module Validators
  AUTOTILE_SIZE   = 48
  FIRST_REGULAR   = 384
  BLOCK_ALL       = 0x0f

  module_function

  # tileset: an RPG::Tileset; returns the max valid tile id (exclusive ceiling)
  def tile_id_ceiling(tileset)
    tileset.instance_variable_get(:@passages).xsize
  end

  def autotile_defined?(tileset, tile_id)
    slot = tile_id / AUTOTILE_SIZE          # 1..7 for real autotiles
    names = tileset.instance_variable_get(:@autotile_names)
    slot >= 1 && slot <= names.size && !names[slot - 1].to_s.empty?
  end

  # A cell (x,y) is a wall if any layer tile is a fully-impassable ground tile.
  def wall?(map, tileset, x, y)
    t  = map.instance_variable_get(:@data)
    pa = tileset.instance_variable_get(:@passages)
    pr = tileset.instance_variable_get(:@priorities)
    (0...t.zsize).any? do |z|
      id = t.get(x, y, z)
      next false if id.nil? || id == 0 || id >= pa.xsize
      (pa.get(id, 0, 0) & BLOCK_ALL) == BLOCK_ALL && pr.get(id, 0, 0) == 0
    end
  end

  # ---- main entry ----
  # valid_map_ids: authoritative set of map ids (from MapInfos) for warp existence.
  # map_dims: { map_id => [width, height] } for warp bounds (may be partial).
  def validate(map, tileset, map_id:, valid_map_ids: nil, map_dims: {}, pbs: nil)
    issues = []
    w = map.instance_variable_get(:@width)
    h = map.instance_variable_get(:@height)
    t = map.instance_variable_get(:@data)

    check_table_dims(issues, w, h, t)
    check_tile_range(issues, t, tileset)
    check_event_bounds(issues, map, w, h)
    check_warps(issues, map, map_id, w, h, valid_map_ids, map_dims)
    check_reachability(issues, map, tileset, w, h)
    check_encounters(issues, map_id, pbs) if pbs

    {
      'map_id'   => map_id,
      'width'    => w, 'height' => h,
      'tileset'  => tileset.instance_variable_get(:@name),
      'ok'       => issues.none? { |i| i['severity'] == 'ERROR' },
      'counts'   => issues.group_by { |i| i['severity'] }.transform_values(&:size),
      'issues'   => issues
    }
  end

  def check_table_dims(issues, w, h, t)
    if t.xsize != w || t.ysize != h
      issues << err('TABLE_DIMS', "tile Table #{t.xsize}x#{t.ysize} != map #{w}x#{h}")
    end
    expect = t.xsize * t.ysize * t.zsize
    if t.size != expect || t.data.size != expect
      issues << err('TABLE_DIMS', "Table size #{t.size}/data #{t.data.size} != x*y*z #{expect}")
    end
  end

  def check_tile_range(issues, t, tileset)
    ceil = tile_id_ceiling(tileset)
    bad = Hash.new(0)
    t.data.each do |id|
      next if id == 0
      if id < FIRST_REGULAR
        bad[id] += 1 unless autotile_defined?(tileset, id)
      elsif id >= ceil
        bad[id] += 1
      end
    end
    bad.each do |id, n|
      issues << err('TILE_RANGE', "tile id #{id} invalid for tileset (ceiling #{ceil})", count: n)
    end
  end

  def check_event_bounds(issues, map, w, h)
    (map.instance_variable_get(:@events) || {}).each do |key, ev|
      x = ev.instance_variable_get(:@x); y = ev.instance_variable_get(:@y)
      next if x.between?(0, w - 1) && y.between?(0, h - 1)
      issues << err('EVENT_OOB', "event ##{key} at (#{x},#{y}) outside #{w}x#{h}",
                    event: key)
    end
  end

  # Shallow-parse Transfer Player (code 201) out of otherwise-opaque pages.
  def each_warp(map)
    (map.instance_variable_get(:@events) || {}).each do |key, ev|
      (ev.instance_variable_get(:@pages) || []).each_with_index do |page, pi|
        (page.instance_variable_get(:@list) || []).each do |cmd|
          next unless cmd.instance_variable_get(:@code) == 201
          p = cmd.instance_variable_get(:@parameters)
          # [appoint_method, map_id, x, y, direction, fade]; method 1 = by variable
          yield(key, pi, p) if p && p[0] == 0
        end
      end
    end
  end

  def check_warps(issues, map, _map_id, _w, _h, valid_map_ids, map_dims)
    each_warp(map) do |key, _pi, p|
      tgt, tx, ty = p[1], p[2], p[3]
      exists = valid_map_ids.nil? || valid_map_ids.include?(tgt)
      unless exists
        issues << err('WARP_TARGET_MISSING',
                      "event ##{key} warps to map #{tgt} which does not exist",
                      event: key, target: tgt)
        next
      end
      # bounds only when the target map's dimensions are available
      next unless map_dims.key?(tgt)
      tw, th = map_dims[tgt]
      unless tx.between?(0, tw - 1) && ty.between?(0, th - 1)
        issues << err('WARP_OOB',
                      "event ##{key} warps to map #{tgt} (#{tx},#{ty}) outside #{tw}x#{th}",
                      event: key, target: tgt)
      end
    end
  end

  def check_reachability(issues, map, tileset, w, h)
    walls = Array.new(h) { |y| Array.new(w) { |x| wall?(map, tileset, x, y) } }
    seen  = Array.new(h) { Array.new(w, false) }
    comps = []
    (0...h).each do |sy|
      (0...w).each do |sx|
        next if walls[sy][sx] || seen[sy][sx]
        size = 0
        stack = [[sx, sy]]
        seen[sy][sx] = true
        until stack.empty?
          x, y = stack.pop
          size += 1
          [[1, 0], [-1, 0], [0, 1], [0, -1]].each do |dx, dy|
            nx, ny = x + dx, y + dy
            next if nx < 0 || ny < 0 || nx >= w || ny >= h
            next if walls[ny][nx] || seen[ny][nx]
            seen[ny][nx] = true
            stack << [nx, ny]
          end
        end
        comps << size
      end
    end
    comps.sort!.reverse!
    if comps.size > 1
      issues << info('REACH_ISOLATED',
                     "#{comps.size} disconnected walkable regions; sizes #{comps.first(5).inspect}",
                     regions: comps.size)
    end
  end

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

  def err(code, detail, **extra)  { 'code' => code, 'severity' => 'ERROR', 'detail' => detail }.merge(extra.transform_keys(&:to_s)) end
  def info(code, detail, **extra) { 'code' => code, 'severity' => 'INFO',  'detail' => detail }.merge(extra.transform_keys(&:to_s)) end
  def warn(code, detail, **extra) { 'code' => code, 'severity' => 'WARN',  'detail' => detail }.merge(extra.transform_keys(&:to_s)) end
end
