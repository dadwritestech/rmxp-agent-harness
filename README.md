# RMXP agent harness

Make RPG Maker XP maps legible to and editable by an LLM through their persisted
`.rxdata`, not the GUI. Edit a JSON intermediate representation, validate it
deterministically, render to an image for sight, and keep the real engine as the
authority for how a map actually looks.

This is a worked example of an agent harness for software that has a rich
persisted format and **no external editing API**, a case the
[CLI-Anything](https://github.com/HKUDS/CLI-Anything) taxonomy does not yet cover.
See [docs/writeup.md](docs/writeup.md) for the argument and
[upstream/OFFER.md](upstream/OFFER.md) for the contribution plan.

## What works

- **Byte-exact codec** (`codec/`, Ruby). Loads `.rxdata` (Ruby Marshal) to a
  JSON-clean IR and back, byte-for-byte. Verified on a synthetic fixture here and,
  locally, on all 69 maps of Pokemon Essentials v21.1.
- **Frozen IR schema** (`schema/map_ir.schema.json`).
- **Renderer** (`renderer/render.py`, Pillow). IR to PNG, advisory only.
- **Validators** (`codec/validators.rb`). Tile range, table dims, event bounds,
  warp integrity, reachability. JSON report, nonzero exit on error.
- **Agent tools** (`.pi/extensions/rmxp.ts`). snapshot / read / act / validate /
  render as [Pi](https://github.com/badlogic/pi-mono) tools, plus a supervisor
  that manages the local model-server lifecycle.

## Quickstart

```bash
# generate the self-contained synthetic test fixture (no game assets needed)
ruby tools/make_sample.rb
python tools/make_sample_png.py

# run the suite
ruby   tests/m0_roundtrip.rb     # codec round-trip is byte-exact
python tests/m1_schema.py        # IR conforms to the frozen schema
python tests/m2_render.py        # every map renders, every tile resolves
ruby   tests/m3_validate.rb      # clean maps clean, broken map flagged
```

Set `RMXP_RUBY` / `RMXP_PYTHON` if those interpreters are not on PATH.

## CLI

```
ruby codec/cli.rb snapshot  <map.rxdata> [Tilesets.rxdata]
ruby codec/cli.rb read      <map.rxdata> region <x> <y> <w> <h> <layer>
ruby codec/cli.rb act       <map.rxdata> <op.json> <out.rxdata>
ruby codec/cli.rb validate  <data_dir>   <map.rxdata>
ruby codec/cli.rb to-ir / to-rxdata / dump-tilesets
python renderer/render.py <ir.json> <tilesets.json> <graphics_dir> <out.png>
```

See [docs/SKILL.md](docs/SKILL.md) for the agent-facing tool surface.

## Game assets

This repository ships an **original synthetic fixture** under `sample/`. It
contains no game data. The map corpus used for the full 69-map validation is
copyrighted Pokemon Essentials content and is not redistributed here. To reproduce
that result, point the verifier at your own Essentials `Data` directory:

```bash
ruby tests/verify_essentials.rb "/path/to/Pokemon Essentials/Data"
```

## License

MIT. See [LICENSE](LICENSE).
