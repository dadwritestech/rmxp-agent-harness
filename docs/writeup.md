# A third mode for agent harnesses: lifting a persisted format that has no editing API

Most of the work that makes a desktop application usable by an agent assumes one
thing: that the application has a scriptable backend. Blender has `bpy`. GIMP has
script-fu. Kdenlive has `melt`. You can lift that backend into a stateful CLI,
hand it JSON, and let the real engine do the rendering and the saving. The agent
never touches pixels and never touches the binary format. It speaks to an API
that already exists.

A large class of software does not work that way. It has a rich, documented,
long-lived persisted format and no external API an agent can drive to edit it.
RPG Maker XP is the clean example. Its maps live in `.rxdata` files, a Ruby
Marshal dump that the engine reads at load time. There is no headless editor, no
scripting bridge, no `bpy` equivalent. The one real engine that can read these
files, mkxp-z, runs a *game*. It does not edit maps and it does not render an
arbitrary map on request.

This note is about building an agent harness for that case, and what it taught me
about where the standard harness contract bends.

## Finding the contract I was about to invent

I started from a concrete goal: make RMXP legible to and editable by a language
model through its data rather than its GUI, then use that to build a Pokemon fan
game on RMXP plus Pokemon Essentials. I reasoned my way to an architecture before
reading any of the literature. Edit a structured intermediate representation, not
the binary. Validate the result deterministically. Render to an image only for
sight, never as the source of truth. Keep the real engine as the authority for
how a map actually looks.

Then I found CLI-Anything (HKUDS, arXiv:2606.03854), and it was substantially the
thing I was about to build, published, implemented, and ahead. Its contract names
six surfaces a harness should expose. State, the working data and its history.
Command, the verbs that change it. Inspection, the bounded read surface. Render,
the relation from state to a viewable artifact. Verification, the checks that say
whether the state is valid. Discovery, the way an agent finds and learns the tool.
Their "verification becomes execution" was my validators-as-primitive. Their
insistence that previews be honest views of the real backend, not toy renderers or
screen scrapes, was my render quarantine. The convergence was not a coincidence.
It is what the problem pushes you toward.

The useful move after that is not to claim novelty. It is to find the place where
the published contract does not fit, and to document it well enough that the next
person does not have to rediscover it.

## Two modes, and the gap between them

CLI-Anything builds harnesses in two ways. The first lifts a mature backend API
into a stateful CLI: Blender via `bpy`, where agent-facing JSON is lowered to a
native script and the real engine renders and verifies. The second builds an
in-process bridge where state lives inside a running application: a mod inside a
game's runtime exposing decision state over loopback.

RMXP fits neither. It has a Blender-style persisted format, the `.rxdata` files.
But it has no `bpy`, no editing API any external process can call. And its real
engine is available only to run the finished game, not to serve edits or renders.
So the backend you would lift does not exist, and the backend you do have cannot
be driven for the operation you need.

That is the third mode: a persisted-format lift with no editing API. You edit the
format directly because nothing else will let you, and you treat the real engine
as a render-truth oracle you can consult but not command.

## The hard part, with the receipt

If you are going to edit a binary format directly, the single thing that decides
whether the whole approach is safe is the round-trip. Load a real file, convert it
to your working representation, rebuild it, write it back. If the bytes the engine
reads are not the bytes it would have read before, you are corrupting people's
work, and no amount of clever tooling on top can fix that. I made this the gate.
Nothing else shipped until it passed.

The `.rxdata` format is Ruby Marshal, version 4.8, frozen since Ruby 1.8. A modern
Ruby can load it given the right class definitions. Three things had to be exactly
right.

First, the `Table` class, which holds the tile grid. It serializes through its own
binary protocol: five little-endian 32-bit integers (dimension, width, height,
depth, count) followed by the tile ids as 16-bit integers. Preserve all five
header integers verbatim rather than recomputing them, unpack and repack the data
at a fixed width, and the bytes survive.

Second, string encoding. RGSS strings are raw byte strings tagged `ASCII-8BIT`.
JSON transport forces them to UTF-8, which makes Marshal stamp an encoding marker
and changes the byte stream. The fix is to carry each string's original encoding
in the intermediate representation and restore it on rebuild. `force_encoding`
changes only the tag, not the bytes, so the text stays readable in the IR and the
re-dump stays exact.

Third, instance-variable order. Marshal writes object fields in assignment order,
and that order varies from file to file (one map I tested swaps two fields
relative to the others, an artifact of its edit history). Record the order in the
IR and replay it on rebuild.

With those three solved, every one of the 69 maps in Pokemon Essentials v21.1
round-trips byte-for-byte through the full chain: load, to IR, serialize to JSON,
parse back, rebuild, re-dump, identical to the original file. Not semantically
equal. Identical. That is a stronger guarantee than the gate required, and it buys
a free regression oracle: any future change to the codec that alters a single byte
is caught by a plain comparison.

## Where the contract bends: rendering

CLI-Anything is blunt about rendering. "The real software is a hard dependency.
The CLI MUST invoke the actual application for rendering and export. Do NOT
reimplement rendering in Python." For Blender or GIMP this is exactly right. The
backend can render on demand, so any Python reimplementation is a worse copy that
will drift from truth.

