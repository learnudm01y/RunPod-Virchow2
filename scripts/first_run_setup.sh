#!/usr/bin/env bash
# =============================================================================
# first_run_setup.sh
# =============================================================================
# ONE-TIME setup script. Run this ONCE after cloning the repo to a new
# /workspace network disk. After this, every pod restart is instant:
#   1. source scripts/setup_env.sh   ← activates the persistent venv
#   2. bash scripts/start_server.sh  ← server is ready in seconds
#
# What this script does:
#   1. Creates a venv on /workspace (persists across pod stop/start)
#   2. Inherits system torch/torchvision (avoids 2+ GB re-download)
#   3. Installs all other required packages into the venv
#   4. Saves rclone.conf to /workspace for auto-restore on future pods
#   5. Moves model weights to correct location if needed
#   6. Creates required directories
#   7. Writes a marker file so you can verify this was run
#
# Usage:
#   source /workspace/RunPod-Virchow2/scripts/setup_env.sh
#   bash /workspace/RunPod-Virchow2/scripts/first_run_setup.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

step() { printf "\n${BOLD}${CYAN}▶ %s${RESET}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${RESET}  %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET}  %s\n" "$*"; }
die()  { printf "  ${RED}✗${RESET}  %s\n" "$*"; exit 1; }

PROJECT_DIR="${WORKSPACE_DIR:-/workspace/RunPod-Virchow2}"
VENV_DIR="${PROJECT_DIR}/venv"
MODEL_DIR="${PROJECT_DIR}/models/virchow2"
OLD_MODEL_DIR="/workspace/VIRCHOW2/models/virchow2"
RCLONE_CONF_SYSTEM="${HOME:-/root}/.config/rclone/rclone.conf"
RCLONE_CONF_PERSIST="${PROJECT_DIR}/rclone.conf"
MARKER="${PROJECT_DIR}/.first_run_complete"

printf "\n${BOLD}First-Run Persistent Setup${RESET}\n"
printf "Project : ${PROJECT_DIR}\n"
printf "venv    : ${VENV_DIR}\n\n"

# Guard: warn if already run
if [ -f "${MARKER}" ]; then
    warn "first_run_setup.sh was already run on $(cat "${MARKER}")"
    warn "Delete ${MARKER} to force re-run."
    printf "\n  If packages are missing, run:\n"
    printf "  ${CYAN}${VENV_DIR}/bin/pip install -r ${PROJECT_DIR}/requirements.txt${RESET}\n\n"
    exit 0
fi

# ─── 1. Verify project directory ─────────────────────────────────────────────
step "Verifying project directory"
[ -d "${PROJECT_DIR}/app" ]         || die "app/ missing – is the repo cloned to ${PROJECT_DIR}?"
[ -f "${PROJECT_DIR}/requirements.txt" ] || die "requirements.txt missing"
ok "Project directory OK"

# ─── 2. Create dirs ───────────────────────────────────────────────────────────
step "Creating required directories"
for d in \
    "${PROJECT_DIR}/models/virchow2" \
    "${PROJECT_DIR}/models/cache/hub" \
    "${PROJECT_DIR}/input/patches" \
    "${PROJECT_DIR}/input/metadata" \
    "${PROJECT_DIR}/output/features" \
    "${PROJECT_DIR}/output/logs" \
    "${PROJECT_DIR}/output/manifests" \
    "${PROJECT_DIR}/logs"
do
    mkdir -p "$d"
    ok "$d"
done

