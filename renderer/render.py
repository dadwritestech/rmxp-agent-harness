#!/usr/bin/env python3
"""M2 renderer: Map IR -> PNG (Pillow, v1).

Composites the three tile layers bottom-to-top. Regular tiles (id >= 384) index
into the tileset PNG (8 tiles wide). Autotiles (1..383) are rendered naively in
v1: we sample the fully-interior cell of the autotile template rather than doing
true 48-subtile neighbor blending. mkxp-z is the ground-truth fallback (handover
section R) if the naive autotiles drift.

Inputs are JSON the Ruby codec emits, so this stays Ruby-free at render time:
    ruby codec/cli.rb to-ir Map001.rxdata > map.ir.json
    ruby codec/cli.rb dump-tilesets Tilesets.rxdata > tilesets.json
    python renderer/render.py map.ir.json tilesets.json corpus/Graphics out.png
"""
import json
import sys
from pathlib import Path
from PIL import Image

TILE = 32
TILESET_COLS = 8           # RMXP tileset sheets are always 8 tiles wide
FIRST_REGULAR_ID = 384     # ids below this are autotiles (or 0 = empty)
AUTOTILE_SIZE = 48         # ids per autotile slot


def load_tile_image(cache, path):
    img = cache.get(path)
    if img is None:
        img = Image.open(path).convert("RGBA")
        cache[path] = img
    return img


def regular_tile(sheet, tile_id):
    idx = tile_id - FIRST_REGULAR_ID
    col, row = idx % TILESET_COLS, idx // TILESET_COLS
    box = (col * TILE, row * TILE, col * TILE + TILE, row * TILE + TILE)
    if box[2] <= sheet.width and box[3] <= sheet.height:
        return sheet.crop(box)
    return None


def autotile_tile(auto_img):
    # Naive v1: RMXP autotile templates are 96x128 (3x4 tiles); the fully
    # surrounded interior tile sits at column 1, row 1. Use the first animation
    # frame (leftmost 96px) if the sheet is wider.
    x, y = TILE, TILE
    if x + TILE <= auto_img.width and y + TILE <= auto_img.height:
        return auto_img.crop((x, y, x + TILE, y + TILE))
    # tiny/atypical autotile sheet: fall back to top-left
    return auto_img.crop((0, 0, min(TILE, auto_img.width), min(TILE, auto_img.height)))


def render(ir, tilesets, graphics_dir, out_path):
    t = ir["tiles"]
    xs, ys, zs = t["xsize"], t["ysize"], t["zsize"]
    data = t["data"]
    tsid = str(ir["tileset_id"])
    ts = tilesets[tsid]

    gdir = Path(graphics_dir)
    cache = {}
    sheet = load_tile_image(cache, gdir / "Tilesets" / f"{ts['tileset_name']}.png")
    auto_names = ts["autotile_names"]

    canvas = Image.new("RGBA", (xs * TILE, ys * TILE), (0, 0, 0, 0))
    placed = {"regular": 0, "autotile": 0, "empty": 0, "missing": 0}

    for z in range(zs):
        for y in range(ys):
            for x in range(xs):
                tid = data[x + y * xs + z * xs * ys]
                if tid == 0:
                    placed["empty"] += 1
                    continue
                if tid >= FIRST_REGULAR_ID:
                    tile = regular_tile(sheet, tid)
                    kind = "regular"
                else:
                    slot = tid // AUTOTILE_SIZE          # 1..7
                    name = auto_names[slot - 1] if 1 <= slot <= len(auto_names) else ""
                    if not name:
                        placed["missing"] += 1
                        continue
                    apath = gdir / "Autotiles" / f"{name}.png"
                    if not apath.exists():
                        placed["missing"] += 1
                        continue
                    tile = autotile_tile(load_tile_image(cache, apath))
                    kind = "autotile"
                if tile is None:
                    placed["missing"] += 1
                    continue
                canvas.alpha_composite(tile, (x * TILE, y * TILE))
                placed[kind] += 1

    canvas.save(out_path)
    return placed, (xs * TILE, ys * TILE)


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: render.py <map.ir.json> <tilesets.json> <graphics_dir> <out.png>")
    ir = json.loads(Path(sys.argv[1]).read_text())
    tilesets = json.loads(Path(sys.argv[2]).read_text())
    placed, size = render(ir, tilesets, sys.argv[3], sys.argv[4])
    print(f"rendered {sys.argv[4]}  {size[0]}x{size[1]}px  "
          f"regular={placed['regular']} autotile={placed['autotile']} "
          f"empty={placed['empty']} missing={placed['missing']}")


if __name__ == "__main__":
    main()
