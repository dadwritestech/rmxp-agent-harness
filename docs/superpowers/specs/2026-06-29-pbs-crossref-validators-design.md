# PBS cross-ref validators (M3 V-layer completion)

Date: 2026-06-29
Status: approved, pre-implementation

## Problem

M3 shipped five deterministic map validators (table dims, tile range, event
bounds, warp integrity, reachability) but the handover's promised
`encounter and trainer cross-refs against PBS` were never built. The V surface
of the H contract is therefore incomplete: nothing checks that a map's wild
encounter table references real species at sane levels, and nothing checks that
the PBS data itself is internally consistent.

This work completes that surface against the PBS files Pokemon Essentials v21.1
already ships. It needs no Showdown->PBS converter (that parallel track is
deferred until the demo game needs modern dex data).

## Scope

In:
- Map-keyed wild-encounter validation, folded into the existing per-map report.
- Map-independent PBS internal-integrity validation, as a separate report.

Out (deliberate):
- Trainer cross-refs via `pbTrainerBattle` shallow-parse of opaque event
  scripts. More fragile string parsing; not worth it for this pass.
- PBS round-trip / editing. This is read-only validation, not a codec.
- The Showdown->PBS converter.

## Architecture: one loader, two entry points

### `codec/pbs.rb` (new) - read-only PBS loader

Two grammars.

Schema files (`pokemon.txt`, `moves.txt`, `abilities.txt`, `types.txt`): the
`[KEY]` + `Key = Value` block grammar. Parsed into `{ id => {field => raw} }`.
Only the fields the cross-refs need are parsed; everything else is skipped
(a validator, not a round-trip codec, so unknown fields need no preservation):
- pokemon: `Types`, `Abilities`, `HiddenAbilities`, `Moves`, `TutorMoves`,
  `EggMoves`, `Evolutions`
- moves: `Type`
- types: `Weaknesses`, `Resistances`, `Immunities`
- abilities: id only (existence set)

`encounters.txt` (custom indented grammar): `[mapID]` / `[mapID,version]` ->
type-header lines (`Land,21`) -> slot lines `prob,SPECIES,min[,max]`. Parsed
into `{ map_id => [ {type, step_chance, slots:[{prob,species,min,max}]} ] }`.

Degrades gracefully: a missing file yields an empty table for that category;
dependent checks that need it are skipped (same pattern as `map_dims` being
partial in the current warp check).

### Entry point 1: encounter cross-ref, folded into `validate()`

`validate()` gains an optional `pbs:` arg. When supplied,
`check_encounters(issues, map_id, pbs)` runs against the map's `[map_id]`
section(s). No section for a map id is not an error (most maps have no wild
Pokemon) - silent skip.

Codes:
- `ENCOUNTER_SPECIES_MISSING` (ERROR) - slot species absent from `pokemon.txt`.
- `ENCOUNTER_LEVEL_RANGE` (ERROR) - min>max, or level outside 1..MAXIMUM_LEVEL.
- `ENCOUNTER_TYPE_UNKNOWN` (WARN) - header not in the known v21.1
  `GameData::EncounterType` set.

Verified facts (extracted from the project's compiled `Data/Scripts.rxdata`,
not assumed - this is exactly the kind of version-specific constant the handover
warns against guessing):
- v21.1 `EncounterType` carries only `id`, `type`
  (`:land/:cave/:water/:fishing/:contest/:none`), and `trigger_chance`. There is
  NO per-type slot count or density. Encounter lists are arbitrary-length
  weighted lists, and slot probabilities are RELATIVE weights, not a percentage
  that sums to 100. So there is deliberately no `ENCOUNTER_SLOT_COUNT` and no
  prob-sum check - both would enforce a rule v21.1 does not have.
- The 21 valid type ids are embedded as a constant in `pbs.rb` with a comment
  citing the v21.1 source: Land, LandDay, LandNight, LandMorning, LandAfternoon,
  LandEvening, PokeRadar (all :land); Cave, CaveDay, CaveNight, CaveMorning,
  CaveAfternoon, CaveEvening (:cave); Water, WaterDay, WaterNight, WaterMorning,
  WaterAfternoon, WaterEvening (:water); RockSmash (:none); BugContest
  (:contest). An unknown header -> `ENCOUNTER_TYPE_UNKNOWN`.
- `Settings::MAXIMUM_LEVEL = 100` (verified); minimum level is 1. Embedded as a
  constant, overridable.

### Entry point 2: PBS integrity, separate `validate_pbs(pbs)`

Map-independent graph check over the loaded PBS. Returns the same
`{ ok, counts, issues }` shape as the map report, keyed by category counts
instead of `map_id`.

Codes (ERROR unless noted):
- `PBS_MOVE_MISSING` - a species' `Moves/TutorMoves/EggMoves` names a move
  absent from `moves.txt`.
- `PBS_ABILITY_MISSING` - `Abilities/HiddenAbilities` names an unknown ability.
- `PBS_TYPE_MISSING` - a species' or move's type names a type absent from
  `types.txt`.
- `PBS_EVOLUTION_MISSING` - `Evolutions` points to an unknown species.
- `PBS_TYPE_RELATION_MISSING` (WARN) - a type's
  `Weaknesses/Resistances/Immunities` names an unknown type.

## Surfaces (mirror existing patterns)

- CLI (`codec/cli.rb`): existing `validate <data_dir> <map>` auto-picks up PBS
  if `<data_dir>/PBS/` exists; new verb `validate-pbs <pbs_dir>`.
- Pi (`.pi/extensions/rmxp.ts`): new tool `rmxp_validate_pbs {pbs_dir}`;
  `rmxp_validate` returns encounter issues for free once the data dir has
  `PBS/`.
- `docs/SKILL.md` / `docs/writeup.md`: add the V rows and the `validate-pbs`
  verb; update the writeup's "PBS cross-refs" line from stubbed to shipped.

## Test fixture and tests

The public repo's `sample/` is synthetic with no PBS. Add a tiny synthetic
`sample/PBS/` (a handful of species/moves/abilities/types + an `encounters.txt`
referencing the sample map ids), generated by extending `tools/make_sample.rb` -
the same synthetic-fixture discipline that replaced the copyrighted corpus.

- `tests/m3_validate.rb` gains encounter cases: a good table passes; a
  deliberately broken slot (unknown species, inverted levels) flags the right
  codes.
- `tests/m3_pbs.rb` (new): clean synthetic PBS passes `validate_pbs`; a seeded
  dangling move/ability/evolution flags the right code.

## Design rationale

- The encounter cross-ref is the only map-scoped check here, so it folds into
  `validate()`; the integrity checks are a global graph and get their own
  entry point rather than being forced per-map.
- Reusing the "degrade gracefully when a registry is absent" pattern keeps the
  public synthetic repo runnable without shipping a full Pokedex.
