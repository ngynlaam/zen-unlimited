import { appendFile, mkdir, readFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { createConnection } from "node:net";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";

const SIGNAL_FILE = process.env.ZEN_QUOTA_SIGNAL_FILE ?? join(homedir(), ".local/share/warp-rotate/signals/zen-quota.log");
const WARP_LOG = process.env.ZEN_QUOTA_WARP_LOG ?? join(homedir(), ".local/share/warp-rotate/auto.log");
const STATE_LOG = process.env.ZEN_QUOTA_STATE_LOG ?? join(homedir(), ".local/state/opencode/zen-quota-retry.log");
// A parked edge can delay a retry until the park expires. After that, WARP can
// take up to 60s to connect, 20s to serve proxy traffic, and 2s to settle.
// warp-auto now wakes at park expiry instead of waiting for another log event.
const ROTATE_WAIT_MS = 100_000;
const SETTLE_MS = 2_000;
const POLL_MS = 250;
// Fail-closed bound: Zen-model traffic never leaves via system-route. A bounded
// wait keeps this scope Zen-only; on timeout the fetch layer throws a
// transport-retryable error instead of leaking a second egress pool.
const PROXY_WAIT_MS = 15_000;
const LOG_SNIPPET_MAX = 200;
const MAX_SESSION_RETRIES = 10;
const RETRY_INTERVAL_MS = 10_000;
const POST_ROTATION_RETRY_MS = 3_000;
const FRESH_DONE_MS = 20_000;
const RETRY_AFTER_MAX_MS = 10_000;
const WARP_PROXY = "http://127.0.0.1:44444";
const WARP_PROXY_HOST = "127.0.0.1";
const WARP_PROXY_PORT = 44444;
const ZEN_QUOTA_ROUTE = process.env.ZEN_QUOTA_ROUTE ?? "warp";
const execFileAsync = promisify(execFile);
// Symbol guard so a plugin reload does not stack another global fetch wrapper.
const GLOBAL_FETCH_MARK = Symbol.for("zen-quota-retry.global-fetch-router");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
let signalChain = Promise.resolve();
const wrappedFetches = new WeakSet();
let zenRequestSequence = 0;

function log(message) {
  const line = `${new Date().toISOString()} ${message}\n`;
  mkdir(dirname(STATE_LOG), { recursive: true, mode: 0o700 })
    .then(() => appendFile(STATE_LOG, line, { mode: 0o600 }))
    .catch((error) => {
      console.error(`[zen-quota-retry] state log failed: ${error?.name ?? "Error"}`);
    });
}

// Free-tier predicate. Keep in sync with lib/auto.sh is_free_model().
// Rule: '-free' suffix (non-jev), or a suffixless zero-cost id (verified
// against models.opencode.ai/api.json 2026-10-17). Contract: WARP-AUTO.md §16.
const FREE_SUFFIXLESS = new Set(["big-pickle", "grok-code"]);
function isZenQuota429(event) {
  const id = event?.model?.id ?? "";
  const isFree = (id.endsWith("-free") || FREE_SUFFIXLESS.has(id)) && !id.startsWith("jev-");
  return event?.model?.providerID === "opencode" &&
    isFree &&
    Number(event?.error?.status) === 429 &&
    (event.error.type === "provider.quota" || event.error.type === "provider.rate-limit");
}

function retryAfterDelay(error) {
  const headers = error?.data?.responseHeaders ?? error?.responseHeaders;
  if (!headers || typeof headers !== "object") return undefined;

  const getHeader = (name) => {
    const key = Object.keys(headers).find((header) => header.toLowerCase() === name);
    return key ? String(headers[key]) : undefined;
  };

  const milliseconds = getHeader("retry-after-ms");
  if (milliseconds !== undefined && milliseconds.trim() !== "") {
    const value = Number(milliseconds);
    if (Number.isFinite(value) && value >= 0) return Math.min(value, RETRY_AFTER_MAX_MS);
  }

  const retryAfter = getHeader("retry-after");
  if (!retryAfter) return undefined;
  const seconds = Number(retryAfter);
  if (Number.isFinite(seconds) && seconds >= 0) {
    return Math.min(seconds * 1_000, RETRY_AFTER_MAX_MS);
  }
  const dateDelay = Date.parse(retryAfter) - Date.now();
  if (Number.isFinite(dateDelay) && dateDelay > 0) {
    return Math.min(dateDelay, RETRY_AFTER_MAX_MS);
  }
  return undefined;
}

function retryTiming(event, rotationReady = false) {
  const serverDelay = retryAfterDelay(event?.error);
  if (serverDelay !== undefined) {
    return {
      delay: Math.min(Math.ceil(serverDelay), RETRY_AFTER_MAX_MS),
      source: serverDelay > RETRY_AFTER_MAX_MS ? "retry-after-capped" : "retry-after",
    };
  }
  return {
    delay: rotationReady ? POST_ROTATION_RETRY_MS : RETRY_INTERVAL_MS,
    source: rotationReady ? "post-rotation-10s" : "fixed-10s",
  };
}

function clearGlobalWarpProxy() {
  const names = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"];
  const cleared = names.filter((name) => process.env[name] === WARP_PROXY);
  for (const name of cleared) delete process.env[name];
  return cleared.length;
}

// isZenEndpoint — exact scope: the OpenCode Zen inference base only.
// v2 serves Zen at https://opencode.ai/zen/v1/* (chat/completions, messages,
// responses, models). /inference/* is inert in v2 (kept as a forward guard).
// Every other host and every other opencode.ai path stays direct, so OpenAI
// auth, MCP servers, and other providers are untouched.
function isZenEndpoint(input) {
  try {
    const url = new URL(input instanceof Request ? input.url : String(input));
    return url.protocol === "https:" && url.hostname.toLowerCase() === "opencode.ai" && (url.pathname.startsWith("/zen/") || url.pathname.startsWith("/inference/"));
  } catch {
    return false;
  }
}

function proxyConnectionCode(error) {
  const visited = new Set();
  let current = error;
  while (current && typeof current === "object" && !visited.has(current)) {
    visited.add(current);
    if (typeof current.code === "string") return current.code;
    current = current.cause;
  }
  return "";
}

function isWarpProxyAvailable() {
  return new Promise((resolve) => {
    const socket = createConnection({ host: WARP_PROXY_HOST, port: WARP_PROXY_PORT });
    let settled = false;
    const finish = (available) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(available);
    };
    socket.setTimeout(500, () => finish(false));
    socket.once("connect", () => finish(true));
    socket.once("error", () => finish(false));
  });
}

