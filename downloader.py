#!/usr/bin/env python3
"""Resilient, resumable downloader. Retries forever on transient network errors."""
import os, sys, time, traceback
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")   # xet stalled; plain HTTP resumes reliably
from huggingface_hub import snapshot_download

REPOS = ["incoai/Qwen3.8-27B-DFlash2", "mlx-community/Qwen3.8-27B-8bit"]
log = open("/Users/vahdetd/local-ai/logs/download.log", "a", buffering=1)

def say(m):
    log.write(f"[{time.strftime('%H:%M:%S')}] {m}\n")

for repo in REPOS:
    attempt = 0
    while True:
        attempt += 1
        try:
            say(f"START {repo} (attempt {attempt})")
            p = snapshot_download(repo_id=repo, max_workers=4)
            say(f"DONE {repo} -> {p}")
            break
        except KeyboardInterrupt:
            say("interrupted"); sys.exit(1)
        except Exception as e:
            say(f"RETRY {repo}: {type(e).__name__}: {str(e)[:200]}")
            time.sleep(min(30, 2 * attempt))
say("ALL DONE")
