#!/bin/bash
# Native MLX inference engine — runs on the HOST for Metal/GPU access.
# Docker on macOS cannot reach the Apple GPU, so this deliberately stays outside
# the container. The compose stack proxies to it via host.docker.internal:8081.
set -euo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate

MODEL="${MODEL:-mlx-community/Qwen3.8-27B-8bit}"
CTX="${CTX:-32768}"       # 32K default: ~36 GB resident. Raise toward 262144 as needed.
KV_BITS="${KV_BITS:-0}"   # 0=bf16 KV (lossless). Set 8 to ~halve KV at long context.
PORT="${PORT:-8081}"
# Thinking control. Qwen3.8 reasons by default, which costs many tokens BEFORE
# the first visible word — the main reason agent turns feel "hung".
#   THINKING=off   -> --no-thinking        (fastest; best for agent/tool loops)
#   EFFORT=low|medium|high|xhigh
THINKING="${THINKING:-on}"
EFFORT="${EFFORT:-low}"
EXTRA=()
if [ "$THINKING" = "off" ]; then EXTRA+=(--no-thinking); else EXTRA+=(--reasoning-effort "$EFFORT"); fi

# DRAFTER override: auto-resolve works for mlx-community repo names, but a renamed
# fork (e.g. the abliterated build) won't match the registry, so pass it explicitly.
if [ -n "${DRAFTER:-}" ]; then EXTRA+=(--drafter "$DRAFTER"); fi

# Prefix-cache LRU depth. dsh fires TWO requests per turn -- the agent call (~4.4k
# tokens, growing) and a small side call (~120 tok). With a single slot they evict each
# other, so every other turn is a full cold prefill: measured 35s / 11s / 39s / 11s
# alternating. A couple of slots keeps both resident.
# Keep this SMALL: cached KV is wired memory and does not page out.
SLOTS="${PREFIX_CACHE_SLOTS:-4}"

mkdir -p logs
echo "engine: $MODEL  ctx=$CTX  kv-bits=$KV_BITS  slots=$SLOTS  port=$PORT"

# Bind LOOPBACK ONLY. This used to be --host 0.0.0.0 because the Docker VM could not
# reach 127.0.0.1 -- but Docker is gone, and 0.0.0.0 published an unauthenticated LLM
# to the whole local network (verified: it answered on the LAN address). Anyone on the
# same wifi could use the model or thrash it by alternating model requests.
# Set BIND=0.0.0.0 only if you deliberately restore the container stack.
# --mode auto resolves the measured-best drafter (DFlash 2 for Qwen3.8-27B).
# --wired-limit raises the Metal wired-memory cap so a 29.5 GB model stays resident.
exec mlx-dspark serve \
  --model "$MODEL" \
  --mode "${MODE:-auto}" \
  --context-window "$CTX" \
  --prefix-cache-slots "$SLOTS" \
  --kv-bits "$KV_BITS" \
  --wired-limit \
  "${EXTRA[@]}" \
  --host "${BIND:-127.0.0.1}" \
  --port "$PORT"
