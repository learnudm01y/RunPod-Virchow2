#!/usr/bin/env bash
# =============================================================================
# start_both.sh  –  Start Virchow2 (port 8000) + TITAN (port 8001) on same pod
#
# Usage (pod startup command):
#   bash /workspace/RunPod-Virchow2/scripts/start_both.sh
# =============================================================================

set -euo pipefail

echo "[start_both] ======================================================"
echo "[start_both] Starting Virchow2 (8000) + TITAN (8001)"
echo "[start_both] ======================================================"

mkdir -p /workspace/logs

# ─── Kill anything already on these ports ─────────────────────────────────────
fuser -k 8000/tcp 2>/dev/null && echo "[start_both] Killed process on 8000" || true
fuser -k 8001/tcp 2>/dev/null && echo "[start_both] Killed process on 8001" || true
sleep 1

# ─── Pull latest code ─────────────────────────────────────────────────────────
echo "[start_both] Pulling Virchow2..."
cd /workspace/RunPod-Virchow2
git pull origin main --quiet

echo "[start_both] Pulling TITAN..."
cd /workspace/RunPood-histo-TITAN
git pull origin main --quiet

# ─── Start Virchow2 on port 8000 (background) ─────────────────────────────────
echo "[start_both] Starting Virchow2 on port 8000..."
source /workspace/RunPod-Virchow2/scripts/setup_env.sh
cd /workspace/RunPod-Virchow2
nohup uvicorn app.server:app --host 0.0.0.0 --port 8000 --workers 1 \
    > /workspace/logs/virchow2.log 2>&1 &
VIRCHOW2_PID=$!
echo "[start_both] Virchow2 PID=${VIRCHOW2_PID}"

# ─── Start TITAN on port 8001 (background) ────────────────────────────────────
echo "[start_both] Starting TITAN on port 8001..."
source /workspace/RunPood-histo-TITAN/scripts/setup_env.sh
cd /workspace/RunPood-histo-TITAN
nohup uvicorn app.server:app --host 0.0.0.0 --port 8001 --workers 1 \
    > /workspace/logs/titan.log 2>&1 &
TITAN_PID=$!
echo "[start_both] TITAN PID=${TITAN_PID}"

echo "[start_both] Both servers started. Tailing logs (Ctrl+C to detach)..."
echo "[start_both] Virchow2 log: /workspace/logs/virchow2.log"
echo "[start_both] TITAN log:    /workspace/logs/titan.log"

# Tail both logs — keeps the process alive so RunPod doesn't kill the pod
tail -f /workspace/logs/virchow2.log /workspace/logs/titan.log
