#!/bin/bash
# Launch dsh with /Users/vahdetd/Documents/App1 as the agent workspace.
cd /Users/vahdetd/Documents/App1 || exit 1
exec /Users/vahdetd/local-ai/dsh-local.sh "$@"
