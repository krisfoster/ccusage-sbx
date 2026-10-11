#!/bin/bash
# Installs the ccusage the hub and dashboard run on this computer, without needing a Rust toolchain.
#
# Downloads the binary for this OS and CPU from the release this checkout pins (macOS arm64 and x64, Linux
# arm64 and x64), refuses it unless its SHA-256 matches the committed SHA256SUMS, and puts it where
# host/ccusage-sbx-hub looks. If there is no pinned release for this platform, build from source instead:
# scripts/build-host-binary.sh.
#
# Usage: scripts/install-host-binary.sh      (CCUSAGE_SBX_BIN=<path> installs somewhere else)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$HERE/ccusage-kit/files/home/.local/share/ccusage-sbx"
DEST="${CCUSAGE_SBX_BIN:-$HOME/.local/share/ccusage-sbx/bin/ccusage}"

case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) echo "no prebuilt binary for $(uname -s); use scripts/build-host-binary.sh" >&2; exit 1 ;; esac
case "$(uname -m)" in arm64 | aarch64) cpu=arm64 ;; x86_64 | amd64) cpu=x64 ;; *) echo "no prebuilt binary for $(uname -m); use scripts/build-host-binary.sh" >&2; exit 1 ;; esac
FILE="ccusage-$os-$cpu"

# shellcheck disable=SC1091
. "$KIT/release.env"
want="$(grep " $FILE\$" "$KIT/SHA256SUMS" 2>/dev/null | cut -d' ' -f1 || true)"
if [ "$RELEASE_BASE" = unreleased ] || [ -z "$want" ]; then
  echo "this checkout pins no $FILE; build from source with scripts/build-host-binary.sh" >&2
  exit 1
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "downloading $RELEASE_BASE/$FILE"
curl -fsSL --retry 3 -o "$tmp/ccusage" "$RELEASE_BASE/$FILE"

if command -v sha256sum >/dev/null; then got="$(sha256sum "$tmp/ccusage" | cut -d' ' -f1)"; else got="$(shasum -a 256 "$tmp/ccusage" | cut -d' ' -f1)"; fi
if [ "$got" != "$want" ]; then
  echo "checksum mismatch for $FILE (expected $want, got $got); not installing it" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
install -m 0755 "$tmp/ccusage" "$DEST"
# A downloaded file on macOS carries a quarantine flag only if a browser fetched it; curl does not set one.
"$DEST" --version
"$DEST" sync serve --help >/dev/null && echo "installed $DEST (has 'sync serve')"
