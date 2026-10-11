#!/bin/sh
# Installs the ccusage binary for this architecture. Runs once, as root, when the sandbox is created.
#
# The binary comes from a GitHub release of this repo (release.env), and is run only if its SHA-256
# matches the one committed in SHA256SUMS. Anything else is refused. Two escape hatches:
#   CCUSAGE_BINARY_URL + CCUSAGE_BINARY_SHA256   install a binary from another place, still checked
#   a binary placed in this directory            a local build from scripts/build-binaries.sh,
#                                                checked against SHA256SUMS.local
set -eu

DIR=/home/agent/.local/share/ccusage-sbx

case "$(uname -m)" in
  x86_64 | amd64) FILE=ccusage-linux-x64 ;;
  aarch64 | arm64) FILE=ccusage-linux-arm64 ;;
  *) echo "ccusage-sbx: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/ccusage"

fetch() { # url dest
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -t 3 -O "$2" "$1"
  else
    echo "ccusage-sbx: neither curl nor wget is available to download the binary" >&2
    return 1
  fi
}

verify() { # expected-sha256
  actual="$(sha256sum "$BIN" | cut -d' ' -f1)"
  if [ "$actual" != "$1" ]; then
    echo "ccusage-sbx: checksum mismatch for $FILE" >&2
    echo "  expected $1" >&2
    echo "  got      $actual" >&2
    echo "  refusing to install it" >&2
    exit 1
  fi
}

if [ -n "${CCUSAGE_BINARY_URL:-}" ]; then
  if [ -z "${CCUSAGE_BINARY_SHA256:-}" ]; then
    echo "ccusage-sbx: binary-url needs binary-sha256 as well" >&2
    exit 1
  fi
  echo "ccusage-sbx: downloading $CCUSAGE_BINARY_URL"
  fetch "$CCUSAGE_BINARY_URL" "$BIN"
  verify "$CCUSAGE_BINARY_SHA256"
elif [ -f "$DIR/$FILE" ]; then
  echo "ccusage-sbx: using the local build at $DIR/$FILE"
  want="$(grep " $FILE\$" "$DIR/SHA256SUMS.local" 2>/dev/null | cut -d' ' -f1 || true)"
  if [ -z "$want" ]; then
    echo "ccusage-sbx: no SHA256SUMS.local entry for $FILE" >&2
    exit 1
  fi
  cp "$DIR/$FILE" "$BIN"
  verify "$want"
else
  # shellcheck disable=SC1091
  . "$DIR/release.env"
  want="$(grep " $FILE\$" "$DIR/SHA256SUMS" 2>/dev/null | cut -d' ' -f1 || true)"
  if [ "$RELEASE_BASE" = unreleased ] || [ -z "$want" ]; then
    echo "ccusage-sbx: this copy of the kit does not name a release yet (see scripts/pin-release.sh)." >&2
    echo "  Use a tagged version of the kit, or set binary-url and binary-sha256." >&2
    exit 1
  fi
  echo "ccusage-sbx: downloading $RELEASE_BASE/$FILE"
  fetch "$RELEASE_BASE/$FILE" "$BIN"
  verify "$want"
fi

install -m 0755 "$BIN" /usr/local/bin/ccusage
rm -f "$DIR"/ccusage-linux-arm64 "$DIR"/ccusage-linux-x64
/usr/local/bin/ccusage --version
