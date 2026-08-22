#!/bin/bash
# Start the local-AI stack (engine + router + watchdog + dsh).
cd "$(dirname "$0")"

echo "1/3  starting router :8090"
launchctl load ~/Library/LaunchAgents/com.vahdetd.mlx-router.plist 2>/dev/null
for i in $(seq 1 20); do curl -s --max-time 2 http://127.0.0.1:8090/healthz >/dev/null 2>&1 && break; sleep 1; done

echo "2/3  loading engine (${1:-$(cat logs/last-model 2>/dev/null || echo uncensored)}) — ~40s for 29.5 GB"
./switch-model.sh "${1:-$(cat logs/last-model 2>/dev/null || echo uncensored)}"

echo "3/3  starting engine watchdog"
launchctl load ~/Library/LaunchAgents/com.vahdetd.mlx-engine-watchdog.plist 2>/dev/null

echo
echo "up. start the UI with: ./dsh-local.sh web   (http://127.0.0.1:3080)"
