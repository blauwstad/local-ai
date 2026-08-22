#!/bin/bash
# Engine watchdog — keeps the MLX engine on :8081 alive for dsh.
#
# The stack is now host-only: dsh :3080 -> router :8090 -> engine :8081.
# No Docker, no Colima VM, no nginx (see README: the Open WebUI layer was removed).
#
# The engine still needs watching: it wires ~34 GB, and if macOS kills it the router
# would cold-load it on the next request -- a 60-85s stall that a client reports as a
# plain error. Restoring it in the background keeps that off the user's path.
#
# Disable temporarily:  touch /Users/vahdetd/local-ai/.watchdog-off
cd "$(dirname "$0")"
LOG=logs/engine-watchdog.log
INTERVAL="${WATCHDOG_INTERVAL:-30}"
CONFIRM="${WATCHDOG_CONFIRM:-3}"     # tolerate a restart in flight
COOLDOWN="${WATCHDOG_COOLDOWN:-120}"
fails=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "engine watchdog started (interval ${INTERVAL}s, confirm ${CONFIRM})"
while true; do
  if [ -f .watchdog-off ]; then sleep "$INTERVAL"; continue; fi

  if curl -s --max-time 5 http://127.0.0.1:8081/v1/models >/dev/null 2>&1; then
    fails=0; sleep "$INTERVAL"; continue
  fi

  # `make sleep` unloaded the engine on purpose to free its ~34 GB. Reloading it
  # behind the user's back would defeat the entire point. Cleared by switch-model.sh,
  # so guarding resumes as soon as a model is loaded again.
  if [ -f logs/.idle ]; then
    fails=0; sleep "$INTERVAL"; continue
  fi

  # A model swap takes the engine down on purpose for 15-85s. Never race the router
  # for :8081 -- two engines fighting for the port is worse than a slow swap.
  # vision mode runs mlx_vlm on :8081 instead of mlx-dspark; do not "restore" over it
  if [ -f logs/.vision ]; then
    fails=0; sleep "$INTERVAL"; continue
  fi

  if [ -d logs/.switch.lock ] || [ -f logs/.swapping ]; then
    log "engine down, but a swap is in progress -- leaving it to the router"
    fails=0; sleep "$INTERVAL"; continue
  fi

  fails=$((fails+1))
  if [ "$fails" -lt "$CONFIRM" ]; then
    log "engine unreachable ($fails/$CONFIRM)"
    sleep "$INTERVAL"; continue
  fi

  want=$(cat logs/last-model 2>/dev/null); [ -n "$want" ] || want=uncensored
  log "engine down -> restoring '$want'"
  if ./switch-model.sh "$want" >>"$LOG" 2>&1; then
    log "engine restored ($want); cooling down ${COOLDOWN}s"
  else
    log "ERROR: engine restore failed; cooling down ${COOLDOWN}s"
  fi
  fails=0
  sleep "$COOLDOWN"
done
