/**
 * llama-supervisor -- make the local model server a managed dependency, not a
 * human chore. When a Pi turn is about to run against the local endpoint
 * (127.0.0.1:8080), ensure the ik_llama.cpp server is up; tear it down when Pi
 * quits -- but only if *we* started it (a hand-run server is left alone).
 *
 * Gating is by the active model's baseUrl, so using the LAN/cloud provider never
 * spawns a 24GB local server.
 *
 * Configure via env: LLAMA_MODEL (required, path to the .gguf), LLAMA_BIN
 * (llama-server, defaults to PATH), LLAMA_PORT, LLAMA_ARGS (extra args). With no
 * LLAMA_MODEL set, auto-start is disabled and you run the server yourself.
 */
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { spawn } from "node:child_process";
import { openSync } from "node:fs";
import { join } from "node:path";

const PORT = process.env.LLAMA_PORT || "8080";
const HOST = "127.0.0.1";
const BASE = `http://${HOST}:${PORT}`;
const BIN = process.env.LLAMA_BIN || "llama-server";   // override if not on PATH
const MODEL = process.env.LLAMA_MODEL || "";           // required to enable auto-start
const ARGS = [
  "-m", MODEL,
  "-ngl", "99", "-sm", "layer", "-ts", "16,16", "-fa", "on", "-c", "16384",
  "--jinja", "--parallel-tool-calls",
  "--host", HOST, "--port", PORT, "-a", "qwen3.6-27b",
  ...(process.env.LLAMA_ARGS ? process.env.LLAMA_ARGS.split(" ").filter(Boolean) : []),
];

export default function llamaSupervisor(pi: ExtensionAPI) {
  let ownedPid: number | null = null;     // set only when WE spawned it
  let ensuring: Promise<void> | null = null;

  const isUp = async (): Promise<boolean> => {
    try {
      const c = new AbortController();
      const t = setTimeout(() => c.abort(), 1000);
      const r = await fetch(`${BASE}/v1/models`, { signal: c.signal });
      clearTimeout(t);
      return r.ok;
    } catch {
      return false;
    }
  };

  const targetsLocal = (ctx: ExtensionContext) => {
    const url = (ctx.model as any)?.baseUrl as string | undefined;
    return !!url && (url.includes(`${HOST}:${PORT}`) || url.includes(`localhost:${PORT}`));
  };

  async function ensureServer(ctx: ExtensionContext) {
    if (ensuring) return ensuring;
    ensuring = (async () => {
      if (await isUp()) return;                         // reuse whatever is serving
      if (!MODEL) {                                     // no model configured -> do not spawn
        ctx.ui.notify(`No server at ${BASE}. Set LLAMA_MODEL to enable auto-start, or start it yourself.`, "error");
        return;
      }
      ctx.ui.notify(`Starting local model server on ${BASE} (model load ~45s)...`, "info");
      const log = openSync(join(ctx.cwd, "out", "llama-supervised.log"), "a");
      const child = spawn(BIN, ARGS, { stdio: ["ignore", log, log], windowsHide: true });
      ownedPid = child.pid ?? null;
      child.on("exit", () => { ownedPid = null; });
      const deadline = Date.now() + 180_000;
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 2000));
        if (await isUp()) { ctx.ui.notify("Local model server ready.", "info"); return; }
      }
      ctx.ui.notify("Local model server did not become ready in time.", "error");
    })().finally(() => { ensuring = null; });
    return ensuring;
  }

  function stopServer() {
    if (ownedPid == null) return;                       // never kill a hand-run server
    const pid = ownedPid;
    ownedPid = null;
    // kill the whole tree on Windows
    spawn("taskkill", ["/PID", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
  }

  // ensure right before a turn, only when this turn will hit the local endpoint
  pi.on("before_agent_start", async (_e, ctx) => {
    if (targetsLocal(ctx)) await ensureServer(ctx);
  });

  // tear down on quit/reload if we own it
  pi.on("session_shutdown", async () => { stopServer(); });

  // manual control / visibility
  pi.registerCommand("llama", {
    description: "Local model server: status | start | stop",
    handler: async (args, ctx) => {
      const cmd = (args || "status").trim();
      if (cmd === "stop") { stopServer(); ctx.ui.notify("Stopped (if owned).", "info"); return; }
      if (cmd === "start") { await ensureServer(ctx); return; }
      const up = await isUp();
      ctx.ui.notify(`server ${up ? "UP" : "down"} at ${BASE}; owned=${ownedPid != null}`, "info");
    },
  });
}
