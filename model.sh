#!/bin/bash
# See and switch the local model. This is the ONE place model choice lives.
#
#   ./model.sh                which build is loaded right now
#   ./model.sh uncensored     switch to the abliterated build
#   ./model.sh stock          switch to the aligned build
#
# Clients (dsh, any OpenAI client) cannot change this: the router is pinned and
# ignores the `model` field, because a stray click in dsh's picker used to rewrite
# its settings file and silently swap the engine. See ./pin-model.sh.
cd "$(dirname "$0")"

show() {
  # In vision mode :8081 is mlx_vlm, whose /v1/models lists every cached repo -- the
  # first entry is NOT necessarily the loaded one. Read the actual --model flag.
  if [ -f logs/.vision ]; then
    # Right after a swap the old server is gone and the new one is not in ps yet, so a
    # single read returns nothing and the label prints "unknown". Retry briefly.
    repo=""
    for _ in $(seq 1 15); do
      repo=$(ps -Ao command | grep -E "[m]lx_vlm\.server --model" | head -1 | sed -n 's/.*--model \([^ ]*\).*/\1/p')
      [ -n "$repo" ] && break
      sleep 1
    done
    if [ -z "$repo" ]; then echo "vision marked ON but no mlx_vlm server is running"; return; fi
    case "$repo" in
      *Huihui*abliterated*) label="UNCENSORED (abliterated)" ;;
      *Qwen3.8-27B-8bit)    label="STOCK (aligned)" ;;
      *)                    label="unknown" ;;
    esac
    printf "model : %s\n  repo: %s\n" "$label" "$repo"
    printf "  vision  : ON (mlx_vlm — images work)\n"
    printf "  %s\n" "$(./pin-model.sh status 2>/dev/null | head -1)"
    return
  fi
  raw=$(curl -s --max-time 5 http://127.0.0.1:8081/v1/models 2>/dev/null)
  if [ -z "$raw" ]; then echo "engine: not running  (make wake)"; return; fi
  repo=$(echo "$raw" | python3 -c "
import json,sys
d=json.load(sys.stdin)['data'][0]
print(d.get('x_mlx_dspark',{}).get('target') or d.get('id'))" 2>/dev/null)
  case "$repo" in
    *Huihui*abliterated*) label="UNCENSORED (abliterated)" ;;
    *mlx-community/Qwen3.8-27B-8bit) label="STOCK (aligned)" ;;
    *) label="unknown" ;;
  esac
  printf "model : %s\n  repo: %s\n" "$label" "$repo"
  printf "  thinking: %s\n" "$(./thinking.sh status 2>/dev/null | sed 's/^thinking: //')"
  printf "  vision  : %s\n" "$(./vision.sh status 2>/dev/null | sed 's/^vision: //')"
  printf "  %s\n" "$(./pin-model.sh status 2>/dev/null | head -1)"
}

# Switching must respect the current mode: in vision mode the engine is mlx_vlm, so
# running switch-model.sh would start mlx-dspark on top of it and give you two servers.
switch_to() {
  if [ -f logs/.vision ]; then
    ./vision.sh on "$1" >/dev/null 2>&1
    # Let the transient launcher leave the process table. While it is still there,
    # `ps` can match it instead of the real server and the label reads as garbage.
    for _ in $(seq 1 10); do
      [ "$(ps -Ao command | grep -cE "[m]lx_vlm\.server --model")" = "1" ] && break
      sleep 1
    done
    sleep 1
  else
    ./switch-model.sh "$1" >/dev/null 2>&1
  fi
  show
}

case "${1:-status}" in
  status|"")            show ;;
  uncensored|abliterated) switch_to uncensored ;;
  stock|aligned|censored) switch_to stock ;;
  *) echo "usage: $0 [status|uncensored|stock]"; exit 1 ;;
esac
