#!/bin/bash
# Builds static Linux ccusage binaries (arm64 and x64) from the fork.
#
# Usage: scripts/build-binaries.sh [path-to-ccusage-fork] [arch...]
#   arch is arm64 and/or x64; default is both. The x64 build on an arm64 host runs under emulation
#   and is slow.
#
# This is the same script the build workflow runs (one architecture per runner, so no emulation there).
#   OUT                         where the binaries go (default: the kit's files directory, for local use)
#   SKIP_METADATA=1             write no checksum or build-info files (the workflow writes its own)
#   CCUSAGE_SBX_BUILD_CACHE     where prices and build output are cached; a model_prices.json already there is used
#
# Locally the result is for trying the kit: it writes SHA256SUMS.local and BUILD-INFO.local, which are not
# committed. The binaries a user gets come from the workflow and are pinned by SHA256SUMS.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
FORK="${1:-$HERE/../ccusage}"
shift || true
ARCHES=("$@")
[ ${#ARCHES[@]} -eq 0 ] && ARCHES=(arm64 x64)

FORK="$(cd "$FORK" && pwd)"
OUT="${OUT:-$HERE/ccusage-kit/files/home/.local/share/ccusage-sbx}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
CACHE="${CCUSAGE_SBX_BUILD_CACHE:-$HERE/.build}"
mkdir -p "$OUT" "$CACHE"

# Prices are embedded at build time, so a binary only knows the models that existed when it was built.
if [ ! -s "$CACHE/model_prices.json" ] || [ -n "${REFRESH_PRICES:-}" ]; then
  curl -fsSL -o "$CACHE/model_prices.json" \
    https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
fi

for arch in "${ARCHES[@]}"; do
  case "$arch" in
    arm64) platform=linux/arm64 ;;
    x64)   platform=linux/amd64 ;;
    *) echo "unknown arch '$arch' (use arm64 or x64)" >&2; exit 1 ;;
  esac
  echo "== building ccusage for $arch ($platform)"
  mkdir -p "$CACHE/target-$arch"
  docker run --rm --platform "$platform" \
    -v "$FORK":/src:ro \
    -v "$CACHE/target-$arch":/target \
    -v "$OUT":/out \
    -v "$CACHE/model_prices.json":/pricing.json:ro \
    -e CARGO_TARGET_DIR=/target -e CCUSAGE_PRICING_JSON_PATH=/pricing.json \
    -w /src/rust rust:1.97-alpine \
    sh -c "apk add --no-cache musl-dev >/dev/null && cargo build --release -p ccusage --locked \
           && cp /target/release/ccusage /out/ccusage-linux-$arch"
  ls -l "$OUT/ccusage-linux-$arch"
done

if [ -n "${SKIP_METADATA:-}" ]; then echo "== done"; exit 0; fi
(cd "$OUT" && shasum -a 256 ccusage-linux-* > SHA256SUMS.local)

# Say what the binaries were built from, because they are committed and nothing else would.
FORK_COMMIT="$(git -C "$FORK" rev-parse HEAD 2>/dev/null || echo unknown)"
FORK_DIRTY="clean"
[ -n "$(git -C "$FORK" status --porcelain 2>/dev/null)" ] && FORK_DIRTY="DIRTY (built from uncommitted changes)"
cat > "$OUT/BUILD-INFO.local" <<INFO
ccusage fork:  $(git -C "$FORK" remote get-url origin 2>/dev/null || echo unknown)
branch:        $(git -C "$FORK" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
commit:        $FORK_COMMIT
tree:          $FORK_DIRTY
built:         $(date -u +%Y-%m-%dT%H:%M:%SZ)
architectures: ${ARCHES[*]}
toolchain:     rust:1.97-alpine (static musl)
prices:        LiteLLM model_prices_and_context_window.json, sha256 $(shasum -a 256 "$CACHE/model_prices.json" | cut -d' ' -f1)
INFO
echo "== done"; cat "$OUT/SHA256SUMS.local" "$OUT/BUILD-INFO.local"
