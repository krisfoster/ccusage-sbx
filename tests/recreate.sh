#!/bin/bash
# What survives when sbx recreates a sandbox's container, and what happens to the machine identity.
#
# Case 1: 'sbx kit add' (recreates the container). Case 2: 'sbx rm' then 'sbx create' with the same name.
# Needs sbx, the kit binaries and a host ccusage with 'sync serve'; see tests/e2e.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${E2E_PORT:-18792}"
BIN="${CCUSAGE_SBX_BIN:-$HOME/.local/share/ccusage-sbx/bin/ccusage}"
WORK="$(mktemp -d)"
NAME="ccusage-recreate-$$"
HUB="$HERE/host/ccusage-sbx-hub"
FAILED=0
export CCUSAGE_SBX_BIN="$BIN" CCUSAGE_SBX_DIR="$WORK/hub" CCUSAGE_SBX_TOKEN_FILE="$WORK/token" CCUSAGE_SBX_PORT="$PORT"

say() { printf '%s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then say "  ok    $d"; else say "  FAIL  $d"; FAILED=1; fi; }
cleanup() { sbx rm -f "$NAME" >/dev/null 2>&1; [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

"$HUB" install --skip-service --skip-secret >/dev/null || exit 2
"$HUB" run > "$WORK/hub.log" 2>&1 &
HUB_PID=$!
sleep 2

create() {
  sbx create --name "$NAME" claude --kit "$HERE/ccusage-kit" --kit-arg hub-port="$PORT" --kit-arg sync-interval=10 >/dev/null 2>&1
  sbx secret set-custom --sandbox "$NAME" --host localhost --env CCUSAGE_SYNC_TOKEN \
    --placeholder ccusage-hub-token --command "/bin/cat $WORK/token" >/dev/null 2>&1
}
wait_joined() {
  local deadline=$((SECONDS + 150))
  until sbx exec "$NAME" sh -c 'grep -q "sync ok" ~/.local/state/ccusage-sbx/sync.log' 2>/dev/null; do
    [ $SECONDS -ge $deadline ] && return 1
    sleep 5
  done
}
sandbox_id() { sbx exec "$NAME" sh -c 'echo $SANDBOX_ID' 2>/dev/null | tail -1; }
machine_id() { sbx exec "$NAME" sh -c 'grep -o "\"machineId\": \"[^\"]*" ~/.local/state/ccusage-sbx/ccusage.json | cut -d\" -f4' 2>/dev/null | tail -1; }
roster() { find "$WORK/hub/data" -path '*/machines/*/machine.json' | wc -l | tr -d ' '; }

say "== create, and wait for the first sync"
create; wait_joined || { say "never synced"; exit 1; }
ID1="$(sandbox_id)"; MACHINE1="$(machine_id)"
say "   SANDBOX_ID=$ID1 machine=$MACHINE1 roster=$(roster)"
check "the machine id is the sandbox id" [ "$ID1" = "$MACHINE1" ]

say "== case 1: sbx kit add recreates the container"
sbx kit add "$NAME" "$HERE/tests/fixtures/noop-kit" 2>&1 | tail -1
sleep 5
ID2="$(sandbox_id)"; MACHINE2="$(machine_id)"
say "   SANDBOX_ID=$ID2 machine=$MACHINE2 noop=$(sbx exec "$NAME" sh -c 'echo $NOOP_KIT' 2>/dev/null | tail -1) roster=$(roster)"
check "SANDBOX_ID is unchanged by a recreate" [ "$ID1" = "$ID2" ]
check "the sync config survived the recreate" [ "$MACHINE1" = "$MACHINE2" ]
check "the loop is running again" sbx exec "$NAME" sh -c 'ps -eo args | grep -q "[s]ync-loop"'
check "no second machine appeared" [ "$(roster)" = "1" ]

say "== case 2: remove the sandbox and create another with the same name"
sbx rm -f "$NAME" >/dev/null 2>&1
create; wait_joined || { say "never synced after recreate"; exit 1; }
ID3="$(sandbox_id)"; MACHINE3="$(machine_id)"
say "   SANDBOX_ID=$ID3 machine=$MACHINE3 roster=$(roster)"
check "a recreated sandbox is a new machine" [ "$ID3" != "$ID1" ]
check "the removed one stays on the roster until it is retired" [ "$(roster)" = "2" ]

say ""
[ $FAILED = 0 ] && say "PASS" || say "FAIL"
exit $FAILED
