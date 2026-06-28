/**
 * RMXP harness -- Pi extension (the D surface).
 *
 * Exposes the codec / validators / renderer as agent-callable tools so an LLM
 * can drive an RPG Maker XP map end-to-end: snapshot -> read -> act -> validate
 * -> render, editing persisted .rxdata (never the GUI, never pixels-as-truth).
 *
 * The heavy lifting lives in Ruby (codec/cli.rb) and Python (renderer/render.py);
 * this file is a thin, typed bridge over them.
 *
 * Subprocesses run via pi's argv-array runner (no shell, no string
 * interpolation), so map paths and ids cannot inject commands.
 *
 * Conventions:
 *   - `map` is a path to a MapNNN.rxdata, resolved against the session cwd.
 *   - Tilesets.rxdata / MapInfos.rxdata are expected beside the map (its data
 *     dir); Graphics/ is expected as `<dataDir>/Graphics` (Essentials layout).
 */
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { StringEnum } from "@mariozechner/pi-ai";
import { fileURLToPath } from "node:url";
import { dirname, resolve, basename } from "node:path";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const EXT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(EXT_DIR, "..", "..");            // D:/Harness
const CODEC_CLI = join(ROOT, "codec", "cli.rb");
const RENDER_PY = join(ROOT, "renderer", "render.py");
const RUBY = process.env.RMXP_RUBY || "C:\\Ruby33-x64\\bin\\ruby.exe";
const PYTHON = process.env.RMXP_PYTHON || "python";

