#!/bin/bash
# Switch which model the engine serves. Restarts the engine on :8081.
#   ./switch-model.sh stock        -> official Qwen3.8-27B-8bit (aligned)
#   ./switch-model.sh uncensored   -> Huihui abliterated 8-bit
#   ./switch-model.sh status       -> show what's loaded
set -e
cd "$(dirname "$0")"

# Thinking mode persists like the model does. Without this, `make sleep` + a reload,
# or a watchdog restore, silently drops thinking back to off -- you would think you had
# reasoning enabled while the engine ran --no-thinking.
mkdir -p logs
THINKING="${THINKING:-$(cat logs/last-thinking 2>/dev/null || echo off)}"
EFFORT="${EFFORT:-$(cat logs/last-effort 2>/dev/null || echo low)}"
export EFFORT

case "${1:-status}" in
  stock)
    M="mlx-community/Qwen3.8-27B-8bit"; D=""; THINK="$THINKING" ;;
  uncensored|abliterated)
    M="ailexleon/Huihui-Qwen3.8-27B-abliterated-mlx-8Bit"
    D="incoai/Qwen3.8-27B-DFlash2"; THINK="$THINKING"
    MODE_OVERRIDE="dflash" ;;   # explicit DFlash2 drafter must run in dflash mode
  status)
    curl -s --max-time 5 http://127.0.0.1:8081/v1/models 2>/dev/null \
      | python3 -c "import json,sys;d=json.load(sys.stdin)['data'][0];print('loaded:',d['x_mlx_dspark']['target'],'| mode:',d['x_mlx_dspark']['mode'])" \
      || echo "engine down"
    exit 0 ;;
  *) echo "usage: $0 {stock|uncensored|status}"; exit 1 ;;
esac

# Guard: don't kill the running engine if the target model isn't downloaded yet.
CACHE="$HOME/.cache/huggingface/hub/models--$(echo "$M" | sed 's#/#--#')"
if ! ls "$CACHE"/snapshots/*/*.safetensors >/dev/null 2>&1; then
  echo "!! $M is not downloaded yet — leaving current engine running."
  echo "   check: tail -1 logs/download-abliterated.log"
  exit 1
fi

# A model is being loaded, so the stack is no longer deliberately idle. Clearing this
# hands guard duty back to the engine watchdog (see sleep.sh).
rm -f logs/.idle

# MUTUAL EXCLUSION. Without this, a manual run of this script races the engine
# watchdog: the watchdog sees :8081 dead mid-switch, runs this script itself, and you
# end up with TWO 30 GB engines fighting for the port, the GPU and RAM -- which also
# quietly corrupts any benchmark you happen to be running.
# mkdir is atomic on POSIX, so it is a real lock; a bare marker file is not, because
# two concurrent runs each delete the other's marker on exit.
mkdir -p logs
LOCK="logs/.switch.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "!! another model switch is already in progress (${LOCK}); leaving it alone."
  echo "   if that is stale: rmdir $LOCK"
  exit 0
fi
touch logs/.swapping            # tells the watchdog the outage is deliberate
cleanup() { rm -f logs/.swapping; rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT INT TERM

echo "switching to: $M  (thinking=$THINK)"
kill "$(cat logs/engine.pid 2>/dev/null)" 2>/dev/null || true
pkill -f "mlx-dspark serve" 2>/dev/null || true
sleep 4

source .venv/bin/activate
[ -n "$D" ] && export DRAFTER="$D"

# Detach into a NEW SESSION (start_new_session=True), not just nohup.
# The router calls this script, so a plain background job makes the engine a child
# of the router's process group -- and launchd kills that whole group whenever it
# restarts the router, taking the 29.5 GB engine down with it. macOS has no setsid,
# hence python. Remember the choice so the watchdog can restore it.
echo "$1" > logs/last-model
echo "$THINK" > logs/last-thinking
echo "$EFFORT" > logs/last-effort
# KV_BITS=8 (quantized KV cache) instead of bf16: halves KV, ~5.6 GB -> ~2.8 GB at
# 64K context. Needed because at bf16 the engine's ~39 GB left the machine with
# ~26 MB free and macOS repeatedly killed the Colima VM out from under Open WebUI.
MODEL="$M" CTX="${CTX:-65536}" KV_BITS="${KV_BITS:-8}" PORT=8081 MODE="${MODE_OVERRIDE:-auto}" THINKING="$THINK" \
  python3 -c "
import subprocess, sys
p = subprocess.Popen(['./engine.sh'],
                     stdout=open('logs/engine.log','w'), stderr=subprocess.STDOUT,
                     start_new_session=True)
open('logs/engine.pid','w').write(str(p.pid))
print('engine pid', p.pid)
"
echo "loading… (first load ~40s for 29.5 GB)"
until curl -s --max-time 3 http://127.0.0.1:8081/v1/models >/dev/null 2>&1; do sleep 5; done
./switch-model.sh status
