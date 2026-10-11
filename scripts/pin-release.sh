#!/bin/bash
# Points the kit at a release made by the build workflow: records its checksums and download location.
# Commit the two files it changes; from then on the kit installs exactly those bytes and nothing else.
#
# Usage: scripts/pin-release.sh <release-tag> [owner/repo]
set -euo pipefail

TAG="${1:?usage: scripts/pin-release.sh <release-tag> [owner/repo]}"
REPO="${2:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$HERE/ccusage-kit/files/home/.local/share/ccusage-sbx"

sums="$(gh release download "$TAG" --repo "$REPO" --pattern SHA256SUMS --output -)"
for f in ccusage-linux-arm64 ccusage-linux-x64; do
  echo "$sums" | grep -Eq "^[0-9a-f]{64}  $f\$" || { echo "release $TAG has no checksum for $f" >&2; exit 1; }
done

# The checksums come from the release itself, so check the release's attestation says the workflow built them.
if [ -z "${SKIP_ATTESTATION:-}" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  gh release download "$TAG" --repo "$REPO" --pattern 'ccusage-linux-*' --dir "$tmp"
  for f in ccusage-linux-arm64 ccusage-linux-x64; do
    want="$(echo "$sums" | awk -v f="$f" '$2==f{print $1}')"
    [ "$(shasum -a 256 "$tmp/$f" | cut -d' ' -f1)" = "$want" ] || { echo "$f does not match SHA256SUMS" >&2; exit 1; }
    gh attestation verify "$tmp/$f" --repo "$REPO" >/dev/null || { echo "no valid attestation for $f" >&2; exit 1; }
  done
  echo "checksums and attestations verified"
fi

printf '%s\n' "# Written by scripts/pin-release.sh $TAG" "$sums" | grep -v '^$' > "$KIT/SHA256SUMS"
cat > "$KIT/release.env" <<ENV
# Where install.sh downloads the binaries from. Written by scripts/pin-release.sh; do not edit by hand.
RELEASE_BASE=https://github.com/$REPO/releases/download/$TAG
ENV
echo "pinned $TAG. Review and commit:"; git -C "$HERE" diff --stat -- "$KIT"
