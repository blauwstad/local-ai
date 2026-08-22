#!/bin/bash
LOG=/Users/vahdetd/local-ai/logs/docker-install.log
mkdir -p /Users/vahdetd/local-ai/logs
{
  echo "=== $(date) installing colima + docker cli ==="
  brew install colima docker docker-compose
  echo "=== $(date) DONE ==="
  colima version 2>&1
  docker --version 2>&1
} >> "$LOG" 2>&1
