#!/bin/bash
# Builds ccusage from the fork for THIS machine and installs it where host/ccusage-sbx-hub looks.
#
# The published ccusage has no 'sync serve', so the hub needs the fork. Needs a Rust toolchain.
# Usage: scripts/build-host-binary.sh [path-to-ccusage-fork]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
FORK="$(cd "${1:-$HERE/../ccusage}" && pwd)"
DEST="${CCUSAGE_SBX_BIN:-$HOME/.local/share/ccusage-sbx/bin/ccusage}"
CACHE="${CCUSAGE_SBX_BUILD_CACHE:-$HERE/.build}"
mkdir -p "$CACHE" "$(dirname "$DEST")"

command -v cargo >/dev/null || { echo "cargo not found; install Rust (https://rustup.rs)" >&2; exit 1; }

# Prices are embedded at build time.
if [ ! -s "$CACHE/model_prices.json" ] || [ -n "${REFRESH_PRICES:-}" ]; then
  curl -fsSL -o "$CACHE/model_prices.json" \
    https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
fi

(cd "$FORK/rust" && \
  CARGO_TARGET_DIR="$CACHE/target-host" CCUSAGE_PRICING_JSON_PATH="$CACHE/model_prices.json" \
  cargo build --release -p ccusage --locked)

install -m 0755 "$CACHE/target-host/release/ccusage" "$DEST"
"$DEST" --version
"$DEST" sync serve --help >/dev/null && echo "installed $DEST (has 'sync serve')"
