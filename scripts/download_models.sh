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

"${WORKSPACE_DIR:-/workspace/RunPod-Virchow2}/venv/bin/python" 2>/dev/null - <<PYEOF || python3 - <<PYEOF
from huggingface_hub import snapshot_download, login
import os

hf_token = os.environ.get("HF_TOKEN", "")
if hf_token:
    login(token=hf_token, add_to_git_credential=False)

hf_cache  = os.environ.get("HF_HUB_CACHE",  "${HF_CACHE}")
local_dir = "${LOCAL_DIR}"

# cache_dir  → blob format in HF cache (allows offline loading by timm)
# local_dir  → flat copy for direct file access
snapshot_download(
    repo_id="paige-ai/Virchow2",
    cache_dir=hf_cache,
    local_dir=local_dir,
    local_dir_use_symlinks=False,
    token=hf_token or None,
)
print("Virchow2 downloaded successfully")
print(f"  HF cache populated at: {hf_cache}/models--paige-ai--Virchow2")
print(f"  Flat copy at:          {local_dir}")
PYEOF
