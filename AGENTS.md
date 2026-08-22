# local-ai — agent notes

Local Qwen3.5-27B (MLX, Apple Silicon). Everything below is **already installed and
working**. Do not install, build, or download anything for it.

## Never do these

- **No `pip install` / `brew install` / `git clone` for OCR or vision.** Both are set
  up. The Baidu Unlimited-OCR GitHub README is CUDA/PyTorch only and does not apply —
  we run the MLX port. Following it wastes 20+ minutes and fails on this machine.
- **Never `kill` the engine or `pkill mlx-dspark` directly.** It is supervised; a
  watchdog LaunchAgent restarts it, and killing it mid-flight can leave TWO 30 GB
  engines fighting for :8081. Use the scripts.
- **Never run two model processes.** Check: `pgrep -f "mlx-dspark serve|mlx_vlm.server" | wc -l` must be 1
  (2 is only valid when `./ocr.sh` is mid-run).

## Commands

| task | command |
|---|---|
| **which model am I?** | `./model.sh` (also shows thinking/vision/pin state) |
| switch model | `./model.sh uncensored` / `./model.sh stock` |
| OCR an image | `./ocr.sh image <file>` (layout+tables) / `./ocr.sh text <file>` (plain) |
| OCR a PDF | `./ocr.sh pdf <file.pdf> [outdir]` |
| let the model see images | `./vision.sh on [uncensored\|stock]` … `./vision.sh off` |
| reasoning on/off | `./thinking.sh on [low\|medium]` / `off` / `status` |
| free ~34 GB | `make sleep` (keeps router+dsh) or `make stop` (everything) |
| load it back | `make wake` |
| what is running | `make status` |

## Gotchas that will otherwise waste your time

- **The text engine silently drops images.** `mlx-dspark serve` returns HTTP 200 and
  the model says "no image attached". Run `./vision.sh on` first for image tasks.
- **OCR is size-sensitive.** Anything wider than ~1000 px degenerates into
  `10. 10. 10. ...`. `ocr.sh` downscales automatically — do not bypass it by calling
  `mlx_vlm.generate` yourself.
- **`web_fetch` works; `web_search` does not** (needs `DEEPSEEK_API_KEY`, which is
  cloud and deliberately unset). Fetch a known URL instead of searching.
- **PDF/Excel/Word are not readable directly.** Convert first: `pdftotext`, `pandoc`,
  or `./ocr.sh pdf` for scans. Then read the text file.

## Ports

`:8081` engine · `:8090` router (advertises both models, swaps on demand) · `:3080` dsh.
All bound to `127.0.0.1` on purpose — they are unauthenticated. Do not bind `0.0.0.0`.

See README.md for the reasoning behind any of this.