export default function rmxp(pi: ExtensionAPI) {
  // argv-array runner (no shell); bound so call sites stay free of shell semantics
  const spawn = pi.exec.bind(pi);

  const resolveMap = (ctx: ExtensionContext, map: string) => {
    const p = resolve(ctx.cwd, map.replace(/^@/, ""));
    const dataDir = dirname(p);
    return {
      map: p,
      dataDir,
      tilesets: join(dataDir, "Tilesets.rxdata"),
      mapInfos: join(dataDir, "MapInfos.rxdata"),
      graphics: join(dataDir, "Graphics"),
    };
  };

  // run a command, throw on nonzero so the tool surfaces a clean error to the LLM
  async function run(cmd: string, args: string[], cwd: string, signal?: AbortSignal) {
    const r = await spawn(cmd, args, { cwd, signal });
    if (r.code !== 0) {
      throw new Error(`${basename(cmd)} ${args.join(" ")}\nexit ${r.code}\n${r.stderr || r.stdout}`);
    }
    return r.stdout;
  }
  const ruby = (args: string[], cwd: string, signal?: AbortSignal) =>
    run(RUBY, [CODEC_CLI, ...args], cwd, signal);

  const text = (s: string) => ({ content: [{ type: "text" as const, text: s }], details: {} });

  // ---- snapshot (I) ----
  pi.registerTool({
    name: "rmxp_snapshot",
    label: "RMXP snapshot",
    description:
      "Bounded summary of an RMXP map: dimensions, tileset, per-layer fill stats " +
      "(top tile ids), and the event list with positions and parsed warp targets. " +
      "Never returns full tile arrays. Start here before editing.",
    promptSnippet: "Summarize an RMXP map (dims, tileset, layers, events, warps)",
    parameters: Type.Object({ map: Type.String({ description: "path to MapNNN.rxdata" }) }),
    async execute(_id, params, signal, _u, ctx) {
      const r = resolveMap(ctx, params.map);
      return text(await ruby(["snapshot", r.map, r.tilesets], r.dataDir, signal));
    },
  });

  // ---- read (I drill-down) ----
  pi.registerTool({
    name: "rmxp_read",
    label: "RMXP read region",
    description: "Read a rectangular block of tile ids from one layer (0=ground,1,2). Use after snapshot to inspect specific tiles before acting.",
    promptSnippet: "Read a tile-id region from an RMXP map layer",
    parameters: Type.Object({
      map: Type.String(),
      x: Type.Integer(), y: Type.Integer(),
      w: Type.Integer({ description: "width in tiles" }),
      h: Type.Integer({ description: "height in tiles" }),
      layer: Type.Integer({ minimum: 0, maximum: 2 }),
    }),
    async execute(_id, p, signal, _u, ctx) {
      const r = resolveMap(ctx, p.map);
      return text(await ruby(
        ["read", r.map, "region", `${p.x}`, `${p.y}`, `${p.w}`, `${p.h}`, `${p.layer}`],
        r.dataDir, signal));
    },
  });

  // ---- validate (V) ----
  pi.registerTool({
    name: "rmxp_validate",
    label: "RMXP validate",
    description:
      "Run deterministic validators on a map (tile-range, table dims, event bounds, " +
      "warp integrity vs MapInfos, reachability). Returns a JSON report; ERROR issues " +
      "mean the map is broken. Always validate after acting.",
    promptSnippet: "Validate an RMXP map (tiles, warps, reachability)",
    parameters: Type.Object({ map: Type.String() }),
    async execute(_id, p, signal, _u, ctx) {
      const r = resolveMap(ctx, p.map);
      // validate exits nonzero on ERROR; capture either way and return the report
      const res = await spawn(RUBY, [CODEC_CLI, "validate", r.dataDir, r.map], { cwd: r.dataDir, signal });
      return text(res.stdout || res.stderr);
    },
  });

  // ---- act (C) ----
  pi.registerTool({
    name: "rmxp_act",
    label: "RMXP act",
    description:
      "Edit a map in place. Operations: set_tile {x,y,layer,tile_id}; " +
      "fill_region {x,y,w,h,layer,tile_id}; move_event {id,x,y}; " +
      "set_warp {event_id,target_map,x,y,direction?} (edits an existing Transfer " +
      "Player command). Bounds-checked; writes the .rxdata in place. Validate after.",
    promptSnippet: "Edit an RMXP map: set/fill tiles, move event, set warp",
    promptGuidelines: [
      "Call rmxp_snapshot before rmxp_act so you edit with correct dimensions and ids.",
      "Call rmxp_validate after rmxp_act; treat any ERROR as a regression to fix.",
    ],
    parameters: Type.Object({
      map: Type.String(),
      operation: StringEnum(["set_tile", "fill_region", "move_event", "set_warp"] as const),
      x: Type.Optional(Type.Integer()),
      y: Type.Optional(Type.Integer()),
      w: Type.Optional(Type.Integer()),
      h: Type.Optional(Type.Integer()),
      layer: Type.Optional(Type.Integer({ minimum: 0, maximum: 2 })),
      tile_id: Type.Optional(Type.Integer()),
      id: Type.Optional(Type.Integer({ description: "event id for move_event" })),
      event_id: Type.Optional(Type.Integer({ description: "event id for set_warp" })),
      target_map: Type.Optional(Type.Integer()),
      direction: Type.Optional(Type.Integer()),
    }),
    async execute(_id, p, signal, _u, ctx) {
      const r = resolveMap(ctx, p.map);
      const op: Record<string, unknown> = { op: p.operation };
      for (const k of ["x", "y", "w", "h", "layer", "tile_id", "id", "event_id", "target_map", "direction"]) {
        if ((p as any)[k] !== undefined) op[k] = (p as any)[k];
      }
      const tmp = join(mkdtempSync(join(tmpdir(), "rmxp-")), "op.json");
      writeFileSync(tmp, JSON.stringify(op));
      return text(await ruby(["act", r.map, tmp, r.map], r.dataDir, signal));
    },
  });

  // ---- render (R) ----
  pi.registerTool({
    name: "rmxp_render",
    label: "RMXP render",
    description:
      "Render a map to PNG and return the image so you can see it. Advisory only: " +
      "use it to sanity-check edits, never as the source of truth for further edits " +
      "(the validators are truth). Autotiles are naive in v1.",
    promptSnippet: "Render an RMXP map to a PNG image",
    parameters: Type.Object({ map: Type.String() }),
    async execute(_id, p, signal, _u, ctx) {
      const r = resolveMap(ctx, p.map);
      const work = mkdtempSync(join(tmpdir(), "rmxp-"));
      const tsJson = join(work, "tilesets.json");
      const irJson = join(work, "map.ir.json");
      const png = join(work, basename(r.map).replace(/\.rxdata$/, ".png"));
      writeFileSync(tsJson, await ruby(["dump-tilesets", r.tilesets], r.dataDir, signal));
      writeFileSync(irJson, await ruby(["to-ir", r.map], r.dataDir, signal));
      const log = await run(PYTHON, [RENDER_PY, irJson, tsJson, r.graphics, png], r.dataDir, signal);
      const b64 = readFileSync(png).toString("base64");
      return {
        content: [
          { type: "text" as const, text: log.trim() },
          { type: "image" as const, data: b64, mimeType: "image/png" },
        ],
        details: { png },
      };
    },
  });

  pi.on("session_start", async (_e, ctx) => {
    ctx.ui.notify("RMXP harness tools loaded: snapshot, read, validate, act, render", "info");
  });
}
