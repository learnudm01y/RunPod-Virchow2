#!/bin/bash
# Downloads Virchow2 weights to local dir AND HF cache (required for offline loading)
# Run once per persistent volume. Re-running is safe (skips existing files).

PROJECT_DIR="${WORKSPACE_DIR:-/workspace/RunPod-Virchow2}"

# Fallback to setup_env.sh at workspace root if available
if [ -f "${PROJECT_DIR}/scripts/setup_env.sh" ]; then
    source "${PROJECT_DIR}/scripts/setup_env.sh" 2>/dev/null || true
elif [ -f "/workspace/setup_env.sh" ]; then
    source "/workspace/setup_env.sh" 2>/dev/null || true
fi

HF_CACHE="${HF_HUB_CACHE:-${PROJECT_DIR}/models/cache/hub}"
LOCAL_DIR="${PROJECT_DIR}/models/virchow2"

echo "✓ Environment ready"
echo "Downloading Virchow2 from HuggingFace..."
echo "  HF cache : ${HF_CACHE}"
echo "  Local dir: ${LOCAL_DIR}"
echo "  (first run: ~2.5 GB download; subsequent runs are instant)"

mkdir -p "${LOCAL_DIR}" "${HF_CACHE}"

# Delegate to Python scripts (avoids heredoc CRLF issues)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${WORKSPACE_DIR:-/workspace/RunPod-Virchow2}/venv/bin/python"
[ -x "$PYTHON" ] || PYTHON="$(command -v python3)"

# If model weights already exist locally → build HF cache from local files
# (no HF access needed; uses hard-links so no extra disk space)
# Otherwise → download from HuggingFace Hub (requires valid HF_TOKEN with model access)
if [ -f "${LOCAL_DIR}/model.safetensors" ]; then
    echo "  model.safetensors found locally – populating HF cache without re-downloading"
    "$PYTHON" "${SCRIPT_DIR}/populate_hf_cache.py"
else
    echo "  Weights not found – downloading from HuggingFace Hub..."
    "$PYTHON" "${SCRIPT_DIR}/download_virchow2.py"
fi