function truncateForLog(value) {
  const text = String(value ?? "");
  return text.length > LOG_SNIPPET_MAX ? text.slice(0, LOG_SNIPPET_MAX) : text;
}

async function waitForWarpProxy(requestID) {
  const deadline = Date.now() + PROXY_WAIT_MS;
  log(`Zen request request=${requestID} route=proxy-wait`);
  while (Date.now() < deadline) {
    if (await isWarpProxyAvailable()) return true;
    await sleep(POLL_MS);
  }
  return false;
}

function proxyUnavailableError(reason) {
  const error = new Error(
    `WARP local proxy unavailable (${truncateForLog(reason)}); failing closed, no direct fallback`
  );
  error.code = "EPROXYUNAVAILABLE";
  error.retryable = true;
  return error;
}

function canReplayForRetry(request, init) {
  const body = init?.body;
  const replayableBody = body == null || typeof body === "string" ||
    body instanceof ArrayBuffer || ArrayBuffer.isView(body) ||
    body instanceof Blob || body instanceof FormData || body instanceof URLSearchParams;
  if (!replayableBody) return false;
  if (request instanceof Request) return !request.bodyUsed;
  return true;
}

function statusCode(error) {
  const status = Number(error?.status ?? error?.data?.statusCode ?? error?.data?.responseHeaders?.["x-status"]);
  return Number.isInteger(status) && status >= 100 && status <= 599 ? status : undefined;
}

async function isRotationServiceActive() {
  try {
    await execFileAsync("systemctl", ["--user", "is-active", "--quiet", "warp-auto.service"]);
    return true;
  } catch {
    return false;
  }
}

