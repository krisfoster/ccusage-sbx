#!/bin/sh
# Registers sync-now.sh as a hook with the agents in this sandbox that have one (Claude Code, Codex, Gemini
# CLI and GitHub Copilot CLI), so usage is synced as soon as a turn or a session ends. Other agents are
# covered by the timer alone. Runs on every container start, so it must be idempotent, and it
# merges into the agent's own settings: whatever hooks the user already has are kept.
#
# Never fails the start-up. A hook that cannot be registered only means the timer does the syncing.
# The container's start-up runs with a clean environment, without the agents' own bin directory.
PATH="$HOME/.local/bin:/usr/local/bin:/usr/local/share/npm-global/bin:$PATH"
HOOK="sh /home/agent/.local/share/ccusage-sbx/sync-now.sh"
STATE="${CCUSAGE_STATE_DIR:-$HOME/.local/state/ccusage-sbx}"
mkdir -p "$STATE"
log() { printf '%s hooks: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE/sync.log"; }

# Claude Code and Gemini CLI keep hooks in their settings.json under "hooks", as event -> groups -> hooks.
# Merges this sandbox's hook into `settings`, replacing an earlier copy of it and leaving everything else
# the user has. $2 is the hook's timeout field as the agent wants it, $3 and up are the events.
merge_json_hooks() {
  settings="$1"; timeout_json="$2"; shift 2
  command -v jq > /dev/null 2>&1 || { log "jq is missing, so no hook was registered in $settings"; return 1; }
  mkdir -p "$(dirname "$settings")"
  [ -s "$settings" ] || echo '{}' > "$settings"
  if ! jq -e . "$settings" > /dev/null 2>&1; then
    log "$settings is not valid JSON, so no hook was registered in it"
    return 1
  fi
  tmp=$(mktemp "$settings.XXXXXX") || return 1
  events=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  if jq --arg cmd "$HOOK" --argjson timeout "$timeout_json" --argjson events "$events" '
      .hooks = (.hooks // {})
      | reduce $events[] as $event (.;
          .hooks[$event] = (
            ((.hooks[$event] // []) | map(select(((.hooks // []) | any(.command == $cmd)) | not)))
            + [{hooks: [{type: "command", command: $cmd, timeout: $timeout}]}]))
    ' "$settings" > "$tmp" && ! cmp -s "$tmp" "$settings"; then
    cp "$tmp" "$settings"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 2
}

# Claude Code: Stop fires after every response, SessionEnd when the process exits. Hooks run in line
# with the agent, so the command has to return at once (sync-now.sh does). Timeouts are in seconds.
claude_hooks() {
  command -v claude > /dev/null 2>&1 || [ -d "$HOME/.claude" ] || return 0
  merge_json_hooks "$HOME/.claude/settings.json" 5 Stop SessionEnd
  [ $? -eq 0 ] && log "registered the sync hook with Claude Code"
  return 0
}

# Gemini CLI: AfterAgent fires when the agent has finished answering, SessionEnd when the CLI exits (which
# it does not wait for, so that one is best-effort). Timeouts are in milliseconds.
gemini_hooks() {
  [ -f "$HOME/.gemini/settings.json" ] || return 0
  merge_json_hooks "$HOME/.gemini/settings.json" 5000 AfterAgent SessionEnd
  [ $? -eq 0 ] && log "registered the sync hook with Gemini CLI"
  return 0
}

# GitHub Copilot CLI reads every file in ~/.copilot/hooks/, so the hook is a file of its own and nothing of
# the user's is edited. agentStop fires when the agent finishes a turn. The files apply to -p mode too.
copilot_hooks() {
  [ -d "$HOME/.copilot" ] || return 0
  dir="$HOME/.copilot/hooks"
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.ccusage-sync.XXXXXX") || return 0
  cat > "$tmp" <<JSON
{
  "version": 1,
  "hooks": {
    "agentStop": [{ "type": "command", "bash": "$HOOK", "timeoutSec": 5 }],
    "sessionEnd": [{ "type": "command", "bash": "$HOOK", "timeoutSec": 5 }]
  }
}
JSON
  if cmp -s "$tmp" "$dir/ccusage-sync.json"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$dir/ccusage-sync.json" && log "registered the sync hook with GitHub Copilot CLI"
  fi
  return 0
}

# Codex: `notify` runs a program when a turn completes, and works without the hook trust that Codex's own
# hooks need (nobody is there to grant it in a sandbox). It is one top-level key, so it can only be
# added when the user has no notify of their own, and it must come before the first [table].
codex_notify() {
  # Codex's own config file is the sign it is here: the binary is not on the start-up PATH.
  config="$HOME/.codex/config.toml"
  [ -f "$config" ] || return 0
  before_tables=$(awk '/^[[:space:]]*\[/ { exit } { print }' "$config")
  if printf '%s\n' "$before_tables" | grep -q '^[[:space:]]*notify[[:space:]]*='; then
    if printf '%s\n' "$before_tables" | grep '^[[:space:]]*notify[[:space:]]*=' | grep -q 'sync-now.sh'; then
      return 0
    fi
    log "Codex already has a notify program, so the sync hook was not registered"
    return 0
  fi
  tmp=$(mktemp "$HOME/.codex/config.XXXXXX") || return 0
  { printf 'notify = ["sh", "/home/agent/.local/share/ccusage-sbx/sync-now.sh"]\n'; cat "$config"; } > "$tmp" \
    && cp "$tmp" "$config" && log "registered the sync hook with Codex"
  rm -f "$tmp"
}

if [ "${CCUSAGE_AGENT_HOOKS:-on}" = "off" ]; then
  exit 0
fi
claude_hooks
gemini_hooks
copilot_hooks
codex_notify
exit 0
