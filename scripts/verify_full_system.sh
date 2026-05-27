#!/usr/bin/env bash
# =============================================================================
# verify_full_system.sh
# =============================================================================
# FULL READINESS VERIFICATION for RunPod Virchow2 + TITAN feature-extraction
# pipeline connected to the Laravel management system.
#
# Run this ONCE after every new pod creation before dispatching any jobs.
#
# Usage (on RunPod terminal):
#   bash /workspace/VIRCHOW2/scripts/verify_full_system.sh
#
# Exit codes:
#   0  – All critical checks passed (warnings are OK)
#   1  – One or more CRITICAL checks failed
# =============================================================================

set -uo pipefail

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS="${GREEN}[PASS]${RESET}"
FAIL="${RED}[FAIL]${RESET}"
WARN="${YELLOW}[WARN]${RESET}"
INFO="${CYAN}[INFO]${RESET}"

CRITICAL_FAILURES=0

pass()  { printf "  ${PASS}  %s\n" "$*"; }
fail()  { printf "  ${FAIL}  %s\n" "$*"; (( CRITICAL_FAILURES++ )) || true; }
warn()  { printf "  ${WARN}  %s\n" "$*"; }
info()  { printf "  ${INFO}  %s\n" "$*"; }

section() {
    printf "\n${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}\n"
    printf "${BOLD}  %s${RESET}\n" "$*"
    printf "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}\n"
}

# ─── Workspace resolution ─────────────────────────────────────────────────────
if [ -d "/workspace" ]; then
    WORKSPACE_ROOT="/workspace"
else
    WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
WORKSPACE="${WORKSPACE_DIR:-${WORKSPACE_ROOT}/RunPod-Virchow2}"
PROJECT_DIR="${WORKSPACE}"   # the git repo lives in /workspace/RunPod-Virchow2
MODEL_DIR="${WORKSPACE}/models/virchow2"
VENV_DIR="${WORKSPACE}/venv"
RCLONE_CONF="${HOME:-/root}/.config/rclone/rclone.conf"
RCLONE_CONF_ALT="${WORKSPACE}/rclone.conf"

printf "\n${BOLD}RunPod Virchow2 – Full System Readiness Check${RESET}\n"
printf "Date       : $(date -u +'%Y-%m-%dT%H:%M:%SZ')\n"
printf "Hostname   : $(hostname)\n"
printf "Workspace  : ${WORKSPACE}\n"
printf "Project    : ${PROJECT_DIR}\n"


# ─────────────────────────────────────────────────────────────────────────────
section "1. ENVIRONMENT VARIABLES"
# ─────────────────────────────────────────────────────────────────────────────

check_env() {
    local var="$1"
    local label="${2:-$1}"
    local value="${!var:-}"
    if [ -n "$value" ]; then
        # Mask secrets – show first 6 chars then ***
        local masked="${value:0:6}***"
        pass "${label} = ${masked}"
    else
        fail "${label} is NOT set  →  export ${var}=\"...\""
    fi
}

check_env "RUNPOD_API_KEY"   "RUNPOD_API_KEY  (shared secret for /jobs/start auth)"
check_env "API_BASE_URL"     "API_BASE_URL    (Laravel management server URL)"
check_env "API_KEY"          "API_KEY         (Laravel Bearer token for callbacks)"
check_env "HF_TOKEN"         "HF_TOKEN        (Hugging Face – needed for Virchow2)"
check_env "RCLONE_REMOTE"    "RCLONE_REMOTE   (rclone remote name, e.g. gdrive)"

# Optional but useful
for opt in GDRIVE_INPUT_PATH GDRIVE_OUTPUT_PATH BATCH_SIZE NUM_WORKERS; do
    val="${!opt:-}"
    if [ -n "$val" ]; then
        info "${opt} = ${val}"
    else
        warn "${opt} not set – will use default from config.py"
    fi
done


# ─────────────────────────────────────────────────────────────────────────────
section "2. WORKSPACE FILESYSTEM"
# ─────────────────────────────────────────────────────────────────────────────