// installGlobalFetchRouter — patch globalThis.fetch once.
//
// Why this seam: OpenCode v2 serves Zen through the native route
// (@opencode/ai/providers/opencode-zen -> effect FetchHttpClient), which never
// calls the AI-SDK `options.fetch` that the old aisdk "sdk" hook wrapped. The
// global fetch is the only plugin seam that sees the native Zen request, so the
// per-request Bun proxy option is injected here. Scope stays exact: only
// https://opencode.ai/zen/* is touched; every other call passes through.
function installGlobalFetchRouter() {
  if (globalThis[GLOBAL_FETCH_MARK]) {
    log("global fetch router already installed");
    return;
  }
  const send = globalThis.fetch;
  if (typeof send !== "function") {
    log("global fetch router skipped: globalThis.fetch is not a function");
    return;
  }

  const routedFetch = async (request, init = {}) => {
    if (process.env.ZEN_DEBUG_FETCH === "1") {
      try { log(`fetch-probe ${request instanceof Request ? request.url : String(request)}`); } catch {}
    }
    const zenEndpoint = isZenEndpoint(request);
    if (!zenEndpoint) return send(request, init);
    const requestID = ++zenRequestSequence;
    const observeZenResponse = async (responsePromise, route) => {
      const response = await responsePromise;
      log(`Zen request request=${requestID} route=${route} status=${response.status} reason=${route === "tunnel-passthrough" ? "passthrough" : "proxy"}`);
      log(`Zen response request=${requestID} status=${response.status} route=${route}`);
      return response;
    };
    // Explicit route override. Default remains WARP-only; direct mode is
    // opt-in and intended for `ZEN_LAUNCH_PROXY=off` diagnostics/use.
    if (ZEN_QUOTA_ROUTE === "direct") {
      log(`Zen request request=${requestID} route=direct-explicit`);
      return observeZenResponse(send(request, { ...init, proxy: false }), "direct-explicit");
    }
    const requestOptions = {
      ...init,
      // Bun honors this per request. It overrides proxy environment variables.
      proxy: { url: WARP_PROXY, respectNoProxy: false },
    };

    // Mode-aware: proxy mode (listener alive) stays fail-closed strict.
    // Tunnel mode (no listener, e.g. WarpWithDnsOverTls) fast-paths to
    // passthrough because "direct" IS the clean tunnel, not an ISP leak.
    // A truly dead WARP fails naturally at transport and the daemon rotates.
    if (!(await isWarpProxyAvailable())) {
      log(`Zen request request=${requestID} route=tunnel-passthrough reason=proxy-not-present`);
      return observeZenResponse(send(request, { ...init, proxy: false }), "tunnel-passthrough");
    }

    // Keep a replayable copy before the first fetch so a post-wait proxy
    // retry does not consume a one-shot body.
    let proxyRetryRequest;
    if (canReplayForRetry(request, init)) {
      try { proxyRetryRequest = request instanceof Request ? request.clone() : request; }
      catch { proxyRetryRequest = undefined; }
    }
    const proxyRetryInit = { ...init };

    try {
      log(`Zen request request=${requestID} route=local-proxy-listener`);
      return await observeZenResponse(send(request, requestOptions), "local-proxy-listener");
    } catch (error) {
      // Only ECONNREFUSED identifies an unavailable local listener. Do not
      // treat provider errors, HTTP 429s, or upstream resets as proxy-down.
      const code = proxyConnectionCode(error);
      if (code !== "ECONNREFUSED") {
        log(`Zen request request=${requestID} route=local-proxy-listener status=TRANSPORT_ERROR:${truncateForLog(code || error?.message || error?.name || "unknown")} reason=non-ECONNREFUSED-rethrow httpStatus=${statusCode(error) ?? "unknown"}`);
        throw error;
      }
      // Mode-aware: listener gone (tunnel mode) → fast-path passthrough with
      // no 15s wait. Listener alive but refused (transient flap) → bounded
      // wait + retry through the proxy as before.
      if (!(await isWarpProxyAvailable())) {
        if (proxyRetryRequest === undefined) {
          log(`Zen request request=${requestID} route=tunnel-passthrough status=TRANSPORT_ERROR:${truncateForLog(proxyConnectionCode(error) || error?.message || error?.name || "unknown")} reason=ECONNREFUSED-proxy-not-present-no-replay`);
          throw error;
        }
        log(`Zen request request=${requestID} route=tunnel-passthrough reason=ECONNREFUSED-proxy-not-present`);
        try {
          return await observeZenResponse(
            send(proxyRetryRequest, { ...proxyRetryInit, proxy: false }),
            "tunnel-passthrough",
          );
        } catch (retryError) {
          log(`Zen request request=${requestID} route=tunnel-passthrough status=TRANSPORT_ERROR:${truncateForLog(proxyConnectionCode(retryError) || retryError?.message || retryError?.name || "unknown")} reason=tunnel-passthrough-retry-failed httpStatus=${statusCode(retryError) ?? "unknown"}`);
          throw retryError;
        }
      }
      const recovered = await waitForWarpProxy(requestID);
      if (!recovered) {
        log(`Zen request request=${requestID} route=proxy-timeout status=TRANSPORT_ERROR:EPROXYUNAVAILABLE reason=ECONNREFUSED`);
        throw proxyUnavailableError("ECONNREFUSED");
      }
      if (proxyRetryRequest === undefined) {
        log(`Zen request request=${requestID} route=proxy-wait status=TRANSPORT_ERROR:EPROXYUNAVAILABLE reason=ECONNREFUSED-recovered-no-replay`);
        throw proxyUnavailableError("ECONNREFUSED-recovered-no-replay");
      }
      try {
        log(`Zen request request=${requestID} route=proxy-wait reason=ECONNREFUSED-recovered-retry`);
        return await observeZenResponse(
          send(proxyRetryRequest, { ...proxyRetryInit, proxy: requestOptions.proxy }),
          "local-proxy-listener",
        );
      } catch (retryError) {
        log(`Zen request request=${requestID} route=local-proxy-listener status=TRANSPORT_ERROR:${truncateForLog(proxyConnectionCode(retryError) || retryError?.message || retryError?.name || "unknown")} reason=proxy-wait-retry-failed httpStatus=${statusCode(retryError) ?? "unknown"}`);
        throw retryError;
      }
    }
  };
  globalThis.fetch = routedFetch;
  globalThis[GLOBAL_FETCH_MARK] = true;
  wrappedFetches.add(routedFetch);
  log("global fetch router installed scope=opencode.ai/zen");
}

