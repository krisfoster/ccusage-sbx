#!/bin/bash
# The agent hooks: usage reaches the host within seconds of a real turn, although the sync timer is set to
# five minutes, and registering is idempotent and keeps the user's own hooks and settings.
#
# Covers Claude Code, Codex, Gemini CLI and GitHub Copilot CLI. It makes one tiny request to each agent that
# has credentials in its sandbox (sbx holds them for Claude and Codex; Gemini needs `sbx secret set google`
# and Copilot `sbx secret set github`). Without credentials a turn cannot succeed, so:
#   - Gemini still has to show that its SessionEnd hook ran (a sync starts when the CLI exits);
#   - Copilot never starts a session, so its firing is reported as SKIPPED, not passed.
# Needs sbx, the kit binaries and a host ccusage with 'sync serve'; see tests/e2e.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${E2E_PORT:-18793}"
BIN="${CCUSAGE_SBX_BIN:-$HOME/.local/share/ccusage-sbx/bin/ccusage}"
WORK="$(mktemp -d)"
NAME="ccusage-hooks-$$"
CODEX="ccusage-hooks-codex-$$"
GEMINI="ccusage-hooks-gemini-$$"
COPILOT="ccusage-hooks-copilot-$$"
SKIPPED=0
HUB="$HERE/host/ccusage-sbx-hub"
FAILED=0
export CCUSAGE_SBX_BIN="$BIN" CCUSAGE_SBX_DIR="$WORK/hub" CCUSAGE_SBX_TOKEN_FILE="$WORK/token" CCUSAGE_SBX_PORT="$PORT"