check_path() {
    local path="$1"; local label="$2"
    if [ -e "$path" ]; then
        if [ -d "$path" ]; then
            local n; n=$(find "$path" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
            pass "${label}  (${n} items)"
        else
            local sz; sz=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
            pass "${label}  (${sz})"
        fi
    else
        fail "${label}  →  MISSING: ${path}"
    fi
}

# Workspace mount
if mountpoint -q "${WORKSPACE_ROOT}" 2>/dev/null; then
    pass "Persistent volume mounted at ${WORKSPACE_ROOT}"
else
    warn "${WORKSPACE_ROOT} is not a mountpoint – check pod volume configuration"
fi

df -h "${WORKSPACE_ROOT}" 2>/dev/null | tail -1 | awk '{
    printf "  '"${INFO}"'  Disk usage: used=%s  avail=%s  use%%=%s\n", $3, $4, $5}'

check_path "${WORKSPACE}"                   "VIRCHOW2 workspace dir"
check_path "${PROJECT_DIR}/app"             "app/ (Python sources)"
check_path "${PROJECT_DIR}/scripts"         "scripts/"
check_path "${PROJECT_DIR}/requirements.txt" "requirements.txt"
check_path "${WORKSPACE}/input"             "input/ directory"
check_path "${WORKSPACE}/output"            "output/ directory"
check_path "${WORKSPACE}/logs"              "logs/ directory"


# ─────────────────────────────────────────────────────────────────────────────
section "3. MODEL WEIGHTS  (Virchow2)"
# ─────────────────────────────────────────────────────────────────────────────

check_path "${MODEL_DIR}" "models/virchow2/"

if [ -d "${MODEL_DIR}" ]; then
    # Key weight files for Virchow2 (timm model – no preprocessor_config.json needed)
    for f in "model.safetensors" "config.json"; do
        fp="${MODEL_DIR}/${f}"
        if [ -f "$fp" ]; then
            sz=$(du -sh "$fp" 2>/dev/null | awk '{print $1}')
            pass "models/virchow2/${f}  (${sz})"
        else
            fail "models/virchow2/${f}  \u2192  MISSING"
        fi
    done

    # Total model directory size
    total=$(du -sh "${MODEL_DIR}" 2>/dev/null | awk '{print $1}')
    info "Total model directory size: ${total}  (safetensors \u2248 2.4 GB + bin duplicate = \u2248 4.8 GB normal)"

    # Check model.safetensors is at least 2 GB (full weights)
    if [ -f "${MODEL_DIR}/model.safetensors" ]; then
        size_bytes=$(stat -c%s "${MODEL_DIR}/model.safetensors" 2>/dev/null || echo 0)
        size_gb=$(awk "BEGIN {printf \"%.2f\", ${size_bytes}/1073741824}")
        if (( size_bytes > 2000000000 )); then
            pass "model.safetensors size ${size_gb} GB  (≥ 2 GB – looks complete)"
        else
            fail "model.safetensors size ${size_gb} GB  (< 2 GB – may be truncated!)"
        fi
    fi
else
    fail "Model directory missing – run:  bash ${PROJECT_DIR}/scripts/download_models.sh"
fi


# ─────────────────────────────────────────────────────────────────────────────
section "4. PYTHON ENVIRONMENT"
# ─────────────────────────────────────────────────────────────────────────────

# Determine python binary – prefer venv on persistent disk
if [ -x "${VENV_DIR}/bin/python" ]; then
    PYTHON="${VENV_DIR}/bin/python"
    pass "venv python found: ${PYTHON}"
elif command -v python3 &>/dev/null; then
    PYTHON="python3"
    fail "No venv found at ${VENV_DIR}"  
    info "Fix: bash ${PROJECT_DIR}/scripts/first_run_setup.sh"
else
    fail "No python3 found on PATH"
    PYTHON=""
fi

if [ -n "${PYTHON}" ]; then
    PY_VERSION=$("${PYTHON}" --version 2>&1)
    info "Python version: ${PY_VERSION}"

    "${PYTHON}" - <<'PYEOF'
