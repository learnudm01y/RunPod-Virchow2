"""
Populate the HuggingFace hub cache from EXISTING local model files.
No internet / HF token required.

Creates the blob + snapshot structure that timm expects when
HF_HUB_OFFLINE=1 is set, using hard-links to avoid duplicating data.

Usage:
    python scripts/populate_hf_cache.py
"""

import hashlib
import os
import shutil
import sys
from pathlib import Path


# ── Known commit hash for paige-ai/Virchow2 (from HF URL in error messages) ──
REPO_ID     = "paige-ai/Virchow2"
COMMIT_HASH = "3158645804b69e3f3bc4439d4116edddf0840a72"


def sha256_file(path: str) -> str:
    """SHA-256 of a file (matches HF blob naming convention)."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):   # 1 MB chunks
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    workspace = os.environ.get("WORKSPACE_DIR", "/workspace/RunPod-Virchow2")
    local_dir = os.path.join(workspace, "models", "virchow2")
    hf_cache  = os.environ.get("HF_HUB_CACHE",
                               os.path.join(workspace, "models", "cache", "hub"))

    if not os.path.isdir(local_dir):
        print(f"ERROR: local model dir not found: {local_dir}", file=sys.stderr)
        sys.exit(1)

    # ── Build cache dir paths ─────────────────────────────────────────────────
    cache_name    = "models--" + REPO_ID.replace("/", "--")
    cache_root    = os.path.join(hf_cache, cache_name)
    blobs_dir     = os.path.join(cache_root, "blobs")
    refs_dir      = os.path.join(cache_root, "refs")
    snapshots_dir = os.path.join(cache_root, "snapshots", COMMIT_HASH)

    os.makedirs(blobs_dir,     exist_ok=True)
    os.makedirs(refs_dir,      exist_ok=True)
    os.makedirs(snapshots_dir, exist_ok=True)

    # refs/main → commit hash
    with open(os.path.join(refs_dir, "main"), "w") as f:
        f.write(COMMIT_HASH)
    print(f"  refs/main → {COMMIT_HASH}")

    # ── Process each file in the flat local dir ───────────────────────────────
    total_bytes = 0
    files = sorted(p for p in Path(local_dir).iterdir() if p.is_file())

    if not files:
        print(f"ERROR: no files found in {local_dir}", file=sys.stderr)
        sys.exit(1)

    for src in files:
        mb = src.stat().st_size / 1024**2
        print(f"\n  {src.name}  ({mb:.1f} MB)")

        sha = sha256_file(str(src))
        blob_path = os.path.join(blobs_dir, sha)

        if not os.path.exists(blob_path):
            try:
                os.link(str(src), blob_path)   # hard-link (same inode, 0 extra space)
                print(f"    hard-linked  → blobs/{sha[:20]}...")
            except OSError:
                shutil.copy2(str(src), blob_path)
                print(f"    copied       → blobs/{sha[:20]}...")
        else:
            print(f"    blob exists  → blobs/{sha[:20]}...")

        # Symlink in snapshot dir → relative path to blob
        snap_link = os.path.join(snapshots_dir, src.name)
        if os.path.islink(snap_link) or os.path.exists(snap_link):
            os.remove(snap_link)
        rel = os.path.relpath(blob_path, snapshots_dir)
        os.symlink(rel, snap_link)
        print(f"    symlink      → snapshots/{COMMIT_HASH[:8]}/{src.name}")

        total_bytes += src.stat().st_size

    # ── Summary ───────────────────────────────────────────────────────────────
    print(f"\n{'─'*60}")
    print(f"HF cache populated at: {cache_root}")
    print(f"Files processed:       {len(files)}")
    print(f"Total size:            {total_bytes / 1024**3:.2f} GB")
    print()
    print("timm can now load Virchow2 offline:")
    print('  export HF_HUB_OFFLINE=1')
    print('  timm.create_model("hf-hub:paige-ai/Virchow2", pretrained=True)')


if __name__ == "__main__":
    main()
