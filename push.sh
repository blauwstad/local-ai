#!/bin/bash
# Commit and push the setup to blauwstad/local-ai (private).
#   ./push.sh "what changed"
#
# Logs, results and .venv are gitignored: logs can contain prompt text, and the venv
# is 594 MB. Only the setup itself is tracked.
set -euo pipefail
cd "$(dirname "$0")"
msg="${1:-update local AI setup}"

# refuse to push if a secret ever lands in a tracked file
if git diff --cached --name-only >/dev/null 2>&1; then :; fi
git add -A
if git diff --cached --quiet; then echo "nothing to push"; exit 0; fi
if git diff --cached | grep -qE "(sk-[A-Za-z0-9]{20,}|gh[pos]_[A-Za-z0-9]{20,}|hf_[A-Za-z0-9]{20,})"; then
  echo "!! refusing to push: a token-shaped string is in the staged diff"; exit 1
fi
git -c user.name="vahdetd" -c user.email="delkaya@gmail.com" commit -q -m "$msg"
git push -q origin main
echo "pushed: $msg"
git log --oneline | head -1 | sed 's/^/  /'