import sys

packages = [
    ("torch",           "2.1.0"),
    ("torchvision",     "0.16.0"),
    ("transformers",    "4.40.0"),
    ("huggingface_hub", "0.22.0"),
    ("timm",            "0.9.16"),
    ("einops",          "0.7.0"),
    ("einops_exts",     None),
    ("h5py",            "3.10.0"),
    ("numpy",           "1.26.0"),
    ("PIL",             None),
    ("tqdm",            "4.66.0"),
    ("httpx",           "0.27.0"),
    ("fastapi",         "0.110.0"),
    ("uvicorn",         "0.27.0"),
    ("pydantic",        "2.6.0"),
]

RED   = "\033[0;31m"; GREEN = "\033[0;32m"; YELLOW = "\033[1;33m"; RESET = "\033[0m"
PASS  = f"  {GREEN}[PASS]{RESET}"
FAIL  = f"  {RED}[FAIL]{RESET}"

all_ok = True
for pkg, min_ver in packages:
    try:
        mod = __import__(pkg)
        ver = getattr(mod, "__version__", "?")
        print(f"{PASS}  {pkg:<20}  {ver}")
    except ImportError as exc:
        print(f"{FAIL}  {pkg:<20}  MISSING  ({exc})")
        all_ok = False

sys.exit(0 if all_ok else 1)
PYEOF
    PY_PKG_STATUS=$?
    if [ $PY_PKG_STATUS -ne 0 ]; then
        fail "One or more Python packages are missing"
        info "Fix: cd ${PROJECT_DIR} && pip install -r requirements.txt"
    fi

    # CUDA availability
    "${PYTHON}" - <<'PYEOF'
import sys, os
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; RESET="\033[0m"
try:
    import torch
    if torch.cuda.is_available():
        n = torch.cuda.device_count()
        for i in range(n):
            props = torch.cuda.get_device_properties(i)
            total_gb = props.total_memory / 1024**3
            print(f"  {GREEN}[PASS]{RESET}  GPU {i}: {props.name}  –  VRAM {total_gb:.1f} GB")
            # Virchow2 in fp16 needs ~2.5 GB; TITAN needs ~3.5 GB
            if total_gb >= 16:
                print(f"  {GREEN}[PASS]{RESET}  Sufficient VRAM for multi-model (≥ 16 GB)")
            elif total_gb >= 8:
                print(f"  {YELLOW}[WARN]{RESET}  VRAM ≥ 8 GB – single model OK; multi-model may be tight")
            else:
                print(f"  {RED}[FAIL]{RESET}  VRAM < 8 GB – may OOM during extraction")
    else:
        print(f"  {RED}[FAIL]{RESET}  CUDA not available – will run on CPU (very slow!)")
        sys.exit(1)
except Exception as exc:
    print(f"  {RED}[FAIL]{RESET}  torch import error: {exc}")
    sys.exit(1)
PYEOF
fi


# ─────────────────────────────────────────────────────────────────────────────
section "5. RCLONE  (Google Drive)"
# ─────────────────────────────────────────────────────────────────────────────

if command -v rclone &>/dev/null; then
    RCLONE_VER=$(rclone --version 2>&1 | head -1)
    pass "rclone installed: ${RCLONE_VER}"
else
    fail "rclone not found on PATH"
    info "Install: curl https://rclone.org/install.sh | sudo bash"
fi

# Restore rclone.conf from workspace if not in ~/.config
if [ ! -f "${RCLONE_CONF}" ] && [ -f "${RCLONE_CONF_ALT}" ]; then
    mkdir -p "$(dirname "${RCLONE_CONF}")"
    cp "${RCLONE_CONF_ALT}" "${RCLONE_CONF}"
    warn "Restored rclone.conf from ${RCLONE_CONF_ALT} → ${RCLONE_CONF}"
fi