say() { printf '%s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then say "  ok    $d"; else say "  FAIL  $d"; FAILED=1; fi; }
skip() { say "  SKIP  $1"; SKIPPED=$((SKIPPED + 1)); }
cleanup() { sbx rm -f "$NAME" "$CODEX" "$GEMINI" "$COPILOT" >/dev/null 2>&1; [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

"$HUB" install --skip-service --skip-secret >/dev/null || exit 2
"$HUB" run > "$WORK/hub.log" 2>&1 &
HUB_PID=$!
sleep 2

say "== create one sandbox per agent, each with a five minute timer, so only a hook can explain a quick sync"
for sandbox in "$NAME:claude" "$CODEX:codex" "$GEMINI:gemini" "$COPILOT:copilot"; do
  ( sbx create --name "${sandbox%%:*}" "${sandbox##*:}" --kit "$HERE/ccusage-kit" --kit-arg hub-port="$PORT" --kit-arg sync-interval=300 >/dev/null 2>&1 ) &
done
wait $(jobs -p | grep -v "^$HUB_PID$")
for sandbox in "$NAME" "$CODEX" "$GEMINI" "$COPILOT"; do
  sbx secret set-custom --sandbox "$sandbox" --host localhost --env CCUSAGE_SYNC_TOKEN \
    --placeholder ccusage-hub-token --command "/bin/cat $WORK/token" >/dev/null 2>&1
  deadline=$((SECONDS + 150))
  until sbx exec "$sandbox" sh -c 'grep -q "sync ok" ~/.local/state/ccusage-sbx/sync.log' 2>/dev/null; do
    [ $SECONDS -ge $deadline ] && { say "$sandbox never joined the hub"; exit 1; }
    sleep 5
  done
done

output_tokens() {
  python3 - "$WORK/hub/data/ccusage/v1/rollup/daily.json" <<'PY'
import json, sys
try: days = json.load(open(sys.argv[1]))["days"]
except Exception: print(0); sys.exit()
print(sum(r.get("out", 0) for rows in days.values() for r in rows if not r.get("suppressed")))
PY
}
hook_entries() { # hook_entries <event>
  sbx exec "$NAME" sh -c "jq '[.hooks.$1[]?.hooks[]? | select(.command | contains(\"sync-now.sh\"))] | length' ~/.claude/settings.json" 2>/dev/null | tail -1
}

say "== the hook is registered, once per event"
check "Stop hook registered once" [ "$(hook_entries Stop)" = "1" ]
check "SessionEnd hook registered once" [ "$(hook_entries SessionEnd)" = "1" ]

say "== a real Claude turn: usage must reach the host long before the 5 minute timer"
BEFORE="$(output_tokens)"
sbx exec "$NAME" sh -c 'cd /tmp && claude -p "reply with the single word ok" --model haiku' 2>&1 | tail -1
DONE=$(date +%s)
until [ "$(output_tokens)" -gt "$BEFORE" ]; do
  [ $(( $(date +%s) - DONE )) -ge 60 ] && break
  sleep 1
done
ELAPSED=$(( $(date +%s) - DONE ))
say "   output tokens on the host: $BEFORE -> $(output_tokens), $ELAPSED s after the turn finished"
check "the turn's usage reached the host within 60 seconds" [ "$(output_tokens)" -gt "$BEFORE" ]
check "and it was the hook, not the timer (the timer is 300 seconds)" [ "$ELAPSED" -lt 60 ]

say "== the hook returns at once"
START=$(date +%s)
sbx exec "$NAME" sh -c 'echo "{}" | sh /home/agent/.local/share/ccusage-sbx/sync-now.sh; echo "exit=$?"' 2>&1 | tail -1
check "sync-now.sh finished in under 3 seconds" [ $(( $(date +%s) - START )) -lt 3 ]

say "== registering again keeps one hook, and keeps a hook the user already had"
sbx exec "$NAME" sh -c 'f=$HOME/.claude/settings.json; jq ".hooks.Stop += [{hooks:[{type:\"command\",command:\"echo the-users-own-hook\"}]}]" $f > /tmp/s.json && cp /tmp/s.json $f'
sbx stop "$NAME" >/dev/null 2>&1
sbx exec "$NAME" true >/dev/null 2>&1
sleep 3
check "still one sync hook for Stop after a restart" [ "$(hook_entries Stop)" = "1" ]
check "still one sync hook for SessionEnd after a restart" [ "$(hook_entries SessionEnd)" = "1" ]
check "the user's own hook is still there" \
  sbx exec "$NAME" sh -c 'jq -e "[.hooks.Stop[]?.hooks[]? | select(.command == \"echo the-users-own-hook\")] | length == 1" ~/.claude/settings.json >/dev/null'
check "other settings were not disturbed" \
  sbx exec "$NAME" sh -c 'jq -e ".permissions.defaultMode == \"bypassPermissions\"" ~/.claude/settings.json >/dev/null'

say "== Codex: its notify setting is registered once, and a real turn syncs at once"
check "Codex notify registered once" \
  [ "$(sbx exec "$CODEX" sh -c "grep -c '^notify.*sync-now.sh' ~/.codex/config.toml" 2>/dev/null | tail -1)" = "1" ]
BEFORE="$(output_tokens)"
sbx exec "$CODEX" sh -c 'cd /tmp && codex exec --skip-git-repo-check "reply with the single word ok" < /dev/null' 2>&1 | tail -1
DONE=$(date +%s)
until [ "$(output_tokens)" -gt "$BEFORE" ]; do
  [ $(( $(date +%s) - DONE )) -ge 60 ] && break
  sleep 1
done
say "   output tokens on the host: $BEFORE -> $(output_tokens), $(( $(date +%s) - DONE )) s after the turn finished"
check "the Codex turn's usage reached the host within 60 seconds" [ "$(output_tokens)" -gt "$BEFORE" ]
sbx stop "$CODEX" >/dev/null 2>&1
sbx exec "$CODEX" true >/dev/null 2>&1
sleep 3
check "still one Codex notify after a restart" \
  [ "$(sbx exec "$CODEX" sh -c "grep -c '^notify.*sync-now.sh' ~/.codex/config.toml" 2>/dev/null | tail -1)" = "1" ]

# How many times an agent hook has asked the loop to sync. Counting syncs would not do: a container that
# stopped and was restarted by this script syncs on its own when the loop starts.
syncs() { sbx exec "$1" sh -c 'grep -c "an agent asked for a sync" ~/.local/state/ccusage-sbx/sync.log' 2>/dev/null | tail -1; }

# Runs one turn in a sandbox and says what the hook did: "usage" if the turn succeeded and its usage reached
# the host, "triggered" if the turn failed (no credentials) but the agent still asked for a sync, and
# "nothing" or "failed-and-nothing" if no hook fired.
turn_result() { # turn_result <sandbox> <command>
  local sandbox="$1" before_tokens before_syncs rc waited
  before_tokens="$(output_tokens)"; before_syncs="$(syncs "$sandbox")"
  sbx exec "$sandbox" sh -c "cd /tmp && $2" > "$WORK/turn-$sandbox.log" 2>&1; rc=$?
  for waited in $(seq 1 45); do
    if [ "$rc" = 0 ] && [ "$(output_tokens)" -gt "$before_tokens" ]; then echo usage; return; fi
    if [ "$rc" != 0 ] && [ "$(syncs "$sandbox")" -gt "$before_syncs" ]; then echo triggered; return; fi
    sleep 1
  done
  [ "$rc" = 0 ] && echo "nothing" || echo "failed-and-nothing"
}

say "== Gemini CLI: AfterAgent and SessionEnd are registered once each, with the user's own hook kept"
gemini_count() { sbx exec "$GEMINI" sh -c "jq '[.hooks.$1[]?.hooks[]? | select(.command | contains(\"sync-now.sh\"))] | length' ~/.gemini/settings.json" 2>/dev/null | tail -1; }
check "AfterAgent hook registered once" [ "$(gemini_count AfterAgent)" = "1" ]
check "SessionEnd hook registered once" [ "$(gemini_count SessionEnd)" = "1" ]
check "the sandbox's other Gemini settings are intact" \
  sbx exec "$GEMINI" sh -c 'jq -e ".mcpServers[\"mcp-gateway\"] and .security.folderTrust.enabled == false" ~/.gemini/settings.json >/dev/null'
RESULT="$(turn_result "$GEMINI" 'gemini -p "reply with the single word ok" < /dev/null')"
case "$RESULT" in
  usage) say "   a real Gemini turn: its usage reached the host"; check "Gemini usage reached the host" true ;;
  triggered) say "   the Gemini turn failed (no credentials), but exiting still asked the loop to sync"
             check "Gemini's SessionEnd hook triggered a sync (AfterAgent needs a successful turn and was not exercised)" true ;;
  *) check "Gemini hook fired ($RESULT)" false ;;
