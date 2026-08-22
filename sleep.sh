#!/bin/bash
# Unload just the ENGINE and free its ~34 GB, leaving the router and dsh running.
#
# Difference from stop.sh: the supervisors stay up, so the stack is still "on" --
# the next message through the router cold-loads the model on demand (~40-85s) and
# then runs at full speed. Use this between sessions; use `make stop` to shut down.
cd "$(dirname "$0")"

# The watchdog's whole job is to notice a dead engine and reload it. Tell it this one
# was deliberate. switch-model.sh clears this marker, so the watchdog resumes guarding
# the moment a model is loaded again -- by the router, by `make wake`, or by hand.
mkdir -p logs
touch logs/.idle

echo "unloading engine (router and dsh stay up)"
kill "$(cat logs/engine.pid 2>/dev/null)" 2>/dev/null || true
pkill -f "mlx-dspark serve" 2>/dev/null || true
for i in $(seq 1 20); do
  pgrep -f "mlx-dspark serve" >/dev/null 2>&1 || break
  sleep 1
done
pgrep -f "mlx-dspark serve" >/dev/null 2>&1 && { pkill -9 -f "mlx-dspark serve"; sleep 2; }

sleep 2
echo
printf "  engine : %s\n" "$(pgrep -f 'mlx-dspark serve' >/dev/null && echo 'still up' || echo 'unloaded')"
printf "  router : %s\n" "$(curl -s --max-time 3 http://127.0.0.1:8090/healthz >/dev/null 2>&1 && echo 'up (:8090)' || echo 'down')"
printf "  dsh    : %s\n" "$(curl -s --max-time 3 -o /dev/null http://127.0.0.1:3080 2>/dev/null && echo 'up (:3080)' || echo 'down')"
vm_stat | awk '/page size of/{ps=$8+0} /Pages free/{printf "  free   : %.1f GB\n", $3*ps/1073741824}'
echo
echo "next message reloads the model automatically (~40-85s), or run: make wake"
