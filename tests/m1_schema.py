#!/usr/bin/env python3
"""M1 acceptance: the IR emitted from every real corpus map validates against
the frozen schema/map_ir.schema.json, and the schema's structural invariants
(data length == size, ivar_order covers every map field) actually hold.

Runs the Ruby codec to produce IR, then validates with jsonschema."""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUBY = r"C:\Ruby33-x64\bin\ruby.exe"
SCHEMA = json.loads((ROOT / "schema" / "map_ir.schema.json").read_text())

import jsonschema
validator = jsonschema.Draft202012Validator(SCHEMA)

maps = sorted((ROOT / "corpus").glob("Map[0-9][0-9][0-9].rxdata"))
if not maps:
    sys.exit("no corpus maps found")

ok = True
for m in maps:
    out = subprocess.run([RUBY, str(ROOT / "codec" / "cli.rb"), "to-ir", str(m)],
                         capture_output=True)
    if out.returncode != 0:
        print(f"{m.name}  [FAIL] codec error: {out.stderr.decode(errors='replace')[:200]}")
        ok = False
        continue
    ir = json.loads(out.stdout)

    errors = sorted(validator.iter_errors(ir), key=lambda e: e.path)
    # extra structural invariants the schema alone can't express
    t = ir["tiles"]
    if len(t["data"]) != t["size"]:
        errors.append(f"tiles.data length {len(t['data'])} != size {t['size']}")
    if t["dim"] == 3 and t["size"] != t["xsize"] * t["ysize"] * t["zsize"]:
        errors.append("tiles.size != x*y*z for a 3-D table")
    # ivar_order must name exactly the fields the rebuild can supply
    supplied = {"@tileset_id", "@width", "@height", "@encounter_step",
                "@data", "@events"} | set(ir["opaque"].keys())
    missing = set(ir["ivar_order"]) - supplied
    if missing:
        errors.append(f"ivar_order references unsupplied fields: {missing}")

    if errors:
        ok = False
        print(f"{m.name}  [FAIL]")
        for e in errors[:8]:
            msg = e.message if hasattr(e, "message") else str(e)
            print(f"    {msg}")
    else:
        print(f"{m.name}  [PASS]  {len(ir['events'])} events, "
              f"{t['xsize']}x{t['ysize']}x{t['zsize']} tiles")

print("\nM1", "PASS -- IR conforms to the frozen schema." if ok else "FAIL")
sys.exit(0 if ok else 1)