esac
sbx stop "$GEMINI" >/dev/null 2>&1; sbx exec "$GEMINI" true >/dev/null 2>&1; sleep 3
check "still one Gemini hook per event after a restart" \
  [ "$(gemini_count AfterAgent)$(gemini_count SessionEnd)" = "11" ]

say "== GitHub Copilot CLI: its own hook file is written, and nothing of the user's was edited"
check "ccusage-sync.json has both events and the right command" \
  sbx exec "$COPILOT" sh -c 'jq -e ".version == 1 and (.hooks.agentStop[0].bash | contains(\"sync-now.sh\")) and (.hooks.sessionEnd[0].bash | contains(\"sync-now.sh\"))" ~/.copilot/hooks/ccusage-sync.json >/dev/null'
check "Copilot's own config.json is untouched" \
  sbx exec "$COPILOT" sh -c 'jq -e ".trusted_folders" ~/.copilot/config.json >/dev/null'
RESULT="$(turn_result "$COPILOT" 'copilot -p "reply with the single word ok" < /dev/null')"
case "$RESULT" in
  usage) check "Copilot usage reached the host" true ;;
  failed-and-nothing) skip "Copilot could not start a session (no GitHub credentials in the sandbox), so firing was NOT verified. Store one with 'sbx secret set github' and rerun" ;;
  *) check "Copilot hook fired ($RESULT)" false ;;
esac

say ""
[ "$SKIPPED" -gt 0 ] && say "($SKIPPED check(s) skipped)"
[ $FAILED = 0 ] && say "PASS" || say "FAIL"
exit $FAILED
