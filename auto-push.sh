#!/bin/bash
# Watch this directory and push changes to blauwstad/local-ai automatically.
#
# Polls instead of using fswatch so there is no extra dependency; `git status` on a
# 36-file repo is far cheaper than the interval it runs at.
#
# DEBOUNCE: a change must still be there on the NEXT poll before anything is pushed.
# Without that, saving a file mid-edit would commit a half-written script.
#
# Disable temporarily:  touch /Users/vahdetd/local-ai/.autopush-off
# Stop entirely:        launchctl unload ~/Library/LaunchAgents/com.vahdetd.local-ai-autopush.plist
cd "$(dirname "$0")"
LOG=logs/auto-push.log
INTERVAL="${AUTOPUSH_INTERVAL:-120}"
last=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
mkdir -p logs
log "auto-push started (poll ${INTERVAL}s, debounced)"

while true; do
  sleep "$INTERVAL"
  [ -f .autopush-off ] && continue

  # never touch a repo that is mid-operation
  if [ -f .git/index.lock ] || [ -f .git/MERGE_HEAD ] || [ -f .git/rebase-merge/interactive ]; then
    log "git busy — skipping"; continue
  fi

  cur=$(git status --porcelain 2>/dev/null)
  [ -z "$cur" ] && { last=""; continue; }

  # debounce: only act once the same change set has persisted for two polls
  if [ "$cur" != "$last" ]; then
    last="$cur"
    continue
  fi

  n=$(printf '%s\n' "$cur" | wc -l | tr -d ' ')
  files=$(printf '%s\n' "$cur" | awk '{print $2}' | head -3 | paste -sd', ' -)
  msg="auto: $n file(s) changed — $files"
  if out=$(./push.sh "$msg" 2>&1); then
    log "$out"
  else
    log "PUSH FAILED: $out"
  fi
  last=""
done