if [ -f "${RCLONE_CONF}" ]; then
    pass "rclone.conf present: ${RCLONE_CONF}"
    # List configured remotes
    REMOTES=$(rclone listremotes 2>/dev/null || echo "")
    if [ -n "${REMOTES}" ]; then
        info "Configured remotes: $(echo "$REMOTES" | tr '\n' ' ')"
    else
        fail "No rclone remotes configured – copy rclone.conf to ${RCLONE_CONF}"
    fi

    # Test connectivity to the GDrive remote
    REMOTE="${RCLONE_REMOTE:-gdrive}"
    info "Testing connectivity to remote '${REMOTE}' ..."
    if timeout 60 rclone lsd "${REMOTE}:" --max-depth 1 &>/dev/null; then
        pass "rclone can list '${REMOTE}:' (Google Drive is reachable)"
    else
        fail "Cannot reach '${REMOTE}:' – check rclone.conf token or network"
    fi
else
    fail "rclone.conf not found at ${RCLONE_CONF}"
    info "Save your rclone config to ${RCLONE_CONF_ALT} for persistence"
fi


# ─────────────────────────────────────────────────────────────────────────────
section "6. LARAVEL API CONNECTIVITY"
# ─────────────────────────────────────────────────────────────────────────────

LARAVEL_URL="${API_BASE_URL:-}"
LARAVEL_KEY="${API_KEY:-}"

if [ -z "${LARAVEL_URL}" ]; then
    fail "API_BASE_URL not set – cannot test Laravel connectivity"
else
    info "Testing Laravel at: ${LARAVEL_URL}"

    # Public health endpoint (no auth)
    HTTP_CODE=$(curl -s -o /tmp/histo_health.json -w "%{http_code}" \
        --connect-timeout 10 --max-time 15 \
        "${LARAVEL_URL}/api/health" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        pass "GET /api/health  →  HTTP ${HTTP_CODE}"
        cat /tmp/histo_health.json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(f'  \033[0;36m[INFO]\033[0m  service={d.get(\"service\",\"?\")}  time={d.get(\"time\",\"?\")}')
except: pass"
    else
        fail "GET /api/health  →  HTTP ${HTTP_CODE}  (expected 200)"
    fi

    # Authenticated health endpoint
    if [ -n "${LARAVEL_KEY}" ]; then
        HTTP_CODE=$(curl -s -o /tmp/histo_auth.json -w "%{http_code}" \
            --connect-timeout 10 --max-time 15 \
            -H "Authorization: Bearer ${LARAVEL_KEY}" \
            -H "Accept: application/json" \
            "${LARAVEL_URL}/api/v1/health" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ]; then
            pass "GET /api/v1/health (authenticated)  →  HTTP ${HTTP_CODE}"
        elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
            fail "GET /api/v1/health  →  HTTP ${HTTP_CODE}  (wrong API_KEY)"
        else
            fail "GET /api/v1/health  →  HTTP ${HTTP_CODE}"
        fi
    else
        warn "API_KEY not set – skipping authenticated health check"
    fi
fi


# ─────────────────────────────────────────────────────────────────────────────
section "7. RUNPOD SERVER SELF-TEST  (/health endpoint)"
# ─────────────────────────────────────────────────────────────────────────────

SERVER_PORT="${PORT:-8000}"

# Check if server is already running
if curl -s --connect-timeout 3 "http://localhost:${SERVER_PORT}/health" &>/dev/null; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 "http://localhost:${SERVER_PORT}/health")
    if [ "$HTTP_CODE" = "200" ]; then
        pass "Server already running on :${SERVER_PORT} – /health → HTTP ${HTTP_CODE}"
    else
        warn "Server on :${SERVER_PORT} returned HTTP ${HTTP_CODE}"
    fi
else
    warn "Server not running on :${SERVER_PORT}"
    info "Start it with:  bash ${PROJECT_DIR}/scripts/start_server.sh"
    info "Or:  uvicorn app.server:app --host 0.0.0.0 --port 8000"

    # Try a quick syntax check of the app
    if [ -n "${PYTHON:-}" ]; then
        "${PYTHON}" -c "
import sys; sys.path.insert(0,'${PROJECT_DIR}')
try:
    import app.config, app.extractor, app.server, app.api_client, app.sync_google_drive
    print('  \033[0;32m[PASS]\033[0m  All app modules import without errors')