function lastQuotaRotation(lines) {
  let latest;
  for (let index = 0; index < lines.length; index++) {
    const match = lines[index].match(/^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (.*)$/);
    if (!match) continue;
    const at = Date.parse(match[1]);
    const message = match[2];
    if (message.startsWith("rotate start (429-")) {
      latest = { index, startedAt: at, state: "running" };
    } else if (latest?.state === "running" && message.startsWith("rotate FAILED")) {
      latest = { ...latest, finishedAt: at, state: "failed" };
    } else if (latest?.state === "running" && (message.startsWith("rotate done") || message.startsWith("rotate stopped:"))) {
      latest = { ...latest, finishedAt: at, state: "done" };
    }
  }
  return latest;
}

// formatQuotaSignal — rotate-signal Interface line (see
// docs/signal-interface.md in zen-unlimited). Writer only: timestamp,
// event model id, trigger text, optional retry-after seconds. The daemon
// decides; a non-catalog $2 is dropped there, same as an absent one today.
function formatQuotaSignal(stamp, signal = {}) {
  const raw = String(signal.modelId ?? "unknown");
  const model = /^[A-Za-z0-9._+/-]+$/.test(raw) ? raw : "unknown";
  const hint = Number.isFinite(signal.retryAfterSecs) && signal.retryAfterSecs > 0
    ? ` retry-after=${Math.ceil(signal.retryAfterSecs)}` : "";
  return `${stamp} ${model} rate limit exceeded status=429 source=zen-session-retry-hook${hint}\n`;
}

