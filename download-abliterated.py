#!/usr/bin/env python3
import os, time
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
from huggingface_hub import snapshot_download
REPO = "ailexleon/Huihui-Qwen3.8-27B-abliterated-mlx-8Bit"
log = open("/Users/vahdetd/local-ai/logs/download-abliterated.log", "a", buffering=1)
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
