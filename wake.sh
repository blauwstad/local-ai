#!/bin/bash
# Load the engine back without waiting for a request to trigger it.
cd "$(dirname "$0")"
want="${1:-$(cat logs/last-model 2>/dev/null || echo uncensored)}"
echo "loading '$want' — ~40s for 29.5 GB"
./switch-model.sh "$want"     # this also clears logs/.idle
