# rgss.rb
# Minimal RGSS/RMXP class definitions required to Marshal.load and re-dump
# RPG Maker XP .rxdata files with a modern Ruby.
#
# Why this file exists:
#   rxdata is a Ruby Marshal dump (format 4.8). Marshal stores ordinary objects
#   as their class name + instance variables, and reconstructs them with
#   Class.allocate (it does NOT call #initialize). So for ordinary RPG::* classes
#   we only need the class to *exist* in this namespace.
#   A few classes (Table, Color, Tone) are "user-defined" marshal types: they
#   serialize through custom self._load(str) / #_dump(depth) byte protocols.
#   Those we must implement faithfully, because their bytes are the fidelity risk.
#
# Byte-fidelity contract for the user-defined classes:
#   For any original blob B, _dump(_load(B)) must equal B exactly.

# ---------------------------------------------------------------------------
# Table: RMXP's tile/flag container. A 1D/2D/3D grid of signed 16-bit ints.
#
# Binary layout (all little-endian):
#   int32 dim        (1, 2, or 3)
#   int32 xsize
#   int32 ysize
#   int32 zsize
#   int32 size       (== xsize*ysize*zsize in every file RMXP writes)
#   int16 data[size]
#
# We keep all five header ints verbatim (not recomputed) so re-dump is byte-exact
# even if a file ever carried an unexpected size field. Tile data is unpacked as
# unsigned 16-bit ('v') purely so repacking reproduces identical bytes; sign is
# irrelevant to the round-trip.
# ---------------------------------------------------------------------------
class Table
  attr_accessor :dim, :xsize, :ysize, :zsize, :size, :data

  def initialize(xsize, ysize = 1, zsize = 1)
    @dim   = (zsize > 1 ? 3 : (ysize > 1 ? 2 : 1))
    @xsize = xsize
    @ysize = ysize
    @zsize = zsize
    @size  = xsize * ysize * zsize
    @data  = Array.new(@size, 0)
  end

  def self._load(str)
    dim, xsize, ysize, zsize, size = str[0, 20].unpack('l<5')
    t = allocate
    t.instance_variable_set(:@dim,   dim)
    t.instance_variable_set(:@xsize, xsize)
    t.instance_variable_set(:@ysize, ysize)
    t.instance_variable_set(:@zsize, zsize)
    t.instance_variable_set(:@size,  size)
    t.instance_variable_set(:@data,  str[20, size * 2].unpack('v*'))
    t
  end

  def _dump(_depth = 0)
    [@dim, @xsize, @ysize, @zsize, @size].pack('l<5') + @data.pack('v*')
  end

  # 3D accessor (x,y,layer). Used by the codec/validators, not by Marshal.
  def get(x, y = 0, z = 0)
    @data[x + y * @xsize + z * @xsize * @ysize]
  end

  def set(x, y, z, v)
    @data[x + y * @xsize + z * @xsize * @ysize] = v
  end
end

# ---------------------------------------------------------------------------
# Color / Tone: four little-endian float64 values (r,g,b,a) / (r,g,b,gray).
# Appear inside tilesets, system data, and screen-tint event commands.
# ---------------------------------------------------------------------------
class Color
  attr_accessor :red, :green, :blue, :alpha
  def initialize(r = 0.0, g = 0.0, b = 0.0, a = 255.0)
    @red, @green, @blue, @alpha = r, g, b, a
  end
  def self._load(str)
    r, g, b, a = str.unpack('E4')
    new(r, g, b, a)
  end
  def _dump(_d = 0)
    [@red, @green, @blue, @alpha].pack('E4')
  end
end

class Tone
  attr_accessor :red, :green, :blue, :gray
  def initialize(r = 0.0, g = 0.0, b = 0.0, gray = 0.0)
    @red, @green, @blue, @gray = r, g, b, gray
  end
  def self._load(str)
    r, g, b, gray = str.unpack('E4')
    new(r, g, b, gray)
  end
  def _dump(_d = 0)
    [@red, @green, @blue, @gray].pack('E4')
  end
end

# ---------------------------------------------------------------------------
# RPG::* ordinary classes. Empty bodies are sufficient for Marshal round-trip:
# Marshal allocates the instance and assigns ivars directly. We only enumerate
# the classes that actually occur in the map/tileset/mapinfo object graphs.
# ---------------------------------------------------------------------------
module RPG
  class Map; end
  class MapInfo; end
  class Tileset; end
  class Event
    class Page
      class Condition; end
      class Graphic; end
    end
  end
  class EventCommand; end
  class MoveRoute; end
  class MoveCommand; end
  class AudioFile; end
end
