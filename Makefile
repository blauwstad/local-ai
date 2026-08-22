.PHONY: help start stop sleep wake engine engine-stop router router-stop up down bench bench-native logs status

help:
	@echo "make stop          - stop EVERYTHING and free the ~34 GB"
	@echo "make sleep         - free the ~34 GB but keep router+dsh up (reloads on next message)"
	@echo "make wake          - load the engine back now, without waiting for a message"
	@echo "make start         - bring the stack back up"
	@echo "make engine        - start native MLX engine (host, Metal/GPU)"
	@echo "make engine-stop   - stop it"
	@echo "make router        - start model router on :8090 (both models, swap on demand)"
	@echo "make router-stop   - stop it"
	@echo "make up            - [optional] dockerized gateway + Open WebUI (removed by default)"
	@echo "make down          - [optional] stop those containers"
	@echo "make bench         - benchmark THROUGH the container gateway"
	@echo "make bench-native  - benchmark direct to host engine (no docker)"
	@echo "make status        - show what's running"

stop:
	@./stop.sh

sleep:
	@./sleep.sh

wake:
	@./wake.sh

start:
	@./start.sh

engine:
	@mkdir -p logs
	@python3 -c "import subprocess,os;p=subprocess.Popen(['./engine.sh'],stdout=open('logs/engine.log','w'),stderr=subprocess.STDOUT,start_new_session=True);open('logs/engine.pid','w').write(str(p.pid));print('engine pid',p.pid)"

engine-stop:
	@kill $$(cat logs/engine.pid) 2>/dev/null || true; pkill -f mlx-dspark || true; echo stopped

router:
	@mkdir -p logs
	@pgrep -f "python router.py" >/dev/null 2>&1 && echo "router already running" || \
	  { nohup ./router.sh > logs/router.log 2>&1 & echo "router starting on :8090"; }
	@for i in 1 2 3 4 5 6 7 8 9 10; do curl -s --max-time 2 http://127.0.0.1:8090/healthz >/dev/null 2>&1 && { echo "router up"; break; }; sleep 1; done

router-stop:
	@pkill -f "python router.py" 2>/dev/null || true; echo "router stopped"

up:
	docker compose up -d gateway webui

down:
	docker compose down

bench:
	docker compose --profile bench run --rm bench --trials 3 --label "docker-gateway"

bench-native:
	@.venv/bin/python bench/benchmark.py --base-url http://127.0.0.1:8081/v1 \
	  --model $${MODEL_NAME:-Qwen3.8-27B-8bit} --trials 3 --out results/bench.json --label native

status:
	@echo "--- engine ---"; curl -s --max-time 3 http://127.0.0.1:8081/v1/models | head -c 300 || echo "engine down"
	@echo; echo "--- router ---"; curl -s --max-time 3 http://127.0.0.1:8090/v1/models | python3 -c "import json,sys;[print('  ',m['display_name']) for m in json.load(sys.stdin)['data']]" 2>/dev/null || echo "router down"
	@echo "--- engine watchdog ---"; tail -1 logs/engine-watchdog.log 2>/dev/null || echo "no log"
	@echo "--- containers (optional layer) ---"; docker compose ps 2>/dev/null || echo "not in use — host-only stack"
	@echo "--- downloads ---"; tail -2 logs/download.log
