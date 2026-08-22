#!/usr/bin/env python3
"""
Model router for the single-model MLX engine.

mlx-dspark serves exactly ONE model: it ignores the `model` field in a request and
answers with whatever is resident. Both builds are ~28 GB, so they cannot be
co-resident in 64 GB. That makes a normal model dropdown impossible -- a client can
only ever discover the one loaded model.

This router sits in front of the engine and fixes that:
  * GET  /v1/models            -> advertises BOTH builds, always
  * POST /v1/chat/completions  -> if the requested build is not resident, swap the
                                  engine (switch-model.sh), wait, then forward
  * anything else              -> transparent proxy (SSE streaming preserved)

A swap costs ~40-60s (29.5 GB reload). Same-model requests just proxy through.
"""
import json, os, subprocess, threading, time
import anyio
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse, JSONResponse, PlainTextResponse
from starlette.concurrency import run_in_threadpool

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.environ.get("ENGINE_URL", "http://127.0.0.1:8081")
PORT = int(os.environ.get("ROUTER_PORT", "8090"))
# Loopback only. The router is unauthenticated and can restart the engine, so binding
# 0.0.0.0 (the old Docker-era default) exposed both to every host on the LAN.
BIND = os.environ.get("ROUTER_BIND", "127.0.0.1")

# advertised id -> (switch-model.sh argument, HF repo the engine reports as target)
MODELS = {
    "Qwen3.8-27B-8bit": ("stock", "mlx-community/Qwen3.8-27B-8bit"),
    "Huihui-Qwen3.8-27B-abliterated-mlx-8Bit": (
        "uncensored", "ailexleon/Huihui-Qwen3.8-27B-abliterated-mlx-8Bit"),
}
REPO_TO_ID = {repo: mid for mid, (_, repo) in MODELS.items()}
DEFAULT_VISION_ID = "Huihui-Qwen3.8-27B-abliterated-mlx-8Bit"

app = FastAPI()

# Concurrency model.
#
# Two clients (Open WebUI and dsh) each have their OWN selected model, so they will
# happily demand different builds seconds apart. A plain "lock around the swap" is not
# enough: client A can start a swap while client B's request is mid-flight against the
# engine that is being killed, which surfaces as "Server disconnected".
#
# So: requests for the resident model run concurrently; a swap waits for in-flight
# requests to drain, blocks new ones, and everyone re-checks afterwards.
_cond = threading.Condition()
_swapping = False       # a swap is running right now
_inflight = 0           # forwarded requests currently talking to the engine


def resident_id():
    """Which model is loaded right now, or None if the engine is down."""
    try:
        r = httpx.get(f"{ENGINE}/v1/models", timeout=5)
        repo = r.json()["data"][0]["x_mlx_dspark"]["target"]
        return REPO_TO_ID.get(repo, repo)
    except Exception:
        return None


SWAP_MARKER = os.path.join(HERE, "logs", ".swapping")


