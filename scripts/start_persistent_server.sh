#!/bin/bash

if [ -d "/workspace/VIRCHOW2" ]; then
    WORKSPACE_ROOT="/workspace"
else
    WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

source "$WORKSPACE_ROOT/setup_env.sh"

cd "$WORKSPACE_ROOT/VIRCHOW2"

mkdir -p logs input/patches output/features output/logs

nohup "$WORKSPACE_ROOT/VIRCHOW2/venv/bin/python" -m uvicorn app.server:app \
  --host 0.0.0.0 \
  --port 8000 \
  --workers 1 \
  > "$WORKSPACE_ROOT/VIRCHOW2/logs/server.log" 2>&1 &

echo "Virchow2 server started — PID: $!"
echo "URL: https://${RUNPOD_POD_HOSTNAME}-8000.proxy.runpod.net"
echo "Logs: tail -f $WORKSPACE_ROOT/VIRCHOW2/logs/server.log"
