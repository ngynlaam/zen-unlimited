# lib/launch.sh — Routing Module: launcher (sourced).

zen_launch_main() {
  # ex bin/opencode2-warp. Routes OpenCode through the single local proxy port
  # (WARP on 127.0.0.1:44444). The OpenCode background service builds its effect
  # FetchHttpClient before plugins load, so the plugin cannot reroute it; the
  # process proxy env is the seam that works for it.
  #   ZEN_LAUNCH_PROXY      proxy URL (default follows live WARP mode);
  #                         "off" = no proxy. Empty/unset means: proxy mode ->
  #                         the local WARP proxy, tunnel mode -> direct (the
  #                         tunnel IS clean egress; a stale :44444 with no
  #                         listener refuses every connection).
  #   ZEN_LAUNCH_NO_PROXY   hosts that must stay direct
  local proxy="${ZEN_LAUNCH_PROXY:-auto}" opencode_bin="${ZEN_OPENCODE_BIN:-}"
  if [ "$proxy" = "auto" ]; then
    if mode_now 2>/dev/null | grep -q "^proxy"; then proxy="http://127.0.0.1:44444"; else proxy="off"; fi
  fi
  if [ "$proxy" = "off" ]; then
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy no_proxy NO_PROXY
    export ZEN_QUOTA_ROUTE=direct
  else
    export ZEN_QUOTA_ROUTE=warp
    export HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" http_proxy="$proxy" https_proxy="$proxy"
    # Remote MCP hosts stay direct: bun reads NO_PROXY at process start and
    # honors domain-suffix matches, so a :44444 rotation outage cannot cut them.
    export NO_PROXY="${ZEN_LAUNCH_NO_PROXY:-localhost,127.0.0.1,::1,mcp.cloudflare.com,mcp.context7.com,mcp.grep.app}"
    export no_proxy="$NO_PROXY"
  fi
  # Prefer an explicit binary, then the active PATH entry (mise/asdf/system),
  # then the legacy standalone install path.
  if [ -z "$opencode_bin" ]; then
    opencode_bin=$(command -v opencode 2>/dev/null || true)
  fi
  if [ -z "$opencode_bin" ] && [ -x "$HOME/.opencode/bin/opencode" ]; then
    opencode_bin="$HOME/.opencode/bin/opencode"
  fi
  if [ -z "$opencode_bin" ] || [ ! -x "$opencode_bin" ]; then
    echo "zen launch: OpenCode executable not found; set ZEN_OPENCODE_BIN or add opencode to PATH" >&2
    return 127
  fi
  exec "$opencode_bin" "$@"
}