except Exception as e:
    print(f'  \033[0;31m[FAIL]\033[0m  Module import error: {e}')
    sys.exit(1)
" 2>&1
    fi
fi

# Public URL via RunPod proxy
if [ -n "${RUNPOD_POD_HOSTNAME:-}" ]; then
    PUBLIC_URL="https://${RUNPOD_POD_HOSTNAME}-${SERVER_PORT}.proxy.runpod.net"
    info "Expected public URL: ${PUBLIC_URL}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 --max-time 15 "${PUBLIC_URL}/health" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        pass "Public URL reachable: ${PUBLIC_URL}/health → HTTP ${HTTP_CODE}"
    else
        warn "Public URL check: HTTP ${HTTP_CODE}  (server may not be running yet)"
    fi
else
    warn "RUNPOD_POD_HOSTNAME not set – cannot derive public URL"
    info "After starting pod:  echo \$RUNPOD_POD_HOSTNAME"
fi


# ─────────────────────────────────────────────────────────────────────────────
section "8. MULTI-MODEL CONCURRENCY ASSESSMENT"
# ─────────────────────────────────────────────────────────────────────────────

if [ -n "${PYTHON:-}" ]; then
    "${PYTHON}" - <<'PYEOF'
import sys

RED    = "\033[0;31m"
GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
CYAN   = "\033[0;36m"
RESET  = "\033[0m"

try:
    import torch
    if not torch.cuda.is_available():
        print(f"  {RED}[FAIL]{RESET}  No CUDA – multi-model inference not possible on GPU")
        sys.exit(0)

    total_vram_gb = sum(
        torch.cuda.get_device_properties(i).total_memory
        for i in range(torch.cuda.device_count())
    ) / 1024**3

    # Model VRAM estimates (float16 inference)
    VIRCHOW2_VRAM  = 2.5   # ViT-H 632M params  ≈ 2.5 GB fp16
    TITAN_VRAM     = 3.5   # 1.1B params         ≈ 3.5 GB fp16
    OVERHEAD       = 2.0   # activation tensors, batch data, OS overhead

    print(f"  {CYAN}[INFO]{RESET}  Total GPU VRAM: {total_vram_gb:.1f} GB")
    print(f"  {CYAN}[INFO]{RESET}  Virchow2  estimated VRAM: {VIRCHOW2_VRAM} GB (fp16)")
    print(f"  {CYAN}[INFO]{RESET}  TITAN     estimated VRAM: {TITAN_VRAM} GB (fp16)")
    print(f"  {CYAN}[INFO]{RESET}  Overhead  (batches+OS):   {OVERHEAD} GB")

    single_vram = VIRCHOW2_VRAM + OVERHEAD
    dual_vram   = VIRCHOW2_VRAM + TITAN_VRAM + OVERHEAD

    if total_vram_gb >= dual_vram:
        print(f"  {GREEN}[PASS]{RESET}  Sufficient VRAM for BOTH Virchow2 + TITAN simultaneously "
              f"({dual_vram:.1f} GB needed, {total_vram_gb:.1f} GB available)")
    elif total_vram_gb >= single_vram:
        print(f"  {YELLOW}[WARN]{RESET}  Enough for ONE model at a time (single: {single_vram:.1f} GB needed)")
        print(f"  {YELLOW}[WARN]{RESET}  For simultaneous models, pod needs ≥ {dual_vram:.1f} GB VRAM")
    else:
        print(f"  {RED}[FAIL]{RESET}  Insufficient VRAM even for single model "
              f"({single_vram:.1f} GB needed, only {total_vram_gb:.1f} GB available)")

    # Architecture note
    print()
    print(f"  {CYAN}[INFO]{RESET}  Architecture: Each model runs in its own uvicorn process")
    print(f"  {CYAN}[INFO]{RESET}  Virchow2 → port 8000   (this server)")
    print(f"  {CYAN}[INFO]{RESET}  TITAN    → port 8001   (RunPood-TITAN server)")
    print(f"  {CYAN}[INFO]{RESET}  Laravel dispatches jobs to each server independently")
    print(f"  {CYAN}[INFO]{RESET}  Both share the same /workspace persistent volume")

