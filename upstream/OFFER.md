# Offering the RMXP harness to CLI-Anything

This document is the contribution plan for upstreaming this harness to
[HKUDS/CLI-Anything](https://github.com/HKUDS/CLI-Anything). It maps what exists
to their HARNESS.md contract, names the gaps honestly, and proposes one amendment
to the contract.

## Why this belongs upstream

CLI-Anything's catalog covers software with a scriptable backend (Blender via
`bpy`, GIMP, Kdenlive) and software with an in-process bridge. RPG Maker XP is
neither. It has a persisted format (`.rxdata`, Ruby Marshal) and no external
editing API, and its real engine (mkxp-z) runs the finished game rather than
serving edits or headless renders. This is a third harness mode their taxonomy
does not yet cover: a persisted-format lift with no editing API. See
[../docs/writeup.md](../docs/writeup.md) for the full argument.

CONTRIBUTING.md supports standalone-repo harnesses directly: host the CLI in your
own repository and submit a registry-only PR whose entry sets `source_url` to the
repo and `skill_md` to the raw URL of `docs/SKILL.md`. No code is required inside
their monorepo. The plan here follows that path: introduce the harness via an
issue first (their stated norm), then open the registry-only PR.

This harness also ships a working Pi extension
([../.pi/extensions/rmxp.ts](../.pi/extensions/rmxp.ts)) plus a supervisor that
manages the local model-server lifecycle, which is relevant given their recent
work on Pi Coding Agent support.

## Surface mapping (their contract -> this harness)

| HARNESS.md verb group | This harness today | Notes |
|---|---|---|
| `info` (project state) | `cli.rb snapshot` | bounded summary, never full tile arrays |
| Inspection drill-down | `cli.rb read region ...` | one layer, a rectangle |
| Core operations (`Command`) | `cli.rb act` (set_tile, fill_region, move_event, set_warp) | bounds-checked; in place |
| `status` / `Verification` | `cli.rb validate` | JSON report, nonzero exit on ERROR |
| Import/Export | `cli.rb to-ir` / `to-rxdata` | IR is JSON, schema in `schema/map_ir.schema.json` |
| Preview (`Render`) | `renderer/render.py` | advisory only; see contract amendment below |
| Session/State (`undo`/`history`) | git | every edit is a minimal byte diff |
| Discovery | `docs/SKILL.md` | the agent-facing tool surface |
| `--json` output | native | every command emits JSON |

## What is done

- Byte-exact codec, verified on all 69 Pokemon Essentials v21.1 maps
  (`tests/m0_roundtrip.rb`). This is the credibility anchor.
- Frozen IR JSON Schema (`schema/map_ir.schema.json`, `tests/m1_schema.py`).
- Renderer and validators with regression guards
  (`tests/m2_render.py`, `tests/m3_validate.rb`).
- Working Pi extension and a verified end-to-end agent loop with a local model
  (`tests/m4_extension_probe.ts`).
- SKILL.md discovery surface.

## Gaps to close before a PR

CLI-Anything harnesses are Python Click CLIs with a specific file layout. This
harness is a Ruby codec plus a Python renderer plus a TypeScript agent extension.
A faithful contribution needs:

1. **Python entry point** `cli-anything-rmxp` (Click, REPL as default) that shells
   to the Ruby codec. The codec stays Ruby (Marshal fidelity is non-negotiable);
   the wrapper just adapts the verb names and `--json` convention.
2. **Package layout**: namespace `cli_anything.rmxp` (PEP 420), `utils/rmxp_backend.py`
   wrapping the Ruby/Python subprocesses, `utils/repl_skin.py` copied from the plugin.
3. **Required files**: `README.md`, `TEST.md` (test plan plus results),
   `tests/test_core.py`, `tests/test_full_e2e.py` invoking the installed command.
4. **Verb renaming** to match their surface (`info`, `status`, `undo`/`redo`,
   `new`/`open`/`save`/`close`).
5. **registry.json entry**: see [registry-entry.json](registry-entry.json), append
   to the top-level `clis` array, fill the placeholders.

## Proposed contract amendment (the substantive contribution)

HARNESS.md states: "The real software is a hard dependency. The CLI MUST invoke
the actual application for rendering and export. Do NOT reimplement rendering in
Python." This is correct when the backend can render on demand. It has no
compliant implementation when the backend cannot, which is exactly the
persisted-format-with-no-API case.

The render rule is a proxy for a deeper principle: the agent's decisions must be
grounded in the real artifact, not an approximation. Proposed amendment:

> When the backend exposes a headless render/export path, the harness MUST use it,
> and any Python renderer is forbidden. When the backend has no headless
> render/export path, the harness MUST (a) move verification truth onto
> deterministic validators over the persisted format, and (b) mark any approximate
> renderer as advisory, never an input to a `Command`. The real engine, if it can
> run the artifact, remains the render-truth oracle for fidelity questions only.

This keeps the principle intact (decisions grounded in truth) while giving the
no-API case a pattern it can actually satisfy. The RMXP harness is the worked
example.