def _do_swap(model_id):
    """Run the actual engine swap. Caller must hold the _swapping flag."""
    # The watchdog also restores a dead engine. During a swap the engine is
    # deliberately down for 15-85s, which must not look like a crash to it --
    # two engines racing for :8081 is worse than a slow swap.
    try:
        open(SWAP_MARKER, "w").write(model_id)
    except Exception:
        pass
    try:
        arg = MODELS[model_id][0]
        print(f"[router] swapping engine -> {model_id} ({arg})", flush=True)
        p = subprocess.run([os.path.join(HERE, "switch-model.sh"), arg],
                           cwd=HERE, timeout=900,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(f"[router] switch-model.sh rc={p.returncode}: "
              f"{p.stdout.decode(errors='replace')[-300:]}", flush=True)
        for _ in range(180):
            if resident_id() == model_id:
                print(f"[router] resident: {model_id}", flush=True)
                return model_id
            time.sleep(2)
        print(f"[router] WARNING: swap to {model_id} did not settle", flush=True)
        return resident_id()
    finally:
        try:
            os.remove(SWAP_MARKER)
        except Exception:
            pass


VISION_MARKER = os.path.join(HERE, "logs", ".vision")
# Pinned mode (DEFAULT). The router ignores the `model` field completely and never
# swaps the engine, so no client can decide which weights are loaded.
#
# Why: dsh persists its picker selection into ~/.dsh/settings.yaml, so a stray UI click
# silently made every request name the stock model -- the router obediently swapped,
# and the "uncensored" setup quietly served aligned weights for a while. Model choice
# now belongs to exactly one place: ./switch-model.sh.
#
# `./pin-model.sh off` restores client-driven swapping.
UNPIN_MARKER = os.path.join(HERE, "logs", ".unpinned")


def pinned():
    return not os.path.exists(UNPIN_MARKER)


def resident_repo():
    """The HF repo the engine actually has loaded (or the last one we selected)."""
    try:
        r = httpx.get(f"{ENGINE}/v1/models", timeout=5)
        d = r.json()["data"][0]
        return d.get("x_mlx_dspark", {}).get("target") or d.get("id")
    except Exception:
        try:
            arg = open(os.path.join(HERE, "logs", "last-model")).read().strip()
        except Exception:
            arg = "uncensored"
        for mid, (a, repo) in MODELS.items():
            if a == arg:
                return repo
        return MODELS[DEFAULT_VISION_ID][1]


def vision_mode():
    """True when mlx_vlm is serving :8081 instead of mlx-dspark (see vision.sh).
    In that mode the engine is a different program with a different /v1/models
    payload, and swapping models under it would kill the VLM."""
    return os.path.exists(VISION_MARKER)


def acquire(model_id):
    """Ensure `model_id` is resident, then register an in-flight request.

    Every successful call MUST be paired with release()."""
    global _swapping, _inflight
    while True:
        with _cond:
            if _swapping:
                _cond.wait(timeout=5)
                continue
            if model_id not in MODELS or resident_id() == model_id:
                _inflight += 1
                return resident_id()
            if _inflight > 0:               # let existing requests finish first
                _cond.wait(timeout=5)
                continue
            _swapping = True                # claim the swap
        try:
            got = _do_swap(model_id)
        finally:
            with _cond:
                _swapping = False
                _cond.notify_all()
        with _cond:
            if got == model_id:
                _inflight += 1
            return got


def release():
    global _inflight
    with _cond:
        _inflight = max(0, _inflight - 1)
        _cond.notify_all()


@app.get("/healthz")
def healthz():
    return PlainTextResponse("router ok\n")


@app.get("/v1/models")
def list_models():
    """Always advertise both builds so the dropdown offers a real choice."""
    live = None if vision_mode() else resident_id()
    if pinned():
        repo = resident_repo()
        mid = REPO_TO_ID.get(repo, repo)
        return {"object": "list", "data": [{
            "id": mid, "object": "model", "created": 0, "owned_by": "mlx-dspark",
            "display_name": f"{mid} (pinned — change with ./switch-model.sh)",
            "x_router": {"resident": True, "repo": repo, "pinned": True}}]}
    return {
        "object": "list",
        "data": [
            {
                "id": mid,
                "object": "model",
                "created": 0,
                "owned_by": "mlx-dspark",
                "display_name": mid + (" (loaded)" if mid == live else " (swaps on use)"),
                "x_router": {"resident": mid == live, "repo": repo},
            }
            for mid, (_, repo) in MODELS.items()
        ],
    }


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"])
async def proxy(path: str, request: Request):
    body = await request.body()

    wanted = None
    if vision_mode():
        # mlx_vlm resolves the `model` field as a HuggingFace repo id on every request
        # (mlx-dspark ignores it entirely). dsh sends the short id from its settings,
        # e.g. "Qwen3.8-27B-8bit", which mlx_vlm tries to FETCH from the Hub and 401s
        # on. Rewrite short ids to the full repo path so clients need no changes.
        if body:
            try:
                j = json.loads(body)
                mid = j.get("model")
                if not mid or "/" not in mid:
                    j["model"] = resident_repo()
                    body = json.dumps(j).encode()
            except Exception:
                pass
    elif pinned():
        wanted = None        # model choice is not the client's to make
    elif body:
        try:
            wanted = json.loads(body).get("model")
        except Exception:
            wanted = None

    acquired = False
    if wanted in MODELS:
        got = await run_in_threadpool(acquire, wanted)
        if got != wanted:
            return JSONResponse(
                {"error": {"message": f"could not load {wanted}; resident={got}",
                           "type": "router_swap_failed"}}, status_code=503)
        acquired = True

    # --- temporary instrumentation (ROUTER_TRACE=1) ---
    trace = os.environ.get("ROUTER_TRACE") == "1"
    t_start = time.time()
    if trace and body:
        try:
            j = json.loads(body)
            msgs = j.get("messages", [])
            chars = sum(len(str(m.get("content", ""))) for m in msgs)
            print(f"[trace] MODEL={j.get('model')!r} msgs={len(msgs)}", flush=True)
            print(f"[trace] IN  msgs={len(msgs)} chars={chars} (~{chars//4} tok) "
                  f"stream={j.get('stream')} max_tokens={j.get('max_tokens')}", flush=True)
            if os.environ.get("ROUTER_TRACE_SHAPE") == "1":
                shape = " | ".join(f"{i}:{m.get('role')}={len(str(m.get('content','')))}c"
                                   for i, m in enumerate(msgs))
                print(f"[trace]   shape {shape}", flush=True)
            if os.environ.get("ROUTER_TRACE_PROMPT") == "1":
                for i, m in enumerate(msgs):
                    c = str(m.get("content", ""))
                    print(f"[trace]   msg{i} role={m.get('role')} head={c[:400]!r}", flush=True)
                    print(f"[trace]   msg{i} tail={c[-200:]!r}", flush=True)
        except Exception:
            pass

    url = f"{ENGINE}/{path}"
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ("host", "content-length", "accept-encoding")}

    # A freshly-swapped engine binds its port slightly before it will answer, so a
    # single attempt here shows up to the user as a spurious 502 right after a switch.
    client = resp = None
    last_err = None
    for attempt in range(4):
        client = httpx.AsyncClient(timeout=httpx.Timeout(None, connect=30))
        try:
            req = client.build_request(request.method, url, content=body,
                                       headers=headers, params=request.query_params)
            resp = await client.send(req, stream=True)
            break
        except Exception as e:
            last_err = e
            await client.aclose()
            client = resp = None
            if attempt < 3:
                await anyio.sleep(2 * (attempt + 1))

    if resp is None:
        if acquired:
            release()
        return JSONResponse({"error": {"message": f"engine unreachable: {last_err}",
                                       "type": "engine_down"}}, status_code=502)

    async def stream():
        n = 0
        try:
            async for chunk in resp.aiter_raw():
                n += len(chunk)
                yield chunk
        finally:
            if trace:
                print(f"[trace] OUT {time.time()-t_start:6.2f}s bytes={n}", flush=True)
            await resp.aclose()
            await client.aclose()
            if acquired:
                release()

    passthru = {k: v for k, v in resp.headers.items()
                if k.lower() not in ("content-length", "content-encoding", "transfer-encoding")}
    return StreamingResponse(stream(), status_code=resp.status_code,
                             headers=passthru,
                             media_type=resp.headers.get("content-type"))


if __name__ == "__main__":
    import uvicorn
    # streaming responses otherwise hold graceful shutdown open indefinitely,
    # which makes launchd's KeepAlive restart never happen.
    uvicorn.run(app, host=BIND, port=PORT, log_level="info",
                timeout_graceful_shutdown=5)
