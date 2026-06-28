// M4 acceptance probe. Run inside Pi (so the extension's runtime deps resolve):
//
//   pi --offline --print --no-tools -e tests/m4_extension_probe.ts "ok"
//   cat out/_m4_probe.json   # -> { ok: true, tools:[...5], steps:{...} }
//
// It builds a self-contained mini Essentials project under out/scratch (rxdata +
// Graphics), loads .pi/extensions/rmxp.ts with a mock `pi` whose exec really
// shells out, and drives snapshot -> act -> validate -> render against it. This
// proves the D-surface tools register and execute end-to-end without an LLM.
import { execFile } from "node:child_process";
import { writeFileSync, mkdirSync, copyFileSync, cpSync } from "node:fs";
import { join } from "node:path";
import rmxpFactory from "../.pi/extensions/rmxp.ts";

const sh = (cmd: string, args: string[], opts: any): Promise<any> =>
  new Promise((res) =>
    execFile(cmd, args, { cwd: opts?.cwd, maxBuffer: 1e8 }, (err: any, stdout: any, stderr: any) =>
      res({ stdout: String(stdout || ""), stderr: String(stderr || ""), code: err?.code ?? 0, killed: false })));

export default function probe(_realPi: any) {
  (async () => {
    const out: any = { tools: [], steps: {} };
    try {
      const root = process.cwd();
      const dir = join(root, "out", "scratch", "m4");
      mkdirSync(dir, { recursive: true });
      for (const f of ["Tilesets.rxdata", "MapInfos.rxdata", "Map001.rxdata"])
        copyFileSync(join(root, "sample", f), join(dir, f));
      cpSync(join(root, "sample", "Graphics"), join(dir, "Graphics"), { recursive: true });

      const tools: Record<string, any> = {};
      rmxpFactory({ exec: sh, registerTool: (t: any) => (tools[t.name] = t), registerCommand: () => {}, on: () => {}, setActiveTools: () => {} });
      out.tools = Object.keys(tools).sort();

      const ctx = { cwd: root };
      const map = "out/scratch/m4/Map001.rxdata";

      const snap = JSON.parse((await tools.rmxp_snapshot.execute("1", { map }, undefined, undefined, ctx)).content[0].text);
      out.steps.snapshot = { events: snap.event_count, dims: snap.dimensions };

      const act = JSON.parse((await tools.rmxp_act.execute("2",
        { map, operation: "fill_region", x: 0, y: 0, w: 3, h: 3, layer: 1, tile_id: 392 }, undefined, undefined, ctx)).content[0].text);
      out.steps.act = act.applied?.[0]?.detail;

      const val = JSON.parse((await tools.rmxp_validate.execute("3", { map }, undefined, undefined, ctx)).content[0].text);
      out.steps.validate_ok = val.ok;

      const ren = await tools.rmxp_render.execute("4", { map }, undefined, undefined, ctx);
      out.steps.render = {
        contentTypes: ren.content.map((c: any) => c.type),
        imageBytes: ren.content.find((c: any) => c.type === "image")?.data?.length || 0,
      };

      out.ok = out.tools.length === 5 && out.steps.validate_ok === true && out.steps.render.imageBytes > 0;
    } catch (e: any) {
      out.ok = false;
      out.error = e?.message || String(e);
    }
    writeFileSync(join(process.cwd(), "out", "_m4_probe.json"), JSON.stringify(out, null, 2));
  })();
}
