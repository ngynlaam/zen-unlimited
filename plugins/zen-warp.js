// plugins/zen-warp.js — thin Plugin Module (Signal Adapter).
//
// Module: ZenWarp signal Adapter.
// Interface: OpenCode plugin hook -> signals log file (append-only text).
// Seam: filesystem signals log; policy Module (bin/zen) reads it.
// Adapter: this file only translates a quota event into a signal line.
//   No policy logic here: no rotate, no decision, no cooldown.
//
// Install target: ~/.config/opencode/plugins/zen-warp.js
// (install.sh copies this file there).
//
// Signal line format: "<ISO8601> <model-id> 429 <retry-after?>"
// Keep this format stable: bin/zen parses it.
//
// Export shape: ESM V2-only no-op adapter. The V2 host requires a default
// export object (`{ id, setup() }`), so this module exports that object with
// an empty setup. No named exports: any extra named function export trips
// "must export default definition".

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Seam: signals log path. Env override keeps tests hermetic.
const SIGNAL_DIR =
  process.env.SIGNAL_DIR || path.join(os.homedir(), ".local/share/warp-rotate/signals");
const ZEN_SIGNAL_FILE =
  process.env.ZEN_SIGNAL_FILE || path.join(SIGNAL_DIR, "zen-quota.log");

// Adapter: append one signal line. Never throws into the host.
// Kept as a non-exported helper (no named exports by design; no importers
// in repo or installed plugins — verified via grep for zen-warp/emitSignal).
// Currently unwired: setup is an intentional no-op until a real host
// hook needs signal emission. All policy lives in bin/zen.
function emitSignal({ model = "unknown", retryAfter = "" } = {}) {
  try {
    fs.mkdirSync(SIGNAL_DIR, { recursive: true });
    const line = `${new Date().toISOString()} ${model} 429${retryAfter !== "" ? ` retry-after=${retryAfter}` : ""}\n`;
    fs.appendFileSync(ZEN_SIGNAL_FILE, line);
  } catch {
    // Intentionally silent: a signal failure must not break the request.
  }
}
void emitSignal;

export default {
  id: "zen-warp",
  setup() {},
};
