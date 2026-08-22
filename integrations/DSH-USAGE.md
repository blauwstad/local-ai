# Using your local Qwen3.8-27B inside DeepSeek Harness

**Verified working** — `dsh` 0.1.1-rc.1, Qwen3.8-27B-8bit, no cloud, no API key.

## The chain

```
dsh  ──►  gateway :8080 (Docker)  ──►  mlx-dspark :8081 (host, Metal)  ──►  Qwen3.8-27B-8bit
```

Nothing leaves your Mac. Your DeepSeek API key is NOT used and is not needed.

## Start it (three steps)

```bash
cd /Users/vahdetd/local-ai
make engine      # native MLX engine — waits ~40s to load 29.5 GB
make up          # dockerized gateway on :8080
./dsh-local.sh   # opens the dsh web UI on :3080
```

## Daily use

```bash
./dsh-local.sh web              # web UI at http://127.0.0.1:3080
./dsh-local.sh ask "fix the failing test in api.py"   # one-shot, prints, exits
./dsh-local.sh tui              # terminal UI
./dsh-local.sh stop             # stop the web server
DSH_PORT=3081 ./dsh-local.sh web   # run on a different port
```

## EADDRINUSE on :3080

```
Error: listen EADDRINUSE: address already in use 127.0.0.1:3080
```

`dsh web` is already running — only one server can hold the port. The web UI is a
long-lived server, not a per-command process, so a second launch always collides.

`./dsh-local.sh web` now detects this and tells you which pid holds the port
instead of throwing a stack trace. Options:

- **Reuse it** — just open <http://127.0.0.1:3080>.
- **Restart it** — `./dsh-local.sh stop && ./dsh-local.sh web`
- **Run a second one** — `DSH_PORT=3081 ./dsh-local.sh web`
- **Find it manually** — `lsof -nP -iTCP:3080 -sTCP:LISTEN`

Note `./dsh-local.sh ask` and `tui` are unaffected — they bind no port.

Run it from the directory you want the agent to work in — `dsh` uses the cwd as
its workspace, so `cd ~/myproject && /Users/vahdetd/local-ai/dsh-local.sh web`.

## What makes it work (`~/.dsh/settings.yaml`)

```yaml
llm-pi-ai:
  providers:
    local-mlx:
      api: openai-completions
      baseURL: http://127.0.0.1:8080/v1
      apiKeyEnv: LOCAL_MLX_KEY        # NOT `apiKey:` — dsh wants an env var NAME
      compat:
        supportsDeveloperRole: false  # Qwen3.8 declares reasoning; dsh would send
        maxTokensField: max_tokens    # role:"developer" + max_completion_tokens
      models:
        - id: Qwen3.8-27B-8bit
agent-default-model:
  provider: local-mlx
  model: Qwen3.8-27B-8bit
```

Four things that will bite you if changed:

1. **`apiKeyEnv`, not `apiKey`.** A literal key fails with
   `PI_AI_ERROR: No API key for provider: local-mlx`. It wants the *name* of an
   env var. `dsh-local.sh` exports `LOCAL_MLX_KEY=local` for you.
2. **The two `compat` flags are mandatory.** Qwen3.8 is a reasoning model, so dsh
   sends the system prompt as `role: "developer"` and caps output with
   `max_completion_tokens`. mlx-dspark's OpenAI route accepts neither.
3. **`agent-default-model` must be overridden.** It ships pointing at
   `deepseek-official` / `deepseek-v4-flash` — i.e. the cloud. Without this block
   dsh ignores your local model.
4. **`dsh` is at `~/.hermes/node/bin`**, which is not on your default PATH.

## Measured

| Test | Result |
|---|---|
| Chat round-trip | works |
| Agentic loop (read → edit → run → verify) | works, **48.7 s** |
| Model self-report | `Qwen3.8-27B-8bit` |
| Throughput | ~22 tok/s (2.3× over 9.3 baseline) |

The agentic test gave it a `ZeroDivisionError` bug; it read the file, added the
guard, executed the file to confirm `2.0` then `0.0`, and stopped.

## Note on agent workloads

Agent turns are prefill-heavy, not decode-heavy. mlx-dspark's prefix cache matters
more here than raw tok/s — repeated turns over the same file tree reuse cached
prefill. Expect the first turn in a session to be slowest.

---

# Troubleshooting: "the AI gives no answer"

Three separate causes, all now fixed. Check in this order.

## 1. Engine unreachable (was the real cause)

The Colima VM had stopped, taking the Docker gateway on :8080 with it. `dsh` was
configured to reach the model *through* that gateway, so every request was
connection-refused and the UI just sat there.

**Fixed structurally**: `dsh` now points at the engine **directly** on `:8081`.
`dsh` is a native macOS process — routing it host → Docker VM → back to host was
a pointless round trip that added a failure mode. Docker is no longer required
for `dsh` at all; the gateway remains for *containerized* clients (Open WebUI,
the bench harness).

Check:
```bash
curl -s http://127.0.0.1:8081/v1/models   # must return JSON
make engine                                # if not
```

## 2. The first turn takes ~40 s. It is not hung.

| turn | time |
|---|---|
| first after engine start | **~40 s** |
| every turn after | **~1.4–2 s** |

The first request pays prefill of a large system prompt (dsh injects its tool
definitions and every skill it discovers) plus a one-time draft-cap calibration.
After that mlx-dspark's **prefix cache** holds the system prompt and turns are
near-instant. Wait out the first one.

Multi-step agent tasks (read → edit → run → verify) take ~40 s regardless,
because each step is a separate model call.

## 3. Thinking mode ate the token budget

Qwen3.8 reasons by default, emitting reasoning tokens before the first visible
word. `engine.sh` now exposes this:

```bash
THINKING=off make engine     # default now — best for agent/tool loops
THINKING=on EFFORT=low make engine
THINKING=on EFFORT=high make engine   # slowest, most careful
```

## 4. Check your workspace

Your session showed:
```
DSH file policy: workspace-write ... session workspace: "/private/tmp/dsh-test"
```
`/private/tmp/dsh-test` was a scratch directory left over from testing — the agent
could only write there. `dsh` uses **the directory you launch it from**:

```bash
cd ~/my-real-project
/Users/vahdetd/local-ai/dsh-local.sh web
```

## 5. Approval policy

```
Approval policy: ask ... without an available answerer, the request fails closed.
```
In the web UI, approvals appear as prompts you click. In `--profile headless`
there is no one to ask, so an operation needing approval **fails closed** rather
than hanging. If a headless task stalls or silently does nothing, run it in the
web UI instead to see what it is asking permission for.