except Exception as exc:
    print(f"  {RED}[FAIL]{RESET}  Assessment error: {exc}")
PYEOF
fi


# ─────────────────────────────────────────────────────────────────────────────
section "9. LARAVEL → RUNPOD INTEGRATION CHECK"
# ─────────────────────────────────────────────────────────────────────────────

if [ -n "${PYTHON:-}" ]; then
    "${PYTHON}" - <<PYEOF
import sys, os
sys.path.insert(0, '${PROJECT_DIR}')
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; RESET="\033[0m"

# Check that shared secret matches what the server will use
api_key = os.environ.get("RUNPOD_API_KEY","")
laravel_key = os.environ.get("API_KEY","")
base_url = os.environ.get("API_BASE_URL","")

if api_key:
    print(f"  {GREEN}[PASS]{RESET}  RUNPOD_API_KEY configured (server will use this for /jobs/start auth)")
else:
    print(f"  {RED}[FAIL]{RESET}  RUNPOD_API_KEY not set – server will reject ALL incoming jobs")

if laravel_key:
    print(f"  {GREEN}[PASS]{RESET}  API_KEY configured (used for callbacks to Laravel)")
else:
    print(f"  {RED}[FAIL]{RESET}  API_KEY not set – job status callbacks to Laravel will fail")

if base_url:
    print(f"  {GREEN}[PASS]{RESET}  API_BASE_URL = {base_url}")
else:
    print(f"  {RED}[FAIL]{RESET}  API_BASE_URL not set – callbacks will be skipped (jobs will still run)")

# Test APIClient import and instantiation
try:
    from app.api_client import APIClient
    client = APIClient(base_url or "http://localhost", laravel_key or "test", timeout=5)
    print(f"  {GREEN}[PASS]{RESET}  app.api_client.APIClient instantiated correctly")
except Exception as exc:
    print(f"  {RED}[FAIL]{RESET}  APIClient error: {exc}")

# Test config import
try:
    from app.config import JobConfig, EMBEDDING_DIM, MODEL_NAME
    print(f"  {GREEN}[PASS]{RESET}  app.config loaded: model={MODEL_NAME}, embedding_dim={EMBEDDING_DIM}")
except Exception as exc:
    print(f"  {RED}[FAIL]{RESET}  app.config import error: {exc}")
PYEOF
fi


# ─────────────────────────────────────────────────────────────────────────────
section "10. QUICK DRY-RUN  (model load test – no patches needed)"
# ─────────────────────────────────────────────────────────────────────────────

if [ -n "${PYTHON:-}" ] && [ -f "${MODEL_DIR}/model.safetensors" ]; then
    info "Attempting to load Virchow2 model (may take 30-60 seconds)..."
    timeout 120 "${PYTHON}" - <<'PYEOF'
import sys, os
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; RESET="\033[0m"

# ─── Authenticate with HuggingFace (required for gated model) ────────────────
hf_token = os.environ.get("HF_TOKEN", "")
if hf_token:
    try:
        from huggingface_hub import login
        login(token=hf_token, add_to_git_credential=False)
    except Exception as _e:
        print(f"  {YELLOW}[WARN]{RESET}  HF login: {_e}")
else:
    print(f"  {YELLOW}[WARN]{RESET}  HF_TOKEN not set – gated model may fail")

# ─── Enable offline mode if HF cache exists ──────────────────────────────────
workspace = os.environ.get("WORKSPACE_DIR", "/workspace/RunPod-Virchow2")
hf_cache = os.environ.get("HF_HUB_CACHE", f"{workspace}/models/cache/hub")
if os.path.exists(os.path.join(hf_cache, "models--paige-ai--Virchow2")):
    os.environ["HF_HUB_OFFLINE"] = "1"
    print(f"  {CYAN}[INFO]{RESET}  HF cache found – using offline mode")

