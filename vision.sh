#!/bin/bash
# Vision mode: swap the text engine for an mlx_vlm server on the SAME port (:8081),
# so the router and dsh keep working unchanged and images actually reach the model.
#
# WHY THIS IS A SWAP, NOT A SECOND SERVICE
# The model is multimodal (333 vision_tower tensors are present in the 8-bit build),
# but `mlx-dspark serve` accepts OpenAI image_url parts and SILENTLY DROPS them -- it
# returns HTTP 200 and the model answers "there's no image attached". mlx_vlm serves
# the same weights and does pass images through. Both want ~30 GB, so on a 64 GB
# machine only one can be resident.
#
#   ./vision.sh on      images work; text still works, but no DFlash speculative decode
#   ./vision.sh off     back to mlx-dspark (faster text, images silently ignored)
#   ./vision.sh status
set -uo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate 2>/dev/null

MODEL_UNCENSORED="ailexleon/Huihui-Qwen3.8-27B-abliterated-mlx-8Bit"
MODEL_STOCK="mlx-community/Qwen3.8-27B-8bit"
PORT=8081
MARK=logs/.vision
LOCK=logs/.switch.lock

stop_all() {
  kill "$(cat logs/engine.pid 2>/dev/null)" 2>/dev/null
  pkill -f "mlx-dspark serve" 2>/dev/null
  pkill -f "mlx_vlm.server" 2>/dev/null
  for _ in $(seq 1 20); do
    pgrep -f "mlx-dspark serve|mlx_vlm.server" >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -9 -f "mlx-dspark serve|mlx_vlm.server" 2>/dev/null
  sleep 2
}

case "${1:-status}" in
  on)
    mkdir -p logs
    if ! mkdir "$LOCK" 2>/dev/null; then echo "!! a model switch is in progress; try again"; exit 0; fi
    # Both markers: .vision stops the ROUTER swapping models under us, and it also
    # tells the engine watchdog not to "restore" mlx-dspark over the top of the VLM.
    touch "$MARK"
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

    case "$(cat logs/last-model 2>/dev/null || echo uncensored)" in
      stock) M="$MODEL_STOCK" ;;
      *)     M="$MODEL_UNCENSORED" ;;
    esac
    echo "vision mode ON  -> $M"
    stop_all
    python3 -c "
import subprocess
p = subprocess.Popen(['.venv/bin/python','-m','mlx_vlm.server',
                      '--model','$M','--host','127.0.0.1','--port','$PORT',
                      '--kv-bits','8'],
                     stdout=open('logs/vision.log','w'), stderr=subprocess.STDOUT,
                     start_new_session=True)
open('logs/engine.pid','w').write(str(p.pid))
print('  vlm pid', p.pid)
"
    echo "  loading (~40-90s for 29.5 GB)…"
    for _ in $(seq 1 90); do
      curl -s --max-time 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && { echo "  ready on :$PORT"; exit 0; }
      sleep 3
    done
    echo "  !! did not come up — see logs/vision.log"; exit 1 ;;

  off)
    rm -f "$MARK"
    echo "vision mode OFF -> restoring mlx-dspark"
    stop_all
    ./switch-model.sh "$(cat logs/last-model 2>/dev/null || echo uncensored)" ;;

  status)
    if [ -f "$MARK" ]; then
      pgrep -f "mlx_vlm.server" >/dev/null && echo "vision: ON (mlx_vlm on :$PORT — images work)" \
        || echo "vision: marked ON but the server is not running"
    else
      pgrep -f "mlx-dspark serve" >/dev/null && echo "vision: OFF (mlx-dspark — images silently ignored)" \
        || echo "vision: OFF, engine not running"
    fi ;;
  *) echo "usage: $0 {on|off|status}"; exit 1 ;;
esac
