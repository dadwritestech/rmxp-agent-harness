#!/usr/bin/env python3
"""Generate an ORIGINAL tileset sheet for the public test fixture.
8 tiles wide (RMXP convention), distinct flat colors so renders are legible.
No game assets involved -- this is generated art, safe to publish."""
import sys
from pathlib import Path
from PIL import Image, ImageDraw

TILE = 32
COLS = 8
ROWS = 8  # 64 regular tiles -> ids 384..447

out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("sample/Graphics/Tilesets/Sample.png")
out.parent.mkdir(parents=True, exist_ok=True)

img = Image.new("RGBA", (COLS * TILE, ROWS * TILE), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
for r in range(ROWS):
    for c in range(COLS):
        # deterministic, distinct color per tile
        col = (40 + (c * 28) % 216, 40 + (r * 28) % 216, 90 + ((c + r) * 20) % 160, 255)
        x, y = c * TILE, r * TILE
        d.rectangle([x, y, x + TILE - 1, y + TILE - 1], fill=col, outline=(20, 20, 20, 255))
img.save(out)
print(f"wrote {out} ({img.width}x{img.height})")