async function rotateForQuota(signal = {}) {
  const requestedAt = Date.now();
  const stamp = new Date(requestedAt).toISOString();
  let text;
  try {
    text = await readFile(WARP_LOG, "utf8");
  } catch {
    log("rotation signal skipped error=warp-log-unavailable");
    return false;
  }

  const lines = text.split("\n");
  let cursor = lines.length - 1;
  let started = false;
  let doneAt = 0;
  const recent = lastQuotaRotation(lines);
  if (recent?.state === "running" && requestedAt - recent.startedAt <= ROTATE_WAIT_MS) {
    started = true;
    log("joining active 429 rotation");
  }

  if (!started && !doneAt) {
    signalChain = signalChain.catch(() => {}).then(async () => {
      await mkdir(dirname(SIGNAL_FILE), { recursive: true, mode: 0o700 });
      await appendFile(SIGNAL_FILE,
        formatQuotaSignal(stamp, signal),
        { mode: 0o600 });
    });
    try {
      await signalChain;
    } catch (error) {
      log(`rotation signal failed error=${error?.name ?? "Error"}`);
      return false;
    }
  }

  const deadline = requestedAt + ROTATE_WAIT_MS;

  while (Date.now() < deadline) {
    let text;
    try { text = await readFile(WARP_LOG, "utf8"); }
    catch { return false; }

    // Only consume newly appended lines. Match rotate reasons to avoid treating
    // an unrelated concurrent daemon rotation as completion of this signal.
    const lines = text.split("\n");
    if (lines.length - 1 < cursor) {
      cursor = 0; // The daemon trims its narrative log when it reaches its size limit.
      started = false;
      doneAt = 0;
    }
    const recent = lines.slice(cursor);
    cursor = lines.length - 1; // Keep the trailing partial line open for the next read.
    for (const line of recent) {
      const parts = line.match(/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d (.*)$/);
      if (!parts) continue;
      const message = parts[1];
      if (message.startsWith("rotate start (429-")) {
        started = true;
        doneAt = 0;
      } else if (started && message.startsWith("rotate FAILED")) {
        return false;
      } else if (started && (message.startsWith("rotate done") || message.startsWith("rotate stopped:"))) {
        // A stopped rotate means the reset succeeded, but WARP returned the
        // same IPv6 edge. The daemon's measured success condition is reconnect.
        doneAt = Date.now();
      }
    }
    if (doneAt && Date.now() - doneAt >= SETTLE_MS) return true;
    await sleep(POLL_MS);
  }
  return false;
}

let inFlightRotation;
async function lastRotateDoneAt() {
  // Fresh-done shortcut: a "rotate done" within FRESH_DONE_MS means the route
  // already serves; the caller skips the rotation wait and retries fast.
  try {
    const text = await readFile(WARP_LOG, "utf8");
    const lines = text.split("\n");
    for (let i = lines.length - 1; i >= 0 && i >= lines.length - 400; i--) {
      const parts = lines[i].match(/^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (.*)$/);
      if (!parts) continue;
      if (parts[2].startsWith("rotate done") || parts[2].startsWith("rotate stopped:")) {
        const t = new Date(parts[1].replace(" ", "T") + "+07:00").getTime();
        if (Number.isFinite(t)) return t;
        return 0;
      }
      if (parts[2].startsWith("rotate start (429-") || parts[2].startsWith("rotate FAILED")) return 0;
    }
  } catch { /* fall through */ }
  return 0;
}
function requestRotation(signal) {
  if (inFlightRotation) return inFlightRotation;
  const rotation = rotateForQuota(signal);
  inFlightRotation = rotation;
  void rotation.finally(() => {
    if (inFlightRotation === rotation) inFlightRotation = undefined;
  });
  return rotation;
}

