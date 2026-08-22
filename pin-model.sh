#!/bin/bash
# Control whether CLIENTS may switch the loaded model.
#
#   ./pin-model.sh on     (default) router ignores the `model` field; nothing but
#                         ./switch-model.sh can change which weights are loaded
#   ./pin-model.sh off    clients may request either build and the router swaps
#   ./pin-model.sh status
#
# Pinned is the default because dsh writes its picker selection into
# ~/.dsh/settings.yaml: one stray click made every request name the stock model, the
# router swapped on demand, and the "uncensored" setup served aligned weights without
# saying so. Pinning puts model choice in exactly one place.
cd "$(dirname "$0")"
mkdir -p logs
M=logs/.unpinned

case "${1:-status}" in
  on)  rm -f "$M";  echo "model PINNED — clients cannot switch; use ./switch-model.sh" ;;
  off) touch "$M";  echo "model UNPINNED — clients may swap the engine on demand" ;;
  status)
    if [ -f "$M" ]; then echo "model: UNPINNED (clients may swap)"
    else echo "model: PINNED (only ./switch-model.sh changes it)"; fi
    printf "  engine has: %s\n" "$(./switch-model.sh status 2>/dev/null | sed 's/^loaded: //')" ;;
  *) echo "usage: $0 {on|off|status}"; exit 1 ;;
esac
