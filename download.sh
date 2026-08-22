#!/bin/bash
source /Users/vahdetd/local-ai/.venv/bin/activate
export HF_HUB_ENABLE_HF_TRANSFER=1
LOG=/Users/vahdetd/local-ai/logs/download.log
mkdir -p /Users/vahdetd/local-ai/logs
{
  echo "=== $(date) target: Qwen3.8-27B-8bit (29.5GB) ==="
  hf download mlx-community/Qwen3.8-27B-8bit
  echo "=== $(date) drafter: DFlash2 (3.85GB) ==="
  hf download incoai/Qwen3.8-27B-DFlash2
  echo "=== $(date) DONE ==="
} >> "$LOG" 2>&1