# ─── 3. Move models if in old location ───────────────────────────────────────
step "Checking model weights location"
if [ -d "${OLD_MODEL_DIR}" ] && [ ! -f "${MODEL_DIR}/model.safetensors" ]; then
    warn "Models found at old location: ${OLD_MODEL_DIR}"
    warn "Moving to: ${MODEL_DIR}"
    mv "${OLD_MODEL_DIR}"/* "${MODEL_DIR}/"
    ok "Models moved to ${MODEL_DIR}"
elif [ -f "${MODEL_DIR}/model.safetensors" ]; then
    sz=$(du -sh "${MODEL_DIR}/model.safetensors" 2>/dev/null | awk '{print $1}')
    ok "Virchow2 weights already at correct location (${sz})"
else
    warn "model.safetensors not found – will need to run download_models.sh"
    warn "bash ${PROJECT_DIR}/scripts/download_models.sh"
fi

# ─── 4. Create venv with system-site-packages ────────────────────────────────
step "Creating persistent venv (inherits system torch)"

# Check if system torch is available
SYS_TORCH=$(python3 -c "import torch; print(torch.__version__)" 2>/dev/null || echo "")
if [ -n "${SYS_TORCH}" ]; then
    ok "System torch detected: ${SYS_TORCH}"
    ok "Using --system-site-packages (avoids re-downloading 2+ GB torch)"
    python3 -m venv --system-site-packages "${VENV_DIR}"
else
    warn "System torch not found – creating standard venv (torch will be installed)"
    python3 -m venv "${VENV_DIR}"
fi

ok "venv created at ${VENV_DIR}"

# ─── 5. Install packages ──────────────────────────────────────────────────────
step "Installing Python packages into venv"
"${VENV_DIR}/bin/pip" install --upgrade pip --quiet

# Check which packages are already available (from system-site-packages)
MISSING_PKGS=""
for pkg in transformers huggingface_hub timm einops h5py tqdm httpx fastapi uvicorn pydantic; do
    if ! "${VENV_DIR}/bin/python" -c "import ${pkg//-/_}" 2>/dev/null; then
        MISSING_PKGS="${MISSING_PKGS} ${pkg}"
    fi
done

if [ -n "${MISSING_PKGS}" ]; then
    warn "Installing missing packages:${MISSING_PKGS}"
    "${VENV_DIR}/bin/pip" install \
        "transformers>=4.40.0" \
        "huggingface_hub>=0.22.0" \
        "timm>=0.9.16" \
        "einops>=0.7.0" \
        "einops-exts>=0.0.4" \
        "h5py>=3.10.0" \
        "tqdm>=4.66.0" \
        "httpx>=0.27.0" \
        "fastapi>=0.110.0" \
        "uvicorn[standard]>=0.27.0" \
        "pydantic>=2.6.0" \
        --quiet
    ok "Packages installed"
else
    ok "All packages already available via system-site-packages"
fi

# Verify key imports
"${VENV_DIR}/bin/python" -c "
import timm, fastapi, uvicorn, httpx, h5py
print('  \033[0;32m✓\033[0m  All critical packages verified')
" || die "Package verification failed – check pip output above"

# ─── 6. Save rclone.conf to persistent storage ───────────────────────────────
step "Persisting rclone.conf"
if [ -f "${RCLONE_CONF_SYSTEM}" ]; then
    if [ ! -f "${RCLONE_CONF_PERSIST}" ]; then
        cp "${RCLONE_CONF_SYSTEM}" "${RCLONE_CONF_PERSIST}"
        ok "rclone.conf saved to ${RCLONE_CONF_PERSIST}"
    else
        ok "rclone.conf already persisted at ${RCLONE_CONF_PERSIST}"
    fi
else
    warn "rclone.conf not found at ${RCLONE_CONF_SYSTEM}"
    warn "Google Drive sync will NOT work until rclone is configured"
    warn "Run: rclone config  →  then re-run this script"
fi

# ─── 7. Write completion marker ───────────────────────────────────────────────
date -u +'%Y-%m-%dT%H:%M:%SZ' > "${MARKER}"
ok "Marker written: ${MARKER}"

# ─── Done ─────────────────────────────────────────────────────────────────────
printf "\n${GREEN}${BOLD}══════════════════════════════════════════════════${RESET}\n"
printf "${GREEN}${BOLD}  ✓  First-run setup complete!${RESET}\n"
printf "${GREEN}${BOLD}══════════════════════════════════════════════════${RESET}\n\n"
printf "  From now on, every pod restart:\n\n"
printf "  ${CYAN}source /workspace/RunPod-Virchow2/scripts/setup_env.sh${RESET}\n"
printf "  ${CYAN}bash /workspace/RunPod-Virchow2/scripts/start_server.sh${RESET}\n\n"
printf "  Verify everything is OK:\n"
printf "  ${CYAN}bash /workspace/RunPod-Virchow2/scripts/verify_full_system.sh${RESET}\n\n"
