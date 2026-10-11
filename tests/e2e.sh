#!/bin/bash
# End-to-end test: sandboxes created with the kit sync synthetic usage to a hub on this machine, and the
# totals on the host come out exactly right.
#
# Needs sbx, python3, the kit binaries (scripts/build-binaries.sh) and a host ccusage with 'sync serve'
# (scripts/build-host-binary.sh). Creates and removes N sandboxes named ccusage-e2e-*, and uses secrets
# scoped to those sandboxes, so nothing global is touched.
#
# Usage: tests/e2e.sh [number-of-sandboxes]     (default 3)
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tests/sbx-real.sh"
N="${1:-3}"
PORT="${E2E_PORT:-18791}"
BIN="${CCUSAGE_SBX_BIN:-$HOME/.local/share/ccusage-sbx/bin/ccusage}"
WORK="$(mktemp -d)"
PREFIX="ccusage-e2e-$$"
HUB="$HERE/host/ccusage-sbx-hub"
FAILED=0

export CCUSAGE_SBX_BIN="$BIN" CCUSAGE_SBX_DIR="$WORK/hub" CCUSAGE_SBX_TOKEN_FILE="$WORK/token" CCUSAGE_SBX_PORT="$PORT"

say() { printf '%s\n' "$*"; }
check() { # check <description> <command...>
  local description="$1"; shift
  if "$@"; then say "  ok    $description"; else say "  FAIL  $description"; FAILED=1; fi
}

