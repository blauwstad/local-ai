#!/bin/bash
# Colima availability watchdog.
#
# WHY THIS EXISTS
# The MLX engine wires ~29.5 GB of RAM (--wired-limit) and a model swap loads a
# second copy before the first is released. Under that pressure macOS reclaims
# memory from the Colima VM, and it fails in TWO different ways:
#
#   1. the VM survives but its host port-forwards are killed
#      -> `colima list` still says Running, yet :3000/:8080/docker.sock are all dead
#   2. the whole VM process is killed
#      -> `colima list` says Stopped
#
# Either way Open WebUI shows "load failed". This repairs both.
#
# Disable temporarily:  touch /Users/vahdetd/local-ai/.watchdog-off
cd "$(dirname "$0")"
LOG=logs/colima-watchdog.log
INTERVAL="${WATCHDOG_INTERVAL:-30}"
# Require repeated failures: a `colima restart` (ours or yours) makes the socket
# unavailable for ~20s, and that is not a fault to "repair".
CONFIRM="${WATCHDOG_CONFIRM:-3}"
COOLDOWN="${WATCHDOG_COOLDOWN:-180}"
fails=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# The MLX engine is a HOST process, independent of Docker. If it dies, the router
# will cold-load it on the next request -- but that takes 60-85s, which Open WebUI
# reports to the user as "500: Internal Error". Keeping it warm avoids that entirely.
engine_fails=0
check_engine() {
  if curl -s --max-time 5 http://127.0.0.1:8081/v1/models >/dev/null 2>&1; then
    engine_fails=0
    return
  fi
  # A swap takes the engine down on purpose; never race the router for :8081.
  if [ -f logs/.swapping ]; then
    log "engine down but a swap is in progress -- leaving it to the router"
    engine_fails=0
    return
  fi
  engine_fails=$((engine_fails+1))
  if [ "$engine_fails" -lt "$CONFIRM" ]; then
    log "engine unreachable ($engine_fails/$CONFIRM)"
    return
  fi
  local want
  want=$(cat logs/last-model 2>/dev/null)
  [ -n "$want" ] || want=uncensored
  log "engine down -> restoring '$want'"
  ./switch-model.sh "$want" >>"$LOG" 2>&1 && log "engine restored ($want)" \
    || log "ERROR: engine restore failed"
  engine_fails=0
}

log "watchdog started (interval ${INTERVAL}s, confirm ${CONFIRM}, cooldown ${COOLDOWN}s)"
while true; do
  if [ -f .watchdog-off ]; then
    sleep "$INTERVAL"; continue
  fi

  check_engine

  if docker ps >/dev/null 2>&1; then
    fails=0
    sleep "$INTERVAL"; continue
  fi

  fails=$((fails+1))
  if [ "$fails" -lt "$CONFIRM" ]; then
    log "docker unreachable ($fails/$CONFIRM) -- may be a restart in flight; waiting"
    sleep "$INTERVAL"; continue
  fi

  state=$(colima list 2>/dev/null | awk '$1=="default"{print $2}')
  case "$state" in
    Running)
      log "VM Running but socket dead -> port-forwards were killed; restarting colima"
      colima restart >>"$LOG" 2>&1 ;;
    Stopped|"")
      log "VM is ${state:-absent} -> killed by memory pressure; starting colima"
      colima start >>"$LOG" 2>&1 ;;
    *)
      log "VM state '$state' -> attempting start"
      colima start >>"$LOG" 2>&1 ;;
  esac

  sleep 5
  if docker ps >/dev/null 2>&1; then
    log "repaired: docker reachable again; cooling down ${COOLDOWN}s"
  else
    log "ERROR: still unreachable after repair; cooling down ${COOLDOWN}s"
  fi
  fails=0
  sleep "$COOLDOWN"
done
