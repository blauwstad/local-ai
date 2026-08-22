# Client integrations

All of these talk to the **dockerized gateway** on `:8080`. None need an API key —
the model is on your machine.

## DeepSeek Harness (dsh)
```sh
npx @deepseek-ai/dsh web
```
Merge `dsh-settings.yaml` into `~/.dsh/settings.yaml`, or use the UI:
Models -> Add a custom provider -> base URL `http://127.0.0.1:8080/v1`, protocol
`openai-completions`, any key. Then set the two compat flags in settings.yaml
(the form has no field for them).

## Claude Code
mlx-dspark serves an Anthropic-compatible route too:
```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8080 claude
# or: mlx-dspark claude
```

## Anything OpenAI-compatible
`base_url=http://127.0.0.1:8080/v1`, `api_key=local`.

---

## Two different DeepSeek projects — don't confuse them

| | what it is | role here |
|---|---|---|
| **deepseek-ai/DeepSpec** | speculative-decoding training/eval codebase | **already in use** — mlx-dspark is its MLX port; DSpark drafters come from it |
| **deepseek-ai/deepseek-harness** (`dsh`) | agent harness / coding UI, "everything is a plugin" | optional *client* that drives the local model |

DeepSpec is the engine layer, dsh is the client layer. The Qwen model is what
actually generates tokens in both cases.
