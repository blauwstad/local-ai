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

case "${1:-status}" in
  status|"")            show ;;
  uncensored|abliterated) ./switch-model.sh uncensored >/dev/null 2>&1; show ;;
  stock|aligned|censored) ./switch-model.sh stock      >/dev/null 2>&1; show ;;
  *) echo "usage: $0 [status|uncensored|stock]"; exit 1 ;;
esac
