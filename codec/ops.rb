# ops.rb -- act operations (the C surface). Mutate a loaded RPG::Map in place.
#
# Operations are deliberately narrow so the agent never handles raw tile arrays:
#   set_tile      {x, y, layer, tile_id}
#   fill_region   {x, y, w, h, layer, tile_id}
#   move_event    {id, x, y}
#   set_warp      {event_id, target_map, x, y, direction?, page?}
#
# Each raises on out-of-bounds / missing targets so the calling tool surfaces a
# clear error instead of silently corrupting the map. Validation of the *result*
# (tile-range, warp integrity) is the validators' job, run after acting.
require_relative 'rgss'

module Ops
  TRANSFER_PLAYER = 201

  module_function

  def apply(map, op)
    case op['op']
    when 'set_tile'    then set_tile(map, op)
    when 'fill_region' then fill_region(map, op)
    when 'move_event'  then move_event(map, op)
    when 'set_warp'    then set_warp(map, op)
    else raise ArgumentError, "unknown op #{op['op'].inspect}"
    end
  end

  def dims(map)
    [map.instance_variable_get(:@width), map.instance_variable_get(:@height)]
  end

  def check_xy(map, x, y)
    w, h = dims(map)
    raise ArgumentError, "(#{x},#{y}) outside map #{w}x#{h}" unless
      x.between?(0, w - 1) && y.between?(0, h - 1)
  end

  def check_layer(layer)
    raise ArgumentError, "layer #{layer} must be 0..2" unless (0..2).include?(layer)
  end

  def set_tile(map, op)
    x, y, layer, tid = op.values_at('x', 'y', 'layer', 'tile_id')
    check_xy(map, x, y); check_layer(layer)
    map.instance_variable_get(:@data).set(x, y, layer, tid)
    { 'changed' => 1, 'detail' => "set (#{x},#{y}) layer #{layer} = #{tid}" }
  end

  def fill_region(map, op)
    x, y, w, h, layer, tid = op.values_at('x', 'y', 'w', 'h', 'layer', 'tile_id')
    check_layer(layer)
    check_xy(map, x, y)
    check_xy(map, x + w - 1, y + h - 1)
    t = map.instance_variable_get(:@data)
    (y...(y + h)).each { |yy| (x...(x + w)).each { |xx| t.set(xx, yy, layer, tid) } }
    { 'changed' => w * h, 'detail' => "filled #{w}x#{h} at (#{x},#{y}) layer #{layer} = #{tid}" }
  end

  def move_event(map, op)
    id, x, y = op.values_at('id', 'x', 'y')
    ev = (map.instance_variable_get(:@events) || {})[id]
    raise ArgumentError, "no event with id #{id}" unless ev
    check_xy(map, x, y)
    ev.instance_variable_set(:@x, x)
    ev.instance_variable_set(:@y, y)
    { 'changed' => 1, 'detail' => "moved event #{id} to (#{x},#{y})" }
  end

  # Edit an existing Transfer Player (201) command's destination. Creating warp
  # events from scratch is out of v1 scope (author them in RMXP); this raises if
  # the event has no 201 so the agent gets a clear message.
  def set_warp(map, op)
    id, tgt, x, y = op.values_at('event_id', 'target_map', 'x', 'y')
    dir  = op['direction']
    page = op['page']
    ev = (map.instance_variable_get(:@events) || {})[id]
    raise ArgumentError, "no event with id #{id}" unless ev
    pages = ev.instance_variable_get(:@pages) || []
    found = nil
    pages.each_with_index do |pg, pi|
      next if page && page != pi
      (pg.instance_variable_get(:@list) || []).each do |cmd|
        next unless cmd.instance_variable_get(:@code) == TRANSFER_PLAYER
        p = cmd.instance_variable_get(:@parameters)
        next unless p && p[0] == 0          # direct-appointment form
        p[1], p[2], p[3] = tgt, x, y
        p[4] = dir if dir
        found = pi
        break
      end
      break if found
    end
    raise ArgumentError, "event #{id} has no editable Transfer Player (201) command" unless found
    { 'changed' => 1, 'detail' => "event #{id} page #{found} warp -> map #{tgt} (#{x},#{y})" }
  end
end