cleanup() {
  say "== cleaning up"
  for i in $(seq 0 $((N - 1))); do sbx rm -f "$PREFIX-$i" >/dev/null 2>&1; done
  [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

command -v sbx >/dev/null || { say "sbx not found"; exit 2; }
[ -x "$BIN" ] || { say "no host ccusage at $BIN (scripts/build-host-binary.sh)"; exit 2; }
[ -s "$HERE/ccusage-kit/files/home/.local/share/ccusage-sbx/SHA256SUMS.local" ] || { say "local kit binaries missing (scripts/build-binaries.sh)"; exit 2; }

say "== starting a hub on 127.0.0.1:$PORT"
"$HUB" install --skip-service --skip-secret >/dev/null || exit 2
"$HUB" run > "$WORK/hub.log" 2>&1 &
HUB_PID=$!
sleep 2
"$HUB" status | head -1

say "== creating $N sandboxes with the kit, all at once"
creators=()
for i in $(seq 0 $((N - 1))); do
  ( sbx create --name "$PREFIX-$i" claude --kit "$HERE/ccusage-kit" \
      --kit-arg hub-port="$PORT" --kit-arg sync-interval=10 > "$WORK/create-$i.log" 2>&1 || echo "create $i failed" ) &
  creators+=($!)
done
# Not a bare 'wait': that would also wait for the hub running in the background.
wait "${creators[@]}"
for i in $(seq 0 $((N - 1))); do
  sbx secret set-custom --sandbox "$PREFIX-$i" --host localhost --env CCUSAGE_SYNC_TOKEN \
    --placeholder ccusage-hub-token --command "/bin/cat $WORK/token" >/dev/null 2>&1 || say "secret $i failed"
done

# Synthetic transcripts with known totals. Sandbox i has two days of three messages each. The JSON has to
# be compact: ccusage skips lines that do not contain the exact bytes "usage":{ .
python3 - "$WORK" "$N" <<'PY'
import json, sys, os, datetime
work, n = sys.argv[1], int(sys.argv[2])
today = datetime.datetime.now(datetime.timezone.utc).date()
for i in range(n):
    d = os.path.join(work, f"seed-{i}", "-work-demo"); os.makedirs(d)
    with open(os.path.join(d, f"session-{i}.jsonl"), "w") as out:
        for day in (0, 1):
            date = today - datetime.timedelta(days=2 - day)
            for k in range(3):
                out.write(json.dumps({
                    "type": "assistant", "timestamp": f"{date}T10:0{k}:00.000Z", "sessionId": f"sess-{i}",
                    "requestId": f"req_{i}_{day}_{k}", "cwd": "/work/demo", "version": "2.1.212",
                    "message": {"id": f"msg_{i}_{day}_{k}", "role": "assistant", "model": "claude-sonnet-4-5-20250929",
                                "usage": {"input_tokens": (i+1)*10+k, "output_tokens": (i+1)*100+10*k+day,
                                          "cache_creation_input_tokens": 1000*(i+1)+k,
                                          "cache_read_input_tokens": 5000*(i+1)+day}}}, separators=(",", ":")) + "\n")
PY
for i in $(seq 0 $((N - 1))); do
  sbx cp "$WORK/seed-$i/-work-demo" "$PREFIX-$i":/home/agent/.claude/projects/ >/dev/null 2>&1
  sbx exec -u root "$PREFIX-$i" chown -R agent:agent /home/agent/.claude/projects/-work-demo
done

# Sandboxes with nothing attached stop on their own within a couple of minutes, so keep poking them.
rolled_up() { # rolled_up <expected machine count>
  python3 - "$WORK/hub/data/ccusage/v1/rollup/daily.json" "$1" <<'PY'
import json, sys
try: days = json.load(open(sys.argv[1]))["days"]
except Exception: sys.exit(1)
machines = {r["machine"] for rows in days.values() for r in rows if not r.get("suppressed")}
sys.exit(0 if len(machines) >= int(sys.argv[2]) else 1)
PY
}
say "== waiting for every sandbox to reach the hub (up to 5 minutes)"
deadline=$((SECONDS + 300))
until rolled_up "$N"; do
  [ $SECONDS -ge $deadline ] && break
  for i in $(seq 0 $((N - 1))); do sbx exec "$PREFIX-$i" true >/dev/null 2>&1; done
  sleep 10
done
say "   (after $SECONDS s)"

totals() { # totals -> "in out cw cr machines users" from the host's rollup
  python3 - "$WORK/hub/data/ccusage/v1" <<'PY'
import json, sys, os
base = sys.argv[1]
days = json.load(open(f"{base}/rollup/daily.json"))["days"]
t = dict(i=0, o=0, w=0, r=0); machines = set()
for rows in days.values():
    for r in rows:
        if r.get("suppressed"): continue
        machines.add(r["machine"])
        for key, field in (("i", "in"), ("o", "out"), ("w", "cw"), ("r", "cr")): t[key] += r.get(field, 0)
print(t["i"], t["o"], t["w"], t["r"], len(machines), len(os.listdir(f"{base}/users")))
PY
}
expected() { # expected <extra output tokens to add, for the flush step>
  python3 - "$N" "$1" <<'PY'
import sys
n, extra = int(sys.argv[1]), int(sys.argv[2])
i_ = o = w = r = 0
for i in range(n):
    for day in (0, 1):
        for k in range(3):
            i_ += (i+1)*10+k; o += (i+1)*100+10*k+day; w += 1000*(i+1)+k; r += 5000*(i+1)+day
print(i_, o + extra, w, r, n, 1)
PY
}

say "== checking totals on the host"
check "totals equal the sum of what the sandboxes were given (in out cw cr machines users): $(expected 0)" \
  [ "$(totals)" = "$(expected 0)" ]
check "the roster has $N machines" [ "$(find "$WORK/hub/data" -path '*/machines/*/machine.json' | wc -l | tr -d ' ')" = "$N" ]

say "== flush: add usage to the first sandbox, then flush it from the host"
sbx exec "$PREFIX-0" sh -c 'cat > ~/.claude/projects/-work-demo/extra.jsonl' <<EOF
{"type":"assistant","timestamp":"$(date -u -v-1d +%Y-%m-%dT12:00:00.000Z 2>/dev/null || date -u -d yesterday +%Y-%m-%dT12:00:00.000Z)","sessionId":"sess-extra","requestId":"req_extra","cwd":"/work/demo","version":"2.1.212","message":{"id":"msg_extra","role":"assistant","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":0,"output_tokens":777,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
"$HUB" flush "$PREFIX-0"
check "the flushed usage shows up on the host at once" \
  [ "$(totals | cut -d' ' -f2)" = "$(expected 777 | cut -d' ' -f2)" ]

say "== pruning: delete that transcript inside the sandbox, as age-based cleanup would, and flush again"
sbx exec "$PREFIX-0" rm -f /home/agent/.claude/projects/-work-demo/extra.jsonl
"$HUB" flush "$PREFIX-0"
check "deleting a transcript in a sandbox does not lower the host's totals" \
  [ "$(totals | cut -d' ' -f2)" = "$(expected 777 | cut -d' ' -f2)" ]
sbx exec "$PREFIX-0" sh -c 'ccusage sync run --config "$HOME/.local/state/ccusage-sbx/ccusage.json"' 2>&1 | tail -1 | grep -q "Nothing to sync" \
  && say "  ok    and the next sync has nothing to do" || { say "  FAIL  the next sync was not quiet"; FAILED=1; }

say "== the host dashboard serves what the explorer needs"
"$HUB" dashboard > "$WORK/dash.log" 2>&1 &
DASH_PID=$!
for _ in $(seq 1 20); do grep -q "http://127.0.0.1:" "$WORK/dash.log" && break; sleep 0.5; done
DASH_URL="$(grep -o 'http://127.0.0.1:[0-9]*' "$WORK/dash.log" | head -1)"
json() { curl -s "$DASH_URL/data/$1.json"; }
check "machines.json names every sandbox by its label" \
  [ "$(json machines | python3 -c "import json,sys; m=json.load(sys.stdin)['machines']; print(sum(1 for x in m if x['label'].startswith('$PREFIX-')))")" = "$N" ]
check "sessions.json has a session per sandbox" \
  [ "$(json sessions | python3 -c "import json,sys; print(len(json.load(sys.stdin)['sessions']))")" -ge "$N" ]
PROJECT="$(json sessions | python3 -c "import json,sys; print(json.load(sys.stdin)['sessions'][0]['project'])")"
say "   a session's project, as synced: $PROJECT"
check "the project is the real name, not a hash (project-names defaults to plain)" \
  [ -n "$PROJECT" ] && [ "${PROJECT#sha256:}" = "$PROJECT" ]
check "the page itself is served" [ "$(curl -s -o /dev/null -w '%{http_code}' "$DASH_URL/")" = "200" ]
kill "$DASH_PID" 2>/dev/null

say ""
if [ $FAILED = 0 ]; then
  say "PASS"
else
  say "FAIL. Diagnostics:"
  for i in $(seq 0 $((N - 1))); do
    say "--- $PREFIX-$i sync log"; sbx exec "$PREFIX-$i" sh -c 'tail -12 ~/.local/state/ccusage-sbx/sync.log' 2>&1 | cut -c1-200
  done
  say "--- hub data"; (cd "$WORK/hub/data" 2>/dev/null && find . -type f | sort | sed 's|^|    |')
  say "--- hub log"; tail -5 "$WORK/hub.log"
fi
exit $FAILED