try:
    import torch
    import timm
    from timm.layers import SwiGLUPacked
    from timm.data import resolve_data_config
    from timm.data.transforms_factory import create_transform

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"  {CYAN}[INFO]{RESET}  Loading on device: {device}")

    model = timm.create_model(
        "hf-hub:paige-ai/Virchow2",
        pretrained=True,
        mlp_layer=SwiGLUPacked,
        act_layer=torch.nn.SiLU,
    ).eval().to(device)

    transforms = create_transform(**resolve_data_config(model.pretrained_cfg, model=model))
    print(f"  {GREEN}[PASS]{RESET}  Virchow2 loaded successfully")

    # Quick forward pass with dummy data – mirrors extractor.py exactly
    dummy = torch.zeros(1, 3, 224, 224, device=device)
    with torch.inference_mode():
        out = model(dummy)   # (1, T, 1280) – full sequence (CLS + registers + patches)

    # Reproduce the extractor.py embedding: class_token ⊕ mean(rest) = 2560
    class_token  = out[:, 0]     # (1, 1280)
    patch_tokens = out[:, 1:]    # (1, T-1, 1280)
    embedding    = torch.cat([class_token, patch_tokens.mean(1)], dim=-1)  # (1, 2560)

    emb_dim = embedding.shape[-1]
    print(f"  {GREEN}[PASS]{RESET}  Forward pass OK – output embedding dim: {emb_dim}  (expected 2560)")
    if emb_dim == 2560:
        print(f"  {GREEN}[PASS]{RESET}  Embedding dimension is correct (2560)")
    else:
        print(f"  {RED}[FAIL]{RESET}  Unexpected embedding dim {emb_dim} (expected 2560)")

    # Report VRAM used
    if torch.cuda.is_available():
        used_gb = torch.cuda.memory_allocated() / 1024**3
        reserved_gb = torch.cuda.memory_reserved() / 1024**3
        print(f"  {CYAN}[INFO]{RESET}  GPU memory: allocated={used_gb:.2f} GB  reserved={reserved_gb:.2f} GB")

    del model; del transforms
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    print(f"  {GREEN}[PASS]{RESET}  Model unloaded and VRAM released")

except Exception as exc:
    import traceback
    print(f"  {RED}[FAIL]{RESET}  Model load error: {exc}")
    traceback.print_exc()
    sys.exit(1)
PYEOF
    DRY_STATUS=$?
    if [ $DRY_STATUS -ne 0 ]; then
        fail "Model dry-run failed – check HF_TOKEN and model files"
    fi
else
    if [ ! -f "${MODEL_DIR}/model.safetensors" ]; then
        warn "Skipping model dry-run – weights not downloaded yet"
        info "Run first:  bash ${PROJECT_DIR}/scripts/download_models.sh"
    fi
fi


# ─────────────────────────────────────────────────────────────────────────────
section "SUMMARY"
# ─────────────────────────────────────────────────────────────────────────────

printf "\n"
if [ "${CRITICAL_FAILURES}" -eq 0 ]; then
    printf "${GREEN}${BOLD}  ✓  All critical checks passed – system is ready for feature extraction!${RESET}\n\n"
    printf "  Next step:  bash ${PROJECT_DIR}/scripts/start_server.sh\n"
    printf "  Then update Laravel servers_names.api_url with:\n"
    printf "  https://\${RUNPOD_POD_HOSTNAME}-8000.proxy.runpod.net\n\n"
else
    printf "${RED}${BOLD}  ✗  ${CRITICAL_FAILURES} critical check(s) FAILED – fix issues above before dispatching jobs${RESET}\n\n"
    printf "  Quick-fix reference:\n"
    printf "    Missing model:   bash ${PROJECT_DIR}/scripts/download_models.sh\n"
    printf "    Missing packages: pip install -r ${PROJECT_DIR}/requirements.txt\n"
    printf "    Missing rclone:  curl https://rclone.org/install.sh | sudo bash\n"
    printf "    Missing env vars: source ${WORKSPACE_ROOT}/setup_env.sh\n\n"
    exit 1
fi
