#!/bin/bash
# Rotating the hub token: delete the token file, run install again, restart the hub, and a sandbox that was
# already syncing carries on with the new token without being touched.
#
# Needs sbx, the kit binaries and a host ccusage with 'sync serve'; see tests/e2e.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tests/sbx-real.sh"
PORT="${E2E_PORT:-18794}"
BIN="${CCUSAGE_SBX_BIN:-$HOME/.local/share/ccusage-sbx/bin/ccusage}"
WORK="$(mktemp -d)"
NAME="ccusage-rotate-$$"
HUB="$HERE/host/ccusage-sbx-hub"
FAILED=0
export CCUSAGE_SBX_BIN="$BIN" CCUSAGE_SBX_DIR="$WORK/hub" CCUSAGE_SBX_TOKEN_FILE="$WORK/token" CCUSAGE_SBX_PORT="$PORT"

say() { printf '%s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then say "  ok    $d"; else say "  FAIL  $d"; FAILED=1; fi; }
cleanup() { sbx rm -f "$NAME" >/dev/null 2>&1; [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

flushes() { "$HUB" flush "$NAME" > /dev/null 2>&1; }
start_hub() { "$HUB" run > "$WORK/hub.log" 2>&1 & HUB_PID=$!; sleep 2; }

"$HUB" install --skip-service --skip-secret >/dev/null || exit 2
start_hub
say "== a sandbox joins and syncs with the first token"
sbx create --name "$NAME" claude --kit "$HERE/ccusage-kit" --kit-arg hub-port="$PORT" --kit-arg sync-interval=300 >/dev/null 2>&1
sbx secret set-custom --sandbox "$NAME" --host localhost --env CCUSAGE_SYNC_TOKEN \
  --placeholder ccusage-hub-token --command "/bin/cat $WORK/token" >/dev/null 2>&1
deadline=$((SECONDS + 150))
until sbx exec "$NAME" sh -c 'grep -q "sync ok" ~/.local/state/ccusage-sbx/sync.log' 2>/dev/null; do
  [ $SECONDS -ge $deadline ] && { say "never joined"; exit 1; }
  sleep 5
done
OLD="$(cat "$WORK/token")"
check "the sandbox syncs with the first token" flushes

say "== rotate: delete the token file, install again, restart the hub"
rm -f "$WORK/token"
"$HUB" install --skip-service --skip-secret >/dev/null
kill "$HUB_PID" 2>/dev/null; sleep 1; start_hub
NEW="$(cat "$WORK/token")"
check "the token changed" [ -n "$NEW" ] && [ "$NEW" != "$OLD" ]
check "the old token is no longer accepted" \
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $OLD" "http://127.0.0.1:$PORT/v1/health")" = "401" ]
check "the sandbox syncs with the new token, untouched" flushes

say ""
[ $FAILED = 0 ] && say "PASS" || say "FAIL"
exit $FAILED