async function retryZenQuotaInSession(event) {
  if (!isZenQuota429(event)) return;
  if (event.attempt > MAX_SESSION_RETRIES + 1) {
    log(`quota retry skipped session=${event.sessionID} attempt=${event.attempt} reason=limit`);
    return;
  }

  log(`quota 429 caught session=${event.sessionID} agent=${event.agent} attempt=${event.attempt} errorType=${event.error.type}`);
  const retryWithoutRotation = retryTiming(event, false);
  if (!(await isRotationServiceActive())) {
    // Mode-aware: tunnel mode (no listener) → schedule immediately, no wait.
    // Proxy mode → bounded wait as before; the fetch layer stays proxy-only.
    if (!(await isWarpProxyAvailable())) {
      event.decision = { retry: true, delay: retryWithoutRotation.delay };
      log(`quota retry scheduled session=${event.sessionID} reason=rotator-inactive route=tunnel-passthrough delay=${retryWithoutRotation.delay}ms timing=${retryWithoutRotation.source}`);
      return;
    }
    const proxyReady = await waitForWarpProxy(`rotator-inactive-attempt-${event.attempt}`);
    event.decision = { retry: true, delay: retryWithoutRotation.delay };
    log(`quota retry scheduled session=${event.sessionID} reason=rotator-inactive route=${proxyReady ? "proxy-wait" : "proxy-timeout"} delay=${retryWithoutRotation.delay}ms timing=${retryWithoutRotation.source}`);
    return;
  }

  // Fresh-done shortcut: the daemon already finished a rotate seconds ago,
  // so retry fast instead of waiting out another rotation window.
  const doneAt = await lastRotateDoneAt();
  if (doneAt && Date.now() - doneAt <= FRESH_DONE_MS) {
    const timing = retryTiming(event, true);
    event.decision = { retry: true, delay: timing.delay };
    log(`native retry enabled session=${event.sessionID} attempt=${event.attempt} delay=${timing.delay}ms timing=fresh-done`);
    return;
  }

  // Signal carries the hook event's model + Retry-After for the daemon's
  // documented line format. Read-only: retry decisions below are unchanged.
  const serverRetryMs = retryAfterDelay(event?.error);
  const rotated = await requestRotation({
    modelId: event?.model?.id,
    retryAfterSecs: serverRetryMs === undefined ? undefined : serverRetryMs / 1000,
  });
  if (!rotated) {
    // Mode-aware: tunnel mode → schedule immediately, no wait. Proxy mode →
    // bounded wait; the fetch layer fails closed on proxy-timeout and
    // surfaces a transport-retryable error instead.
    if (!(await isWarpProxyAvailable())) {
      event.decision = { retry: true, delay: retryWithoutRotation.delay };
      log(`quota retry scheduled session=${event.sessionID} reason=rotation-not-ready route=tunnel-passthrough delay=${retryWithoutRotation.delay}ms timing=${retryWithoutRotation.source}`);
      return;
    }
    const proxyReady = await waitForWarpProxy(`rotation-not-ready-attempt-${event.attempt}`);
    event.decision = { retry: true, delay: retryWithoutRotation.delay };
    log(`quota retry scheduled session=${event.sessionID} reason=rotation-not-ready route=${proxyReady ? "proxy-wait" : "proxy-timeout"} delay=${retryWithoutRotation.delay}ms timing=${retryWithoutRotation.source}`);
    return;
  }

  // OpenCode marks provider.quota as non-retryable by default. Retry with the
  // provider's Retry-After value (capped at 10s), or retry 1s after the
  // confirmed route settle. Every later 429 starts another WARP reset.
  // Concurrent 429 hooks share the same active reset because WARP is system-wide.
  const timing = retryTiming(event, true);
  event.decision = { retry: true, delay: timing.delay };
  log(`native retry enabled session=${event.sessionID} attempt=${event.attempt} delay=${timing.delay}ms timing=${timing.source}`);
}

async function setupZenQuotaRetry(context) {
  const clearedProxyVars = clearGlobalWarpProxy();
  installGlobalFetchRouter();
  await context.session.hook("retry", retryZenQuotaInSession);
  log(`global WARP proxy variables cleared=${clearedProxyVars}`);
  log(`plugin setup active directory=${context.location?.directory ?? process.cwd()}`);
}

// Install at import time. The effect Fetch service resolves globalThis.fetch
// when its layer is built, which happens BEFORE the plugin setup hook runs. A
// patch inside setup() is therefore invisible to native-provider requests.
// Module import is early enough (proven on opencode v2.0.15). Idempotent.
installGlobalFetchRouter();

export default {
  id: "zen-quota-retry",
  setup: setupZenQuotaRetry,
};
