# RMXP Harness — agent tool surface (D)

Edit RPG Maker XP maps through their persisted `.rxdata`, not the GUI. The agent
inspects and edits a JSON intermediate representation; a real renderer draws the
map for sight; deterministic validators are the source of truth. This document is
the discovery surface: what the tools are and how to drive them.

## Setup

- Ruby 3.3+ on PATH (`RMXP_RUBY` overrides the interpreter path).
- Python 3 with Pillow (`RMXP_PYTHON`, default `python`).
- The Pi extension auto-loads from `.pi/extensions/rmxp.ts`.
- A map's data dir must contain `Tilesets.rxdata` and `MapInfos.rxdata` beside it,
  and `Graphics/` (Essentials layout) for rendering.

## Tools

| Tool | H verb | Purpose |
|------|--------|---------|
| `rmxp_snapshot {map}` | I | Bounded summary: dims, tileset, per-layer fill stats, events + parsed warps. Never dumps tile arrays. |
| `rmxp_read {map,x,y,w,h,layer}` | I | Read a rectangle of tile ids from one layer. |
| `rmxp_act {map,operation,...}` | C | Edit in place: `set_tile`, `fill_region`, `move_event`, `set_warp`. Bounds-checked. |
| `rmxp_validate {map}` | V | Deterministic report: tile-range, table dims, event bounds, warp integrity, reachability. |
| `rmxp_render {map}` | R | Render to PNG and return the image. Advisory only — validators are truth. |

## Loop

1. `rmxp_snapshot` to learn dimensions, tileset, ids, events.
2. `rmxp_read` for any specific tiles you need before editing.
3. `rmxp_act` to make a narrow edit (one operation).
4. `rmxp_validate` — treat any `ERROR` as a regression to fix before continuing.
5. `rmxp_render` to eyeball the result (never to decide the next edit).

State lives under git: each edit is a minimal diff to the `.rxdata`, because the
codec round-trips byte-exactly (only the touched fields change).

## Scope (v1)

Editable: tile layers, event positions, and existing Transfer Player warps.
Opaque pass-through: full event command lists (author complex scripting in RMXP).
Autotiles render naively; mkxp-z is the ground-truth renderer if edges drift.

## Verbs without Pi

Every tool is a thin bridge over `codec/cli.rb`:

```
ruby codec/cli.rb snapshot  <map.rxdata> [Tilesets.rxdata]
ruby codec/cli.rb read      <map.rxdata> region <x> <y> <w> <h> <layer>
ruby codec/cli.rb act       <map.rxdata> <op.json> <out.rxdata>
ruby codec/cli.rb validate  <data_dir>   <map.rxdata>
ruby codec/cli.rb to-ir     <map.rxdata>            # full IR (schema/map_ir.schema.json)
ruby codec/cli.rb to-rxdata <ir.json> <out.rxdata>
ruby codec/cli.rb dump-tilesets <Tilesets.rxdata>
python renderer/render.py <map.ir.json> <tilesets.json> <graphics_dir> <out.png>
```
