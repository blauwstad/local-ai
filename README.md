# Local AI — Qwen3.8-27B (MLX 8-bit) + DFlash 2 speculative decoding

Runs on Apple Silicon. Everything is a native host process — see
[The Docker layer was removed](#the-docker-layer-was-removed).

## Why the model runs natively

MLX computes on **Metal**, Apple's GPU API. Docker on macOS is a **Linux VM**, and
there is no mechanism to pass the Apple GPU into it — unlike NVIDIA on Linux, there
is no `--gpus all` equivalent. An MLX process inside the VM falls back to CPU and
loses roughly 90% of its throughput. So the engine was always outside the container.

The rest (Open WebUI, nginx, the Colima VM) has since been removed too: dsh is a
native client, so nothing needed a container at all.

```
┌ HOST (native, Metal, 18-core) ──────────────────────┐
│  dsh :3080  ──►  router :8090  ──►  engine :8081    │
│                  both builds        Qwen3.8-27B-8bit│
│                  swap on demand     + DFlash 2      │
└─────────────────────────────────────────────────────┘
```

`docker-compose.yml` and `bench/` are kept for the optional browser UI and for
benchmarking through a container hop; neither runs by default.

## Quick start

```bash
make engine     # native engine on :8081  (loads ~29.5 GB, first run calibrates ~5s)
make router     # model router on :8090   (both builds, swaps on demand)
./dsh-local.sh web   # DeepSeek Harness on :3080
make status
```

The router and the engine-watchdog run at login via LaunchAgents. The engine itself
is not a LaunchAgent -- the watchdog notices it is down and restores your last model
(~90s after login), so in practice you only run `./dsh-local.sh web`.

## Configuration

`engine.sh` reads env vars:

| var | default | notes |
|---|---|---|
| `MODEL` | `mlx-community/Qwen3.8-27B-8bit` | any HF repo or local path |
| `CTX` | `32768` | raise toward `262144` (native max) as RAM allows |
| `KV_BITS` | `0` | `0`=bf16 KV; `8` roughly halves KV at long context |
| `MODE` | `auto` | resolves DFlash 2 for this target automatically |

Uncensored swap (same size, same speed):
```bash
MODEL=ailexleon/Huihui-Qwen3.8-27B-abliterated-mlx-8Bit \
  DRAFTER=incoai/Qwen3.8-27B-DFlash2 make engine
```

## Switching models from a UI

`mlx-dspark` serves exactly ONE model: it ignores the `model` field in a request and
answers with whatever is resident. Both builds are ~28 GB, so they cannot both be
loaded in 64 GB. A client asking "what models do you have?" therefore only ever sees
one -- no dropdown is possible, and pointing a client straight at :8081 means the
picker silently lies about which build answered.

`router.py` (:8090) fixes that. It advertises BOTH builds and swaps the engine when
you pick the other one.

```
dsh :3080 ──► router :8090 ──► engine :8081
```

| | |
|---|---|
| same model | ~0.4 s (plain proxy) |
| swap, warm page cache | ~15 s |
| swap, cold | ~85 s |

The first message after switching stalls while 29.5 GB reloads, then runs at full speed.

**One engine, one client.** If you ever add a second client, note that each one
remembers its own selected model -- two clients that disagree will swap the engine back
and forth and every message pays the reload. The router serializes this (requests drain
before a swap, so nobody gets a half-killed engine) but it cannot make it fast.

```bash
make router        # start it (also runs at login via LaunchAgent)
make router-stop
```

## The Docker layer was removed

Open WebUI, the nginx gateway and the Colima VM are gone. dsh is a native client and
talks to the router directly, so none of that was load-bearing -- it was only ever
there to serve the browser UI.

It was also actively harmful. The engine wires ~34 GB (`--wired-limit`, so it cannot
be paged out). With ~20 GB of other apps live on a 64 GB machine, macOS reclaimed
memory from the biggest evictable process -- the Colima VM -- and killed it. That
failed in two confusing ways: sometimes the VM survived but its host port-forwards
died (`colima list` still said `Running` while :3000 and docker.sock were dead), and
sometimes the whole VM was killed (`Stopped`). Either way the browser UI showed
"load failed" or "500: Internal Error", while the containers were perfectly healthy
*inside* the VM the whole time.

Measured, dropping it:

| | before | after |
|---|---|---|
| free RAM | ~0.9 GB | **6.9-10 GB** |
| swap used | 4.4 GB | **1.8 GB** |
| VM killed | every ~4 min | **n/a** |

Bringing it back if you ever want the browser UI: `colima start && make up`, then set
Open WebUI's base URL to the gateway. The `webui-data` volume was NOT deleted -- your
chat history is still in the VM's disk image.

## Starting and stopping

The engine wires ~34 GB, so freeing it matters. Two levels:

```bash
make sleep    # unload the engine, keep router + dsh up   -> ~32 GB free
make wake     # load it back now (or just send a message)
make stop     # shut everything down                      -> ~41 GB free
make start    # bring it all back
```

**`make sleep` is the one you want between sessions.** The stack stays "on": the next
message through the router cold-loads your last model (~20-30s warm, up to 85s cold)
and then runs at full speed. `make wake` does the same without waiting for a message.

**Do not just kill the engine.** The router and watchdog are LaunchAgents with
`KeepAlive`, so the pieces defend themselves:

| naive attempt | what actually happens |
|---|---|
| `make engine-stop` | watchdog reloads all 29.5 GB within ~90s |
| `pkill -f router.py` | launchd restarts it in ~4s |

`stop.sh` unwinds them in the right order (watchdog, router, dsh, engine) -- killing
the engine before its supervisors achieves nothing. Note `make stop` also unloads the
LaunchAgents, so the stack will not return at next login until `make start`.

`logs/.idle` is how `make sleep` tells the watchdog "this one was deliberate".
`switch-model.sh` clears it, so guard duty resumes the instant a model is loaded --
by the router, by `make wake`, or by hand.

Measured:

| state | free RAM |
|---|---|
| running | ~3 GB |
| `make sleep` | **~32 GB** |
| `make stop` | **~41 GB** |

## The engine watchdog

The engine is the one piece that still needs watching. If macOS kills it, the router
would cold-load it on the next request -- a 60-85s stall the client reports as a bare
error. `engine-watchdog.sh` (LaunchAgent, 30s poll) restores it in the background
instead, using the last model you selected (`logs/last-model`).

It stands down while `logs/.swapping` exists, so it never races the router for :8081
during a deliberate model swap.

```bash
touch .watchdog-off   # pause it
rm .watchdog-off      # resume
tail -f logs/engine-watchdog.log
```

A related trap, now fixed: `switch-model.sh` used to start the engine as a plain
background job, which made it a child of whatever called it. When launchd restarted
the router, the process group died and took the 29.5 GB engine with it. It now
detaches into its own session (`start_new_session`); macOS has no `setsid`.

## Thinking (reasoning) mode

```bash
./thinking.sh status
./thinking.sh on [low|medium|high|xhigh]   # default low
./thinking.sh off
```

Measured via dsh, simple question, steady state:

| setting | per question |
|---|---|
| off | ~9.4s |
| **on, effort=low** | **~10.0s** -- reasoning on, essentially free |
| on, effort=medium | **~572s** -- 9.5 minutes for "name a bird" |

Qwen3.8 reasons before it emits anything visible, and dsh sends `max_tokens=32768`, so
at medium and above the model can produce thousands of reasoning tokens at ~15-50
tok/s before the first word of the answer. That is what "it takes an hour to do one
job" actually feels like. `low` is the setting worth running; raise it only for a
genuinely hard one-off, then put it back.

### Never run two engines

`switch-model.sh` takes an atomic lock (`logs/.switch.lock`, via `mkdir`) and sets
`logs/.swapping`. Without the lock, a manual switch races the engine watchdog: the
watchdog sees :8081 dead mid-switch, starts its OWN engine from `logs/last-model`, and
two 30 GB engines then fight for the port, the GPU and RAM. This was observed live --
one engine on `--reasoning-effort medium` and a second on `--no-thinking` -- and it
silently corrupts any benchmark running at the time.

A plain marker file is not enough: two concurrent runs each delete the other's marker
on exit. Check with:

```bash
pgrep -f "mlx-dspark serve" | wc -l    # must be 1
```

## Images, documents and OCR

### Why images "did not work"

The model is multimodal -- the 8-bit build carries **333 `vision_tower` tensors**.
The blocker was the serving layer: `mlx-dspark serve` accepts OpenAI `image_url`
parts, returns **HTTP 200**, and silently discards the image. The model then answers
"there's no image attached", which looks like a model limitation and is not one.

### vision.sh -- the 27B model with working eyes

```bash
./vision.sh on      # mlx_vlm serves the SAME weights on :8081; images work
./vision.sh off     # back to mlx-dspark (faster text, images ignored again)
```

A swap, not a second service: the 27B VLM wants the same ~30 GB as the text engine.
Verified end to end -- it read a test image as *"a red rectangle containing the blue
word HELLO"*, both directly and through the router.

Two gotchas handled in code:
- `mlx_vlm` resolves the `model` field as a **HuggingFace repo id on every request**
  (mlx-dspark ignores it). dsh sends a short id, which mlx_vlm tries to FETCH and 401s
  on -- so the router rewrites short ids to full repo paths while vision mode is on.
- The router and watchdog stand down on `logs/.vision`, or they would swap the VLM out
  from under you.

Cost: no DFlash speculative decoding in vision mode, so text is slower.

### ocr.sh -- Baidu Unlimited-OCR, Apple Silicon build

```bash
./ocr.sh image <file.png>     # layout + <table> HTML + <|det|> bounding boxes
./ocr.sh text  <file.png>     # plain text, tables as "a | b | c"
./ocr.sh pdf   <file.pdf> [outdir]
```

`mlx-community/Unlimited-OCR-8bit`, ~3.9 GB. Small enough to run **alongside** the
text engine rather than swapping. ~3s per page including model load. On a test
invoice it reconstructed the full table with every figure correct.

Two hard-won details:

- **It is size-sensitive.** 1000x620 reads perfectly; the same page at 1389x862 or
  2778x1723 degenerates into `10. 10. 10. ...` with no real text. `ocr.sh` downscales
  anything wider than `OCR_WIDTH` (default 1000) first. Without that, `ocr.sh pdf`
  returns confident garbage.
- **Not served over HTTP.** mlx_vlm's OpenAI server fails on this model with
  `There is no Stream(gpu, 2) in current thread` (an MLX threading bug, reproducible
  with the text engine both running and stopped). `mlx_vlm.generate` works, so ocr.sh
  shells out per call.

Also note the checkpoint sometimes prepends a junk first line (a stray date, or
`1. 2. 3. ...`); `ocr.sh text` filters those.

### Other document formats

No LLM ingests PDF/Excel/Word natively -- they are containers that must become text
or images first. All the tools are already installed:

```bash
pdftotext report.pdf report.txt                  # text-layer PDF -> text
./ocr.sh pdf scan.pdf                            # scanned PDF -> OCR
pandoc doc.docx -o doc.md                        # Word -> markdown
.venv/bin/pip install pandas openpyxl            # once
python3 -c "import pandas as pd; pd.read_excel('b.xlsx').to_csv('b.csv',index=False)"
```

Once it is `.txt`/`.md`/`.csv`, dsh's `read` tool handles it normally. For
spreadsheets CSV is usually *better* than the original -- the formatting noise is gone.

## Internet access

dsh ships web tooling, and the two halves have very different requirements:

| tool | works? | needs |
|---|---|---|
| `web_fetch` (fetch a URL) | **yes, now** | nothing -- verified against example.com |
| `web_search` (search the web) | no | `DEEPSEEK_API_KEY` -- provider is `deepseek-official`, i.e. **cloud** |

So the setup can read any page you point it at, entirely locally. Actual search would
send your queries to DeepSeek's servers, which is at odds with the rest of this stack.
A local alternative would be a self-hosted SearXNG instance behind a custom provider.

## Version control

Pushed to **blauwstad/local-ai** (private).

```bash
./push.sh "what changed"     # manual
```

`.venv/` (594 MB), `logs/` and `results/` are gitignored -- **logs can contain prompt
text and conversation content**, so they are never committed. `push.sh` refuses to
push if a token-shaped string shows up in the staged diff.

### Automatic pushing

`auto-push.sh` runs as a LaunchAgent and pushes changes made outside any assistant
session -- your own edits included.

- Polls every 120s (`git status` on 36 files is cheaper than the interval; no fswatch
  dependency needed).
- **Debounced**: a change must survive two consecutive polls before it is committed,
  so saving a file mid-edit does not commit a half-written script.
- Skips while git is mid-operation (`index.lock`, `MERGE_HEAD`, interactive rebase).

```bash
touch .autopush-off     # pause it
rm .autopush-off        # resume
tail -f logs/auto-push.log
launchctl unload ~/Library/LaunchAgents/com.vahdetd.local-ai-autopush.plist   # stop for good
```

Commits it makes are prefixed `auto:` so they are easy to tell from deliberate ones.

## Network exposure

Everything binds **loopback only**. Nothing is reachable from your network.

| port | service | bind | notes |
|---|---|---|---|
| 3080 | dsh web | `127.0.0.1` | the agent UI -- has filesystem access, must stay local |
| 8090 | router | `127.0.0.1` | unauthenticated; can restart the engine |
| 8081 | engine | `127.0.0.1` | unauthenticated; the model itself |

This was NOT the case originally. Both the engine and the router bound `0.0.0.0`,
because the Docker VM could not reach `127.0.0.1` -- and that was verified reachable
from the LAN address, serving an unauthenticated LLM to anyone on the same wifi. With
Docker removed the flag was pure leftover exposure, so both now bind loopback.

None of these services has any authentication, so the loopback bind IS the security
boundary. Two consequences:

- **Do not "just expose" a port** to reach it from a phone or another laptop. An open
  :8090 lets anyone use the model, read every prompt, and trigger a model swap on each
  request -- 20-85s of reload each time, which is a trivial denial of service. Use an
  SSH tunnel instead: `ssh -L 8090:127.0.0.1:8090 <this-mac>`.
- **Restoring the container stack needs `BIND=0.0.0.0`** (engine) / `ROUTER_BIND=0.0.0.0`
  (router) so the VM can reach them, which re-opens the LAN. Only do that on a network
  you trust.

The macOS application firewall is currently **disabled**. It is not what is protecting
these ports -- the loopback bind is -- but turning it on is worth doing anyway:
System Settings > Network > Firewall.

## Why dsh feels slow (and the fix)

`./dsh-skills.sh off` -> ~1.5s per question. `on` -> ~8.5s. Cold, it was 26-27s.

dsh injects a `<system-reminder>` listing **every** skill in `~/.agents/skills` as a
user message placed AFTER your question. The message shape per turn is:

```
0: system = 4144c
1: user   =   23c   <- your question
2: user   =  464c   <- runtime context snapshot
3: user   = 12866c  <- the skill catalog (44 skills, ~3300 tokens)
```

A prefix cache can only reuse tokens up to the first change. Because the question sits
*before* ~3300 tokens of catalog, every new question invalidates all of it and forces a
re-prefill at ~400 tok/s. It gets worse as a conversation grows -- prefill is ~11s at
4.8k tokens and ~78s at 38k.

`~/.agents/skills` is dsh's own root. Claude Code reads `~/.claude/skills`, a different
directory, and is unaffected by the toggle.

What was measured and ruled out along the way:

| suspect | verdict |
|---|---|
| decode speed | fine -- 49-53 tok/s on predictable text (accept_len 8.02/7) |
| the two concurrent requests dsh sends | negligible, 1.02x |
| multi-turn prefix caching | works -- appends cost 0.36s vs 11.17s cold |
| a timestamp invalidating the cache | no -- a 70s-later repeat still hit (1.28s) |
| `--prefix-cache-slots` too low | **real** -- see below; the first test saying otherwise was contaminated |
| **question placed before the skill catalog** | **this was it** |

### Two fixes, measured

**1. `--prefix-cache-slots 4`** (in `engine.sh`). dsh sends TWO requests per turn --
the agent call (~4.4k tokens) and a small side call (~120 tok). With a single cache
slot they evict each other, so every OTHER turn was a full cold prefill:

```
1 slot : 35.5s  11.3s  39.2s  11.2s  40.8s  11.5s   <- alternating, avg ~24.6s
4 slots: 10.6s  10.0s  10.1s  10.5s  10.0s  10.2s   <- stable
```

Keep the slot count SMALL. Cached KV is wired memory that never pages out; an earlier
attempt at 8 slots with a 4 GB cap was not worth it.

**2. Shorter skill descriptions.** Only the `description:` frontmatter goes into the
catalog -- the skill body is untouched and the skill keeps working. Rewriting the 15
longest to one line each cut the catalog 14,639 -> 9,027 chars (3,659 -> 2,256 tokens):

```
long descriptions : ~12.1s steady
short descriptions:  ~9.4s steady
```

Backup of the originals: `~/.agents/skills.bak-*`.

### A warning about benchmarking this engine

The engine is single-sequence: it finishes a request even after the client
disconnects, and queues everything behind it. Two overlapping benchmarks therefore
produce nonsense -- during this investigation a 15-token request appeared to take
231s, and a 4.8k prefill appeared to take 91s, purely from queueing behind a killed
benchmark. Always confirm the engine is idle (a tiny request returning in <1.5s)
before trusting a number.

Note decode is only fast when the drafter guesses well: 49 tok/s counting numbers vs
14.5 tok/s writing a poem (accept_len 2.4/7). Speculative decoding helps predictable
output most.

## Memory budget (measured: 0.086 GB per 1k tokens of context)

| context | 8-bit total |
|---|---|
| 32K  | ~36 GB |
| 128K | ~44 GB |
| 256K | ~55 GB (use `KV_BITS=8` → ~44 GB) |

Weights 29.5 GB + drafter 3.85 GB + KV. Machine has 64 GB.

## Notes

- `HF_HUB_DISABLE_XET=1` is required — the Xet backend stalled at 0 MB/s here.
- Speculative decoding is **lossless relative to the target**: the target verifies
  every drafted token. It does not change what the model says, only how fast.
- `z-lab/Qwen3.8-27B-DFlash2` and `incoai/Qwen3.8-27B-DFlash2` are byte-identical
  mirrors (same safetensors SHA-256). Either works.
