#!/usr/bin/env python3
"""M2 regression guard: render every corpus map and assert structural sanity.

Visual fidelity is judged by eye (handover M2 acceptance). This guard catches
regressions cheaply: every referenced tile resolves (missing == 0) and the
canvas is exactly width*32 x height*32. Renders go to out/ (gitignored)."""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUBY = r"C:\Ruby33-x64\bin\ruby.exe"
sys.path.insert(0, str(ROOT / "renderer"))
import render as R  # noqa: E402

OUT = ROOT / "out"
OUT.mkdir(exist_ok=True)

# tileset metadata once
ts_json = OUT / "tilesets.json"
ts_json.write_bytes(subprocess.run(
    [RUBY, str(ROOT / "codec" / "cli.rb"), "dump-tilesets", str(ROOT / "sample" / "Tilesets.rxdata")],
    capture_output=True, check=True).stdout)
tilesets = json.loads(ts_json.read_text())

ok = True
for m in sorted((ROOT / "sample").glob("Map[0-9][0-9][0-9].rxdata")):
    ir = json.loads(subprocess.run(
        [RUBY, str(ROOT / "codec" / "cli.rb"), "to-ir", str(m)],
        capture_output=True, check=True).stdout)
    placed, size = R.render(ir, tilesets, str(ROOT / "sample" / "Graphics"),
                            str(OUT / f"{m.stem}.png"))
    exp = (ir["tiles"]["xsize"] * 32, ir["tiles"]["ysize"] * 32)
    problems = []
    if placed["missing"] != 0:
        problems.append(f"{placed['missing']} unresolved tiles")
    if size != exp:
        problems.append(f"size {size} != expected {exp}")
    if problems:
        ok = False
        print(f"{m.name}  [FAIL]  {'; '.join(problems)}")
    else:
        print(f"{m.name}  [PASS]  {size[0]}x{size[1]}  "
              f"reg={placed['regular']} auto={placed['autotile']}")

print("\nM2", "PASS -- all corpus maps render with every tile resolved."
      if ok else "FAIL")
sys.exit(0 if ok else 1)
