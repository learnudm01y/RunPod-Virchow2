#!/bin/bash
# Downloads Virchow2 weights to local cache
# Run once before starting the server

if [ -d "/workspace/VIRCHOW2" ]; then
    WORKSPACE_ROOT="/workspace"
else
    WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

source "$WORKSPACE_ROOT/setup_env.sh"

echo "Downloading Virchow2 from HuggingFace..."
echo "This will download ~2.5 GB"

mkdir -p "$WORKSPACE_ROOT/VIRCHOW2/models/virchow2"

python3 - << PYEOF
from huggingface_hub import snapshot_download
import os

snapshot_download(
    repo_id="paige-ai/Virchow2",
    local_dir="${WORKSPACE_ROOT}/VIRCHOW2/models/virchow2",
    token=os.environ.get("HF_TOKEN")
)
print("Virchow2 downloaded successfully")
PYEOF
