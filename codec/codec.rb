# codec.rb -- RPG::Map <-> Map IR (Ruby Hash, JSON-ready).
#
# v1 scope (from HANDOVER.md section 5):
#   Editable in IR:  tile layers (the @data Table), event positions (@x,@y),
#                    event id/name, top-level map scalars.
#   Opaque pass-through: full event command lists (@pages) and the small audio/
#                    encounter objects, carried as exact Marshal bytes (base64).
#
# Fidelity contract: rebuild(to_ir(load(file))) must produce an object graph that
# Marshal.dumps to the same bytes the engine would load -- and, for the tile
# Table, identical tile-by-tile. Opaque fields survive because we never decode
# them: we hold their original Marshal bytes verbatim.

require_relative 'rgss'
require 'base64'
require 'json'

module Codec
  IR_VERSION = 1

  # ---- helpers: opaque blob = exact Marshal bytes, base64 for JSON transport ----
  def self.freeze_blob(obj)
    Base64.strict_encode64(Marshal.dump(obj))
  end

  def self.thaw_blob(b64)
    Marshal.load(Base64.strict_decode64(b64))
  end

  # ---- string <-> IR, preserving the ORIGINAL encoding tag exactly ----
  # RGSS strings are ASCII-8BIT (raw bytes). JSON transport is UTF-8, and
  # force_encoding changes only the tag, never the bytes -- so we keep the bytes
  # readable as text where possible and restore the exact original encoding on
  # rebuild, making the re-dumped Marshal string byte-identical. Bytes that are
  # not valid UTF-8 fall back to base64 so JSON stays well-formed.
  def self.enc_str(s)
    return nil if s.nil?
    probe = s.dup.force_encoding('UTF-8')
    if probe.valid_encoding?
      { 's' => probe, 'enc' => s.encoding.name }
    else
      { 'b64' => Base64.strict_encode64(s), 'enc' => s.encoding.name }
    end
  end

  def self.dec_str(h)
    return nil if h.nil?
    if h.key?('b64')
      Base64.strict_decode64(h['b64']).force_encoding(h['enc'])
    else
      h['s'].dup.force_encoding(h['enc'])
    end
  end

  # ---- Table <-> plain Hash ----
  def self.table_to_ir(t)
    { 'dim' => t.dim, 'xsize' => t.xsize, 'ysize' => t.ysize,
      'zsize' => t.zsize, 'size' => t.size, 'data' => t.data }
  end

  def self.ir_to_table(h)
    t = Table.allocate
    t.instance_variable_set(:@dim,   h['dim'])
    t.instance_variable_set(:@xsize, h['xsize'])
    t.instance_variable_set(:@ysize, h['ysize'])
    t.instance_variable_set(:@zsize, h['zsize'])
    t.instance_variable_set(:@size,  h['size'])
    t.instance_variable_set(:@data,  h['data'])
    t
  end

  # Editable, human-meaningful ivars get first-class IR fields; everything else
  # is carried as an opaque Marshal blob. Marshal writes ivars in assignment
  # order and that order varies per file, so we also record 'ivar_order' and
  # replay it on rebuild to make the round-trip byte-exact, not just semantic.
  MAP_EDITABLE   = %i[@tileset_id @width @height @encounter_step].freeze
  EVENT_EDITABLE = %i[@id @name @x @y].freeze

  # ---- Map -> IR ----
  def self.map_to_ir(map)
    g = ->(sym) { map.instance_variable_get(sym) }

    events = {}
    (g.call(:@events) || {}).each do |key, ev|
      events[key.to_s] = {
        'id'          => ev.instance_variable_get(:@id),
        'name'        => enc_str(ev.instance_variable_get(:@name)),
        'x'           => ev.instance_variable_get(:@x),
        'y'           => ev.instance_variable_get(:@y),
        'pages_blob'  => freeze_blob(ev.instance_variable_get(:@pages)),
        'ivar_order'  => ev.instance_variables.map(&:to_s)
      }
    end

    # any map ivar that isn't a first-class editable field travels opaque
    opaque = {}
    map.instance_variables.each do |iv|
      next if MAP_EDITABLE.include?(iv) || iv == :@data || iv == :@events
      opaque[iv.to_s] = freeze_blob(g.call(iv))
    end

    {
      'ir_version'     => IR_VERSION,
      'klass'          => map.class.name,
      'ivar_order'     => map.instance_variables.map(&:to_s),
      'tileset_id'     => g.call(:@tileset_id),
      'width'          => g.call(:@width),
      'height'         => g.call(:@height),
      'encounter_step' => g.call(:@encounter_step),
      'tiles'          => table_to_ir(g.call(:@data)),
      'events'         => events,
      'opaque'         => opaque
    }
  end

  # ---- IR -> Map ----
  # Sets ivars in the recorded original order so Marshal re-dumps byte-exactly.
  def self.ir_to_map(ir)
    map = RPG::Map.allocate

    # value source for each possible map ivar
    vals = {
      '@tileset_id'     => ir['tileset_id'],
      '@width'          => ir['width'],
      '@height'         => ir['height'],
      '@encounter_step' => ir['encounter_step'],
      '@data'           => ir_to_table(ir['tiles']),
      '@events'         => rebuild_events(ir['events'])
    }
    ir['opaque'].each { |k, b64| vals[k] = thaw_blob(b64) }

    ir['ivar_order'].each do |iv|
      map.instance_variable_set(iv.to_sym, vals.fetch(iv))
    end
    map
  end

  def self.rebuild_events(ir_events)
    events = {}
    ir_events.each do |key, ev|
      e = RPG::Event.allocate
      vals = {
        '@id'    => ev['id'],
        '@name'  => dec_str(ev['name']),
        '@x'     => ev['x'],
        '@y'     => ev['y'],
        '@pages' => thaw_blob(ev['pages_blob'])
      }
      ev['ivar_order'].each { |iv| e.instance_variable_set(iv.to_sym, vals.fetch(iv)) }
      # restore the Hash key as RMXP wrote it (string in JSON -> integer key)
      events[key.to_i] = e
    end
    events
  end

  def self.load_file(path)  Marshal.load(File.binread(path)) end
  def self.dump_file(map, path) File.binwrite(path, Marshal.dump(map)) end
end
