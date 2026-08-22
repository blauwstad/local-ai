#!/bin/bash
# Launch DeepSeek Harness against the LOCAL Qwen3.8-27B.
# Handles PATH, the key env var, and port collisions on :3080.
export PATH="/Users/vahdetd/.hermes/node/bin:$PATH"
export LOCAL_MLX_KEY=local     # engine is unauthenticated; dsh only requires the var to exist

PORT="${DSH_PORT:-3080}"

# dsh talks to the ENGINE directly (:8081). Docker is NOT required for dsh --
# the gateway (:8080) exists for containerized clients like Open WebUI.
need_engine() {
  if ! curl -s --max-time 3 http://127.0.0.1:8081/v1/models >/dev/null 2>&1; then
    echo "!! MLX engine :8081 is down. Start it:"
    echo "   make engine"
    echo "   (takes ~40s to load 29.5 GB)"
    exit 1
  fi
}

case "${1:-web}" in
  web)
    shift; need_engine
    holder=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | head -1)
    if [ -n "$holder" ]; then
      cmd=$(ps -p "$holder" -o comm= 2>/dev/null)
      echo "!! port $PORT is already in use by pid $holder ($cmd)"
      if curl -s --max-time 3 "http://127.0.0.1:$PORT" >/dev/null 2>&1; then
        echo "   It answers HTTP — a dsh web server is already running."
        echo "   Just open:  http://127.0.0.1:$PORT"
        echo
        echo "   To restart it instead:   $0 stop && $0 web"
        echo "   Or use another port:     DSH_PORT=3081 $0 web"
        exit 0
      fi
      echo "   It is NOT answering HTTP. Kill it with: kill $holder"
      exit 1
    fi
    exec dsh web --port "$PORT" "$@"
    ;;
  stop)
    holder=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | head -1)
    if [ -n "$holder" ]; then kill "$holder" && echo "stopped dsh on :$PORT (pid $holder)";
    else echo "nothing listening on :$PORT"; fi
    ;;
  ask)   shift; need_engine; exec dsh --profile headless "$*" ;;
  tui)   shift; need_engine; exec dsh --profile tui "$@" ;;
  *)     exec dsh "$@" ;;
esac
