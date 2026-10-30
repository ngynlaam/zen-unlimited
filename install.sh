#!/usr/bin/env bash
# install.sh — install the combined OpenCode plugin repo layout.
# Modules installed: Plugin Module (plugins/zen-warp.js), Zen Module (bin/zen
# + thin rollback wrappers bin/warp-*, sourced libs lib/*.sh).
# State files stay in place: never touch $STATE_DIR contents.
set -eu

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DST="${PLUGIN_DST:-$HOME/.config/opencode/plugins}"
BIN_DST="${BIN_DST:-$HOME/.local/share/warp-rotate/bin}"
LIB_DST="${LIB_DST:-$(dirname "$BIN_DST")/lib}"   # bin/zen sources ../lib, so keep the pair together

# Check required plugins before creating or changing installation files.
for plugin in zen-warp.js zen-quota-retry.js; do
  if [ ! -f "$SRC_DIR/plugins/$plugin" ]; then
    echo "install: required plugin missing: plugins/$plugin" >&2
    exit 1
  fi
done
if [ "$LIB_DST" != "$(dirname "$BIN_DST")/lib" ]; then
  echo "install: LIB_DST must be the lib directory next to BIN_DST" >&2
  exit 1
fi

mkdir -p "$PLUGIN_DST" "$BIN_DST" "$LIB_DST"

cp "$SRC_DIR/plugins/zen-warp.js" "$PLUGIN_DST/zen-warp.js"
cp "$SRC_DIR/plugins/zen-quota-retry.js" "$PLUGIN_DST/zen-quota-retry.js"
for b in zen warp-auto warp-rotate warp-report opencode2-warp; do
  cp "$SRC_DIR/bin/$b" "$BIN_DST/$b"
  chmod +x "$BIN_DST/$b"
done
if [ -f "$SRC_DIR/bin/steam-warp" ]; then
  cp "$SRC_DIR/bin/steam-warp" "$BIN_DST/steam-warp"
  chmod +x "$BIN_DST/steam-warp"
  echo "installed optional Steam launcher -> $BIN_DST/steam-warp"
fi
cp "$SRC_DIR"/lib/*.sh "$LIB_DST/"

echo "installed plugin -> $PLUGIN_DST/zen-warp.js"
echo "installed retry plugin -> $PLUGIN_DST/zen-quota-retry.js"
echo "installed bins   -> $BIN_DST/{zen,warp-auto,warp-rotate,warp-report,opencode2-warp}"
echo "installed libs   -> $LIB_DST/{state,auto,rotate,report,launch,catch}.sh"
echo "state files left in place (untouched)"
echo "no service installed or started; see README.md for opt-in setup"
