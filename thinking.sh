#!/bin/bash
# Toggle the model's reasoning ("thinking") mode. Restarts the engine (~40s).
#
#   ./thinking.sh off            fastest; best for agent/tool loops
#   ./thinking.sh on [effort]    effort = low (default) | medium | high | xhigh
#   ./thinking.sh status
#
# MEASURED on this machine, via dsh, simple question, steady state:
#
#   off                ~9.4s
#   on low            ~10.0s    <- reasoning on, essentially free
#   on medium        ~572s      <- 9.5 MINUTES for "name a bird". Not a typo.
#
# Qwen3.8 reasons before it says anything, and dsh sends max_tokens=32768, so at
# medium+ the model can emit thousands of reasoning tokens at ~15-50 tok/s before the
# first visible word. That is what "it takes an hour to do one job" feels like.
# Raise the effort only for a genuinely hard one-off question, then put it back.
cd "$(dirname "$0")"

case "${1:-status}" in
  off)
    THINKING=off ./switch-model.sh "$(cat logs/last-model 2>/dev/null || echo uncensored)" ;;
  on)
    eff="${2:-low}"
    case "$eff" in low|medium|high|xhigh) ;; *) echo "effort must be low|medium|high|xhigh"; exit 1 ;; esac
    [ "$eff" != "low" ] && echo "!! effort=$eff measured at ~572s for a trivial question. Ctrl-C now if unintended."
    THINKING=on EFFORT="$eff" ./switch-model.sh "$(cat logs/last-model 2>/dev/null || echo uncensored)" ;;
  status)
    f=$(ps -Ao command | grep "[m]lx-dspark serve" | head -1)
    if [ -z "$f" ]; then echo "engine not running"; exit 0; fi
    if echo "$f" | grep -q -- "--no-thinking"; then
      echo "thinking: OFF  (~9.4s per question)"
    else
      e=$(echo "$f" | sed -n 's/.*--reasoning-effort[= ]\([a-z]*\).*/\1/p')
      [ -n "$e" ] || e="(unset)"
      echo "thinking: ON, effort=$e"
    fi ;;
  *) echo "usage: $0 {on [low|medium|high|xhigh]|off|status}"; exit 1 ;;
esac
