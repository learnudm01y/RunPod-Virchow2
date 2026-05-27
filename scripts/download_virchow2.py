"""
Download Virchow2 weights into both:
  - HF blob cache (cache_dir)   → allows timm offline loading
  - flat local dir  (local_dir) → direct file access

Usage:
    python scripts/download_virchow2.py
"""
import os
import sys

from huggingface_hub import snapshot_download

# ── authenticate ────────────────────────────────────────────────────────────
hf_token = os.environ.get("HF_TOKEN", "")
if hf_token:
    try:
        from huggingface_hub import login
        login(token=hf_token, add_to_git_credential=False)
        print("  HF login: OK")
    except Exception as e:
        print(f"  HF login warning: {e}", file=sys.stderr)
else:
    print("  WARNING: HF_TOKEN not set – gated model download may fail", file=sys.stderr)

# ── paths ────────────────────────────────────────────────────────────────────
workspace  = os.environ.get("WORKSPACE_DIR", "/workspace/RunPod-Virchow2")
hf_cache   = os.environ.get("HF_HUB_CACHE",  f"{workspace}/models/cache/hub")
local_dir  = f"{workspace}/models/virchow2"

os.makedirs(local_dir, exist_ok=True)
os.makedirs(hf_cache,  exist_ok=True)

print(f"  HF cache : {hf_cache}")
print(f"  Local dir: {local_dir}")

# ── download ─────────────────────────────────────────────────────────────────
# cache_dir  → blob format (allows timm HF_HUB_OFFLINE=1 loading next time)
# local_dir  → flat copy   (direct access, human-readable)
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
