#!/bin/bash
# Toggle dsh's skill catalog.
#
# dsh injects a <system-reminder> listing EVERY skill in ~/.agents/skills as a user
# message placed AFTER your question. A prefix cache can only reuse tokens up to the
# first change, so each new question invalidates that trailing block and re-prefills
# it at ~400 tok/s. With 44 skills that block is ~12.9 KB / ~3300 tokens.
#
# Measured on this machine (simple question, warm engine):
#   skills on  : ~8.5s
#   skills off : ~1.5s
#
# This touches ~/.agents/skills (dsh only). Claude Code's ~/.claude/skills is separate
# and is NOT affected either way.
SKILLS="$HOME/.agents/skills"
OFF="$HOME/.agents/skills.disabled"

case "${1:-status}" in
  off)  [ -d "$SKILLS" ] && mv "$SKILLS" "$OFF" && echo "dsh skills OFF (fast)" || echo "already off" ;;
  on)   [ -d "$OFF" ] && mv "$OFF" "$SKILLS" && echo "dsh skills ON" || echo "already on" ;;
  list) ls -1 "$SKILLS" 2>/dev/null || ls -1 "$OFF" 2>/dev/null ;;
  status)
    if [ -d "$SKILLS" ]; then
      echo "dsh skills: ON  ($(ls -1 "$SKILLS" | wc -l | tr -d ' ') skills, ~$(du -sk "$SKILLS" | cut -f1) KB on disk)"
      echo "  each turn re-prefills the catalog -> ~8.5s per question"
    else
      echo "dsh skills: OFF -> ~1.5s per question"
    fi ;;
  *) echo "usage: $0 {on|off|list|status}"; exit 1 ;;
esac
