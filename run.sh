#!/bin/bash
# One-shot bring-up: engine (host) + stack (docker), then smoke test.
set -e
cd "$(dirname "$0")"
./engine.sh &
echo "waiting for engine..."
for i in $(seq 1 90); do
  curl -s --max-time 2 http://127.0.0.1:8081/v1/models >/dev/null 2>&1 && break
  sleep 2
done
docker compose up -d gateway webui
echo "engine  : http://127.0.0.1:8081/v1  (native, Metal)"
echo "gateway : http://127.0.0.1:8080/v1  (dockerized)"
echo "web UI  : http://127.0.0.1:3000"
