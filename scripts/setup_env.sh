#!/usr/bin/env bash
# =============================================================================
# setup_env.sh  –  Environment bootstrap for RunPod Virchow2 pod
# =============================================================================
# Source this file ONCE at the start of every new pod session:
#
#   source /workspace/VIRCHOW2/scripts/setup_env.sh
#   # or (if stored at workspace root for TITAN compat):
#   source /workspace/setup_env.sh
#
# It sets every variable required by the Python pipeline, starts no processes.
# =============================================================================

# ─── Workspace layout ────────────────────────────────────────────────────────
# WORKSPACE_ROOT : the persistent network disk mounted at /workspace
# WORKSPACE_DIR  : the project directory (git repo lives here)
export WORKSPACE_ROOT="/workspace"
export WORKSPACE_DIR="${WORKSPACE_ROOT}/RunPod-Virchow2"
export HF_HOME="${WORKSPACE_DIR}/models/cache"
export HF_HUB_CACHE="${HF_HOME}/hub"
export TRANSFORMERS_CACHE="${HF_HOME}"
export PYTHONPATH="${WORKSPACE_DIR}"

# ─── Hugging Face (Virchow2 is a gated model) ────────────────────────────────
# Set HF_TOKEN before sourcing this file, or export it manually:
#   export HF_TOKEN="hf_..."
export HF_TOKEN="${HF_TOKEN:-}"

# ─── Laravel management API ───────────────────────────────────────────────────
# API_BASE_URL : URL of the Laravel management server
# API_KEY      : Bearer token that Laravel uses to authenticate callbacks
#                (matches servers_names.api_key for this RunPod server row)
export API_BASE_URL="${API_BASE_URL:-https://ai.histopathology.cloud}"
# Set API_KEY before sourcing this file, or export it manually:
#   export API_KEY="your-laravel-api-key"
export API_KEY="${API_KEY:-}"

# ─── Shared secret (RunPod server ↔ Laravel dispatcher) ──────────────────────
# RUNPOD_API_KEY is validated by /jobs/start on the FastAPI server.
# It must match the value in Laravel's servers_names.api_key for this pod row.
export RUNPOD_API_KEY="${API_KEY}"

# ─── Google Drive (rclone) ────────────────────────────────────────────────────
export RCLONE_REMOTE="gdrive"
export GDRIVE_INPUT_PATH="histo-pipeline/input/patches"
export GDRIVE_OUTPUT_PATH="histo-pipeline/output/features"

# ─── Extraction defaults (override per job if needed) ────────────────────────
export BATCH_SIZE="32"
export NUM_WORKERS="4"
export PATCH_SIZE_PX="256"
export MAGNIFICATION="20x"

# ─── Server defaults ──────────────────────────────────────────────────────────
export PORT="8000"
export HOST="0.0.0.0"

# ─── Restore rclone config from persistent volume ────────────────────────────
RCLONE_SRC="${WORKSPACE_DIR}/rclone.conf"
RCLONE_DST="${HOME:-/root}/.config/rclone/rclone.conf"
if [ -f "${RCLONE_SRC}" ] && [ ! -f "${RCLONE_DST}" ]; then
    mkdir -p "$(dirname "${RCLONE_DST}")"
    cp "${RCLONE_SRC}" "${RCLONE_DST}"
    echo "[setup_env] Restored rclone.conf from ${RCLONE_SRC}"
fi

# ─── Activate venv if present (packages persist on network disk) ─────────────
VENV_PYTHON="${WORKSPACE_DIR}/venv/bin/python"
if [ -x "${VENV_PYTHON}" ]; then
    source "${WORKSPACE_DIR}/venv/bin/activate"
    echo "[setup_env] venv activated: ${WORKSPACE_DIR}/venv"
else
    echo "[setup_env] WARN: venv not found – run first_run_setup.sh once"
fi

# ─── Warn about required secrets ─────────────────────────────────────────────
[ -z "${API_KEY}" ]         && echo "[setup_env] WARN: API_KEY not set – add it to RunPod template env vars"
[ -z "${HF_TOKEN}" ]        && echo "[setup_env] WARN: HF_TOKEN not set – add it to RunPod template env vars"

echo "[setup_env] Environment ready."
echo "  WORKSPACE_DIR   = ${WORKSPACE_DIR}"
echo "  API_BASE_URL    = ${API_BASE_URL}"
echo "  RCLONE_REMOTE   = ${RCLONE_REMOTE}"
echo "  HF_TOKEN        = ${HF_TOKEN:0:6}***"
echo ""
echo "  First time only: bash ${WORKSPACE_DIR}/scripts/first_run_setup.sh"
echo "  Run verification: bash ${WORKSPACE_DIR}/scripts/verify_full_system.sh"
echo "  Start server:     bash ${WORKSPACE_DIR}/scripts/start_server.sh"
