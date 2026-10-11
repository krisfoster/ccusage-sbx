#!/bin/sh
# Keeps this sandbox's usage synced to the ccusage hub on the host.
#
# Started on every container start. Joins the hub once (retrying until it can), then runs
# `ccusage sync run` forever. A failed run is repeated after a short random delay: the engine
# gives up after a few collisions on the shared rollups when many sandboxes sync together, and the
# shards it already uploaded make a repeat cheap. Never exits non-zero into anything that cares.
#
# SIGUSR1 means "sync now". The agent hooks (sync-now.sh) send it when a turn or a session ends, so
# the last of the usage does not wait for the timer. Syncs stay at least MIN_GAP seconds apart.
set -u

# A hook can signal this process at any moment. Until the real handler is installed below, a signal
# must not kill it, which is what SIGUSR1 does by default.
trap ':' USR1

STATE="${CCUSAGE_STATE_DIR:-$HOME/.local/state/ccusage-sbx}"
CONFIG="$STATE/ccusage.json"
LOG="$STATE/sync.log"
PIDFILE="$STATE/loop.pid"
URL="${CCUSAGE_HUB_URL:?CCUSAGE_HUB_URL is not set}"
INTERVAL="${CCUSAGE_SYNC_INTERVAL:-600}"
MACHINE_ID="${SANDBOX_ID:-$(hostname)}"
MACHINE_LABEL="${SANDBOX_NAME:-$(hostname)}"
LOG_LIMIT=1048576
MIN_GAP="${CCUSAGE_SYNC_MIN_GAP:-20}"

mkdir -p "$STATE"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

# A number in 0..$1-1. The shell has no RANDOM, so read the kernel's.
rand() {
  value=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
  echo $((value % $1))
}

# One copy per container. A stale pid file from a previous run does not count.
if [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null \
    && tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q sync-loop; then
    exit 0
  fi
fi
echo $$ > "$PIDFILE"

if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt "$LOG_LIMIT" ]; then
  mv -f "$LOG" "$LOG.1"
fi

ccusage_sync() { ccusage sync "$@" --config "$CONFIG"; }

# Sleeping in the background and waiting on it lets a signal interrupt the wait.
pause() {
  sleep "$1" &
  SLEEPER=$!
  wait "$SLEEPER" 2>/dev/null
  SLEEPER=
}

SLEEPER=
KICKED=0
kicked() {
  KICKED=1
  log "an agent asked for a sync"
  [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null
}
trap kicked USR1

# Waits out `seconds`, however many times a kick cuts a sleep short.
wait_for() {
  deadline=$(($(date +%s) + $1))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    pause $((deadline - $(date +%s)))
  done
}

stopping() {
  log "stopping, running a last sync"
  [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null
  ccusage_sync run >> "$LOG" 2>&1 || true
  rm -f "$PIDFILE"
  exit 0
}
trap stopping TERM INT

# Machines started together should not all arrive at the hub at the same instant.
pause "$(rand 30)"

configured() { [ -s "$CONFIG" ] && grep -q '"machineId"' "$CONFIG"; }

until configured; do
  log "joining the hub at $URL as $MACHINE_ID ($MACHINE_LABEL)"
  if ccusage sync setup --provider http --url "$URL" \
    --machine-id "$MACHINE_ID" --machine-label "$MACHINE_LABEL" \
    --non-interactive --config "$CONFIG" >> "$LOG" 2>&1; then
    break
  fi
  log "could not join the hub (see the error above). Is the hub running on the host, and is the token secret registered? Trying again shortly"
  pause $((10 + $(rand 50)))
done

# Whether project paths are synced as they are or as hashes is a setting in the sync config. Set it on every
# start so the kit argument wins, and only write the file when it changes.
apply_project_names() {
  redact=true
  [ "${CCUSAGE_PROJECT_NAMES:-plain}" = plain ] && redact=false
  command -v jq > /dev/null 2>&1 || return 0
  tmp=$(mktemp "$CONFIG.XXXXXX") || return 0
  if jq --argjson redact "$redact" '.sync.redactProjects = $redact' "$CONFIG" > "$tmp" && ! cmp -s "$tmp" "$CONFIG"; then
    cp "$tmp" "$CONFIG"
    log "project names will be synced as: ${CCUSAGE_PROJECT_NAMES:-plain}"
  fi
  rm -f "$tmp"
}
apply_project_names

sync_once() {
  attempt=1
  while :; do
    if ccusage_sync run >> "$LOG" 2>&1; then
      log "sync ok"
      return 0
    fi
    if [ "$attempt" -ge 6 ]; then
      log "sync failed $attempt times; waiting for the next interval"
      return 1
    fi
    attempt=$((attempt + 1))
    pause $((3 + $(rand 25)))
  done
}

LAST=0
while :; do
  KICKED=0
  since=$(($(date +%s) - LAST))
  [ "$since" -lt "$MIN_GAP" ] && wait_for $((MIN_GAP - since))
  sync_once || true
  LAST=$(date +%s)
  # Asked to sync again while this one ran: usage may have arrived since it read the logs.
  [ "$KICKED" = 1 ] && continue
  pause $((INTERVAL + $(rand 60)))
done
