#!/bin/bash
# Installs a 'ccusage-sbx-dashboard' command into ~/.local/bin that opens the local dashboard.
# It is a small wrapper that runs host/ccusage-sbx-hub from this checkout, so keep the checkout where it is
# (or run this again after moving it). Extra arguments are passed on, e.g. 'ccusage-sbx-dashboard --port 9000'.
#
# Usage: scripts/install-command.sh [--uninstall]
#   BIN_DIR=<dir>   install somewhere other than ~/.local/bin
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
NAME=ccusage-sbx-dashboard
TARGET="$BIN_DIR/$NAME"
MARK="# managed by ccusage-sbx scripts/install-command.sh"

if [ "${1:-}" = "--uninstall" ]; then
  if [ -f "$TARGET" ] && grep -qF "$MARK" "$TARGET"; then rm "$TARGET"; echo "removed $TARGET"; else echo "nothing to remove at $TARGET"; fi
  exit 0
fi

if [ -e "$TARGET" ] && ! grep -qF "$MARK" "$TARGET" 2>/dev/null; then
  echo "$TARGET exists and was not made by this script; not overwriting it" >&2
  exit 1
fi

mkdir -p "$BIN_DIR"
cat > "$TARGET" <<WRAPPER
#!/bin/sh
$MARK
exec "$HERE/host/ccusage-sbx-hub" dashboard --open "\$@"
WRAPPER
chmod 0755 "$TARGET"
echo "installed $TARGET"

case ":$PATH:" in
  *":$BIN_DIR:"*) echo "run: $NAME" ;;
  *) echo "$BIN_DIR is not on your PATH; add it to your shell profile to run '$NAME' directly" ;;
esac
