#!/bin/bash
# Unlimited-OCR (Baidu) on Apple Silicon — text, tables and layout out of images/PDFs.
#
#   ./ocr.sh image <file.png|jpg> [prompt]
#   ./ocr.sh pdf   <file.pdf> [outdir]        # renders pages, OCRs each
#   ./ocr.sh text  <file>                     # OCR to plain text (drops boxes/tables)
#
# WHY THE CLI AND NOT A SERVER
# mlx_vlm's OpenAI server fails on this model with "There is no Stream(gpu, 2) in
# current thread" -- an MLX threading bug in its request handling, reproducible with
# the text engine both running and stopped. `mlx_vlm.generate` runs in-process and
# works. It reloads the 3.9 GB model per call, but the whole run is ~5s, so a
# persistent server buys little.
#
# Output includes <|det|>region [x1,y1,x2,y2]<|/det|> boxes and real <table> HTML.
set -uo pipefail
cd "$(dirname "$0")"

MODEL="mlx-community/Unlimited-OCR-8bit"
# NOTE: no literal <image> in the prompt. The image token comes from --image; adding
# the tag too makes the model count 2 images for 1 file and the run fails.
DEFAULT_PROMPT="document parsing."

# This checkpoint is SIZE-SENSITIVE. At 1000x620 it reads a document perfectly; the
# same page rendered at 1389x862 or 2778x1723 degenerates into "10. 10. 10. ..." with
# no real text at all. Baidu's own example uses base_size=1024, so anything wider than
# OCR_WIDTH gets downscaled first. Without this, `ocr.sh pdf` silently returns garbage.
OCR_WIDTH="${OCR_WIDTH:-1000}"

fit_image() {
  .venv/bin/python - "$1" "$OCR_WIDTH" <<'PYE'
import sys, tempfile, os
from PIL import Image
src, w = sys.argv[1], int(sys.argv[2])
im = Image.open(src).convert("RGB")
if im.size[0] <= w:
    print(src)
else:
    h = int(im.size[1] * w / im.size[0])
    out = os.path.join(tempfile.mkdtemp(prefix="ocr-"), "fit.png")
    im.resize((w, h), Image.LANCZOS).save(out)
    print(out)
PYE
}

ocr_one() {
  local img; img="$(fit_image "$1")"
  set -- "$img" "${2:-}"
  .venv/bin/python -m mlx_vlm.generate --model "$MODEL" --image "$1" \
    --prompt "${2:-$DEFAULT_PROMPT}" --max-tokens "${OCR_MAX_TOKENS:-4096}" --temperature 0 2>/dev/null \
    | grep -vE "^(Fetching|Add pad token|<｜▁pad▁｜>|Add image token|<image>:|Added )" \
    | sed '/^==========$/d'
}

case "${1:-help}" in
  image) shift; ocr_one "${1:?usage: ocr.sh image <file>}" "${2:-}" ;;

  text)  shift
    # Keep table structure readable: cells -> " | ", rows -> newlines, before tags go.
    # Also drop the stray leading date the model sometimes emits (a known artifact of
    # this checkpoint -- it prepended "2017年1月1日" to a 2026 invoice in testing).
    ocr_one "${1:?usage: ocr.sh text <file>}" "$DEFAULT_PROMPT" \
      | sed -E 's/<\|det\|>[^<]*<\|\/det\|>//g' \
      | sed -E 's#</td>#\ | #g; s#</tr>#\'$'\n''#g' \
      | sed -E 's/<[^>]+>//g' \
      | sed -E 's/[[:space:]]*\|[[:space:]]*$//' \
      | awk 'NR==1 && (/^[0-9]+年[0-9]+月[0-9]+日$/ || /^([0-9]+\. ){5,}/) {next} {print}' \
      | sed '/^[[:space:]]*$/d' ;;

  pdf)   shift
    f="${1:?usage: ocr.sh pdf <file.pdf> [outdir]}"
    out="${2:-./ocr-out}"; mkdir -p "$out"
    command -v pdftoppm >/dev/null || { echo "pdftoppm not found (brew install poppler)"; exit 1; }
    echo "rendering pages…"
    pdftoppm -r 200 -png "$f" "$out/page"
    n=0
    for p in "$out"/page-*.png; do
      n=$((n+1)); echo "--- page $n ($(basename "$p")) ---"
      ocr_one "$p" | tee "$out/$(basename "${p%.png}").md"
    done
    echo "wrote $n page(s) to $out/" ;;

  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
