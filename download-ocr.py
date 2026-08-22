#!/usr/bin/env python3
"""Fetch the Apple-Silicon MLX build of Baidu's Unlimited-OCR (~3.9 GB).
Small enough to serve alongside the 30 GB text engine rather than swapping for it."""
import os, time
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")   # the Xet backend stalls here
from huggingface_hub import snapshot_download
REPO = "mlx-community/Unlimited-OCR-8bit"
log = open("/Users/vahdetd/local-ai/logs/download-ocr.log", "a", buffering=1)
def say(m): log.write(f"[{time.strftime('%H:%M:%S')}] {m}\n")
attempt = 0
while True:
    attempt += 1
    try:
        say(f"START {REPO} (attempt {attempt})")
        p = snapshot_download(repo_id=REPO, max_workers=4)
        say(f"DONE -> {p}"); say("ALL DONE"); break
    except Exception as e:
        say(f"RETRY: {type(e).__name__}: {str(e)[:200]}")
        time.sleep(min(30, 2*attempt))
