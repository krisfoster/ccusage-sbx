#!/bin/sh
# Agent hook: asks the sync loop to sync now. Registered by install-hooks.sh for Claude Code, Gemini CLI
# and GitHub Copilot CLI (turn-end and session-end hooks) and Codex (the notify setting).
#
# It has to return at once and never fail. Agents run hooks in line with their own work, so a hook that
# takes seconds slows every turn, and one that exits non-zero can stop the agent. The sync itself runs in
# the loop, which outlives the hook.
# Claude Code sends its event on stdin and closes it, so drain that. Codex's notify passes it as an
# argument instead and leaves stdin alone, where waiting for end-of-file could wait for ever.
if [ "$#" -eq 0 ] && [ ! -t 0 ]; then
  timeout 1 cat > /dev/null 2>&1
fi

STATE="${CCUSAGE_STATE_DIR:-$HOME/.local/state/ccusage-sbx}"
DIR=/home/agent/.local/share/ccusage-sbx
pid=$(cat "$STATE/loop.pid" 2>/dev/null || true)

if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
  && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q sync-loop; then
  kill -USR1 "$pid" 2>/dev/null
else
  # No loop is running, so start one. It exits at once if another instance appears in the meantime.
  setsid sh "$DIR/sync-loop.sh" > /dev/null 2>&1 < /dev/null &
fi
# Gemini CLI requires a hook to print JSON on stdout and nothing else. An empty object is a valid answer
# to every agent that reads one, and the others ignore it.
echo "{}"
exit 0
