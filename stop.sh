#!/bin/bash
# Stop the whole local-AI stack and free the ~34 GB the engine wires.
#
# Order matters. The router and the watchdog are LaunchAgents with KeepAlive, so
# killing the engine on its own achieves nothing: the watchdog notices within ~90s
# and loads it straight back. The supervisors have to go first.
cd "$(dirname "$0")"

echo "1/4  stopping engine watchdog (else it reloads the engine)"
launchctl unload ~/Library/LaunchAgents/com.vahdetd.mlx-engine-watchdog.plist 2>/dev/null \
  && echo "     watchdog stopped" || echo "     watchdog was not loaded"

echo "2/4  stopping router :8090"
launchctl unload ~/Library/LaunchAgents/com.vahdetd.mlx-router.plist 2>/dev/null \
  && echo "     router stopped" || echo "     router was not loaded"
pkill -f "python router.py" 2>/dev/null

echo "3/4  stopping dsh :3080"
./dsh-local.sh stop 2>/dev/null || true

echo "4/4  stopping engine :8081  (this is the 34 GB)"
kill "$(cat logs/engine.pid 2>/dev/null)" 2>/dev/null || true
pkill -f "mlx-dspark serve" 2>/dev/null || true

for i in $(seq 1 20); do
  pgrep -f "mlx-dspark serve" >/dev/null 2>&1 || break
  sleep 1
done
pgrep -f "mlx-dspark serve" >/dev/null 2>&1 && { echo "     engine still up, forcing"; pkill -9 -f "mlx-dspark serve"; sleep 2; }

echo
echo "stopped. free memory:"
vm_stat | awk '/page size of/{ps=$8+0} /Pages free/{printf "  %.1f GB\n", $3*ps/1073741824}'
echo "restart with: make start"
