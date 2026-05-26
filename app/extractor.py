"""
This file replaces TITAN's extractor.py.
Everything else in the architecture is identical.
"""

import os
import torch
import numpy as np
from pathlib import Path
from PIL import Image
from huggingface_hub import login
import timm
from timm.layers import SwiGLUPacked
from timm.data import resolve_data_config
from timm.data.transforms_factory import create_transform

MODEL_NAME    = "Virchow2"
MODEL_VERSION = "virchow2-v1"
EMBEDDING_DIM = 2560
HF_MODEL_ID   = "paige-ai/Virchow2"

_model      = None
_transforms = None


def load_model():
    """
    Load Virchow2 from local cache if available,
    otherwise download from HuggingFace.
    Model is cached at /workspace/VIRCHOW2/models/virchow2/
    """
    global _model, _transforms

    if _model is not None:
        return _model, _transforms

    hf_token = os.environ.get("HF_TOKEN")
    if hf_token:
        login(token=hf_token)

    workspace_dir = os.environ.get("WORKSPACE_DIR", "/workspace/VIRCHOW2")
    # If testing locally and /workspace/VIRCHOW2 doesn't exist, fallback to the current script's parent's parent dir
    if workspace_dir == "/workspace/VIRCHOW2" and not os.path.exists("/workspace"):
        workspace_dir = str(Path(__file__).resolve().parent.parent)

    local_path = f"{workspace_dir}/models/virchow2"

    # Try local first, fall back to HuggingFace
    if os.path.exists(f"{local_path}/model.safetensors"):
        print(f"Loading Virchow2 from local cache: {local_path}")
        model_source = f"hf-hub:{local_path}"
    else:
        print(f"Downloading Virchow2 from HuggingFace: {HF_MODEL_ID}")
        model_source = f"hf-hub:{HF_MODEL_ID}"

    device = "cuda" if torch.cuda.is_available() else ("mps" if hasattr(torch.backends, "mps") and torch.backends.mps.is_available() else "cpu")

    _model = timm.create_model(
        f"hf-hub:{HF_MODEL_ID}",
        pretrained=True,
        mlp_layer=SwiGLUPacked,   # REQUIRED for Virchow2
        act_layer=torch.nn.SiLU   # REQUIRED for Virchow2
    ).eval().to(device)

    _transforms = create_transform(
        **resolve_data_config(_model.pretrained_cfg, model=_model)
    )

    print(f"Virchow2 loaded — embedding dim: {EMBEDDING_DIM}")
    return _model, _transforms


def extract_features(patches_dir: str) -> dict:
    """
    Main function called by main.py.
    
    Args:
        patches_dir: path to folder containing patch PNG files
                     e.g. /workspace/VIRCHOW2/input/patches/slide_id/
    
    Returns:
        dict with:
            embeddings   → np.array (N, 2560)
            patch_names  → list of filenames
            patch_count  → int
            failed_count → int
            model_name   → "Virchow2"
            model_version→ "virchow2-v1"
            embedding_dim→ 2560
    """
    model, transforms = load_model()
    device = "cuda" if torch.cuda.is_available() else ("mps" if hasattr(torch.backends, "mps") and torch.backends.mps.is_available() else "cpu")

    patch_files = sorted([
        f for f in Path(patches_dir).glob("*.png")
        if f.name.startswith("patch_")
    ])

    if len(patch_files) == 0:
        raise ValueError(f"No patch files found in {patches_dir}")

    print(f"Running Virchow2 on {len(patch_files)} patches...")

    embeddings   = []
    patch_names  = []
    failed_count = 0

    for i, patch_path in enumerate(patch_files):
        try:
            image  = Image.open(patch_path).convert("RGB")
            tensor = transforms(image).unsqueeze(0).to(device)

            with torch.inference_mode(), \
                 torch.autocast(device_type="cuda" if device == "cuda" else "cpu", dtype=torch.float16 if device == "cuda" else torch.float32):
                output = model(tensor)   # (1, 257, 1280)

            class_token  = output[:, 0]       # (1, 1280)
            patch_tokens = output[:, 1:]      # (1, 256, 1280)
            embedding    = torch.cat(
                [class_token, patch_tokens.mean(1)], dim=-1
            )   # (1, 2560)

            embeddings.append(embedding.cpu().float().numpy()[0])
            patch_names.append(patch_path.name)

        except Exception as e:
            print(f"Failed patch {patch_path.name}: {e}")
            failed_count += 1

        if (i + 1) % 100 == 0:
            print(f"  {i+1}/{len(patch_files)} done...")

    return {
        "embeddings":    np.array(embeddings),   # (N, 2560)
        "patch_names":   patch_names,
        "patch_count":   len(embeddings),
        "failed_count":  failed_count,
        "model_name":    MODEL_NAME,
        "model_version": MODEL_VERSION,
        "embedding_dim": EMBEDDING_DIM,
    }