RMXP cannot satisfy this rule, because the operation the rule assumes does not
exist. There is no headless "render this map to a PNG" path. mkxp-z can run the
game, which is closer to screen-scraping the thing the contract also warns against.
So the rule, taken literally, has no compliant implementation here.

The honest resolution is to stop asking rendering to be truth. In this harness the
renderer is a fast Pillow approximation, explicitly advisory, and it never feeds
an editing decision. The authority moves entirely onto deterministic validators:
tile-id range checks against the tileset, table-dimension consistency, event
bounds, warp integrity cross-checked against the project's real map registry, and
a reachability flood-fill. A broken map is caught by a validator with a specific
error code, not by a human noticing the picture looks wrong. The real engine,
mkxp-z, remains the render-truth oracle for fidelity questions, consulted when the
naive renderer is in doubt, never as a step in an edit.

This is the part worth contributing upstream. The contract's render rule is a
proxy for a deeper principle: the agent's decisions must be grounded in the real
artifact, not in an approximation. When the backend can render, the cleanest way
to honor that is to make it render. When the backend cannot, you honor the same
principle by moving truth to deterministic verification and quarantining the
approximate render so it can never be mistaken for ground truth. Same principle,
different mechanism, and the contract should name both.

## The surfaces, concretely

State is the IR (a JSON-clean structure that mirrors the engine's own map object),
the `.rxdata` and rendered PNGs as backend artifacts, and git as history and undo.
Command is a small set of bounded operations: set a tile, fill a region, move an
event, set a warp. The agent never handles the raw 7,740-element tile array; it
asks for narrow edits. Inspection is a bounded snapshot (dimensions, tileset,
per-layer fill stats, the event list with parsed warp targets) plus a region read,
never the full arrays by default. Render is the advisory Pillow path described
above. Verification is the validator suite plus the round-trip oracle. The suite now includes a per-map wild-encounter cross-ref against PBS data (folded into rmxp_validate when a PBS/ dir is present) and a map-independent PBS internal-integrity check (rmxp_validate_pbs), both deterministic and covered by tests/m3_pbs.rb and tests/m3_validate.rb. Discovery
is a SKILL.md describing the verbs and the edit loop.

One detail that matters for verification: warps in RMXP live inside event command
lists, as Transfer Player commands (code 201), and those command lists are the
worst fidelity risk, so the harness treats them as opaque pass-through blobs. To
keep warp validation working anyway, it does a targeted shallow parse of just the
201 command out of an otherwise-opaque page. Everything else in the command list
stays untouched and byte-exact. This is the kind of seam the third mode forces:
you keep most of the format opaque for safety and surgically open the one field
the contract needs.

## It runs

The point of a harness is that an agent can drive it. A local Qwen3.6-27B, served
by ik_llama.cpp across two consumer GPUs and reached through the Pi coding agent,
took a single natural-language instruction and called the tools in order: snapshot
the map, fill a three-by-three region with a given tile on a given layer, validate,
render. The edit landed in the persisted `.rxdata`, which I confirmed by reading
the bytes back independently rather than trusting the model's summary. The model
produced clean, schema-valid tool calls because the inspection surface is bounded
and the command surface is narrow. That asymmetry, wide reads made small and writes
made narrow, is what keeps a map editable by a model inside a token budget.

The server that hosts the model is itself a managed dependency, not a human chore.
A small extension starts it when a turn is about to run against the local endpoint
and stops it when the session ends, reusing a server that is already up rather than
spawning a second one. A harness that needs a human to start a background process
is not finished.

## What contributing means here

The lesson I take from MCP is that it did not win on novelty. It won on a reference
implementation, SDKs, documentation, ergonomics, and distribution. The swing in
this work is not a new protocol. It is to make this kind of harness, the
persisted-format lift with no editing API, easy to build and well documented, and
to prove it on a case nobody had done.

So the contribution to CLI-Anything is three things. A registry entry for the
harness. A worked example of the third mode, with the byte-exact codec as the
credibility anchor. And a small amendment to the render contract: name the case
where the backend cannot render, and specify the substitution, validators as truth
plus a quarantined approximate render, so the next person who hits a format without
an API has a pattern to follow instead of a rule they cannot satisfy.

## Honest limits

The renderer's autotiles are naive in v1; true 48-subtile neighbor blending is not
done, and mkxp-z remains the fidelity fallback. Complex event scripting stays
opaque by design, so the harness authors tiles, positions, and warps, not arbitrary
game logic. The model-server supervisor cleans up on a normal quit but can orphan
the process on a hard crash, because Windows does not cascade child death without a
job object. And the upstream packaging is not finished: CLI-Anything harnesses are
Python Click CLIs, while this one is a Ruby codec with a Python renderer and a
TypeScript agent extension, so a faithful contribution needs a thin Python entry
point that shells to the codec, plus their required test files. None of these
change the result that matters. The format round-trips exactly, the validators
catch what they should, and an agent can drive the whole loop.
