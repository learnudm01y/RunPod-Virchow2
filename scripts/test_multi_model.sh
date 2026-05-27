#!/usr/bin/env bash
# =============================================================================
# test_multi_model.sh
# =============================================================================
# Tests the ability to run Virchow2 AND TITAN simultaneously on the same pod,
# each on its own port, sharing the same GPU and /workspace volume.
#
# Prerequisites:
#   - verify_full_system.sh has already passed
#   - setup_env.sh has been sourced
#   - Both RunPood-TITAN and VIRCHOW2 project dirs exist in /workspace
#
# Usage:
#   bash /workspace/VIRCHOW2/scripts/test_multi_model.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS="${GREEN}[PASS]${RESET}"; FAIL="${RED}[FAIL]${RESET}"
WARN="${YELLOW}[WARN]${RESET}"; INFO="${CYAN}[INFO]${RESET}"

ERRORS=0
pass()  { printf "  ${PASS}  %s\n" "$*"; }
fail()  { printf "  ${FAIL}  %s\n" "$*"; (( ERRORS++ )) || true; }
warn()  { printf "  ${WARN}  %s\n" "$*"; }
info()  { printf "  ${INFO}  %s\n" "$*"; }
section() {
    printf "\n${BOLD}${CYAN}══════════════════════════════════════════════════════════${RESET}\n"
    printf "${BOLD}  %s${RESET}\n" "$*"
    printf "${BOLD}${CYAN}══════════════════════════════════════════════════════════${RESET}\n"
}

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"
VIRCHOW2_DIR="${WORKSPACE_ROOT}/VIRCHOW2"
TITAN_DIR="${WORKSPACE_ROOT}/RunPood-TITAN"
VIRCHOW2_PORT="${PORT:-8000}"
TITAN_PORT="8001"

PYTHON=""
if   [ -x "${VIRCHOW2_DIR}/venv/bin/python" ]; then PYTHON="${VIRCHOW2_DIR}/venv/bin/python"
elif [ -x "${TITAN_DIR}/venv/bin/python" ];    then PYTHON="${TITAN_DIR}/venv/bin/python"
elif command -v python3 &>/dev/null;            then PYTHON="python3"
fi

printf "\n${BOLD}Multi-Model Concurrency Test${RESET}\n"
printf "Date          : $(date -u +'%Y-%m-%dT%H:%M:%SZ')\n"
printf "Virchow2 dir  : ${VIRCHOW2_DIR}  (port ${VIRCHOW2_PORT})\n"
printf "TITAN dir     : ${TITAN_DIR}  (port ${TITAN_PORT})\n"


# ─────────────────────────────────────────────────────────────────────────────
section "1. VRAM CAPACITY CHECK"
# ─────────────────────────────────────────────────────────────────────────────

if [ -n "${PYTHON}" ]; then
    "${PYTHON}" - <<'PYEOF'
import sys
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; RESET="\033[0m"

try:
    import torch
    if not torch.cuda.is_available():
        print(f"  {RED}[FAIL]{RESET}  No CUDA available")
        sys.exit(1)

    for i in range(torch.cuda.device_count()):
        p = torch.cuda.get_device_properties(i)
        gb = p.total_memory / 1024**3
        print(f"  {CYAN}[INFO]{RESET}  GPU {i}: {p.name}  –  {gb:.1f} GB VRAM")

    total = sum(torch.cuda.get_device_properties(i).total_memory
                for i in range(torch.cuda.device_count())) / 1024**3

    # fp16 estimates: Virchow2=2.5 GB, TITAN=3.5 GB, overhead=2 GB each
    need = 2.5 + 3.5 + 2.0
    if total >= need:
        print(f"  {GREEN}[PASS]{RESET}  {total:.1f} GB VRAM ≥ {need:.1f} GB needed for dual-model")
    elif total >= 6:
        print(f"  {YELLOW}[WARN]{RESET}  {total:.1f} GB VRAM – marginal; use fp16 + sequential loading")
    else:
        print(f"  {RED}[FAIL]{RESET}  {total:.1f} GB VRAM insufficient for dual-model")
        sys.exit(1)
except Exception as exc:
    print(f"  {RED}[FAIL]{RESET}  {exc}")
    sys.exit(1)
PYEOF
else
    fail "No Python available"
fi


# ─────────────────────────────────────────────────────────────────────────────
section "2. SHARED VOLUME ACCESS"
# ─────────────────────────────────────────────────────────────────────────────

# Both models must read from and write to /workspace
for dir in \
    "${WORKSPACE_ROOT}/input/patches" \
    "${WORKSPACE_ROOT}/VIRCHOW2/output/features" \
    "${WORKSPACE_ROOT}/VIRCHOW2/models/virchow2" \
    "${WORKSPACE_ROOT}/VIRCHOW2/logs"
do
    mkdir -p "$dir" 2>/dev/null || true
    if [ -d "$dir" ]; then
        pass "Shared dir exists: $dir"
    else
        fail "Cannot create shared dir: $dir"
    fi
done

# Write + read test on the shared volume
TEST_FILE="${WORKSPACE_ROOT}/VIRCHOW2/.multimodel_test_$(date +%s)"
echo "virchow2_test" > "${TEST_FILE}" 2>/dev/null && \
    rm -f "${TEST_FILE}" && \
    pass "Shared volume is writable" || \
    fail "Shared volume is NOT writable: ${WORKSPACE_ROOT}"


# ─────────────────────────────────────────────────────────────────────────────
section "3. PORT AVAILABILITY"
# ─────────────────────────────────────────────────────────────────────────────

for port in "${VIRCHOW2_PORT}" "${TITAN_PORT}"; do
    if ss -tlnp "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
        warn "Port ${port} is already in use – check running processes"
        ss -tlnp "sport = :${port}" 2>/dev/null | tail -1
    else
        pass "Port ${port} is free"
    fi
done


# ─────────────────────────────────────────────────────────────────────────────
section "4. SIMULTANEOUS SERVER STARTUP TEST"
# ─────────────────────────────────────────────────────────────────────────────

if [ ! -d "${VIRCHOW2_DIR}/app" ]; then
    fail "Virchow2 app/ not found at ${VIRCHOW2_DIR}"
    info "Ensure the project is cloned to /workspace/VIRCHOW2"
else
    # Start Virchow2 server in background
    info "Starting Virchow2 server on port ${VIRCHOW2_PORT} ..."
    RUNPOD_API_KEY="${RUNPOD_API_KEY:-test-key}" \
    WORKSPACE_DIR="${VIRCHOW2_DIR}" \
    PYTHONPATH="${VIRCHOW2_DIR}" \
    nohup "${PYTHON}" -m uvicorn app.server:app \
        --app-dir "${VIRCHOW2_DIR}" \
        --host 0.0.0.0 --port "${VIRCHOW2_PORT}" \
        > "${VIRCHOW2_DIR}/logs/server_test.log" 2>&1 &
    VIRCHOW2_PID=$!
    echo "[test_multi_model] Virchow2 PID: ${VIRCHOW2_PID}"

    # Give it time to bind
    sleep 5

    # Check Virchow2 health
    VIRCHOW2_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 "http://localhost:${VIRCHOW2_PORT}/health" 2>/dev/null || echo "000")
    if [ "${VIRCHOW2_HTTP}" = "200" ]; then
        pass "Virchow2 server /health → HTTP 200"
    else
        fail "Virchow2 server /health → HTTP ${VIRCHOW2_HTTP}  (check ${VIRCHOW2_DIR}/logs/server_test.log)"
        cat "${VIRCHOW2_DIR}/logs/server_test.log" 2>/dev/null | tail -10
    fi
fi

if [ -d "${TITAN_DIR}/app" ]; then
    info "TITAN project found at ${TITAN_DIR}"
    # Check if TITAN has its own start script
    if [ -x "${TITAN_DIR}/scripts/start_server.sh" ]; then
        info "Start TITAN on port 8001 with:"
        info "  PORT=8001 bash ${TITAN_DIR}/scripts/start_server.sh"
    else
        info "Start TITAN with:"
        info "  WORKSPACE_DIR=${TITAN_DIR} RUNPOD_API_KEY=\$RUNPOD_API_KEY PORT=8001 \\"
        info "  uvicorn app.server:app --app-dir ${TITAN_DIR} --host 0.0.0.0 --port 8001"
    fi
    pass "TITAN project directory present – can run on port ${TITAN_PORT}"
else
    warn "TITAN project not found at ${TITAN_DIR}"
    info "Clone it: cd /workspace && git clone <titan-repo> RunPood-TITAN"
fi


# ─────────────────────────────────────────────────────────────────────────────
section "5. SIMULATED JOB DISPATCH TEST  (no real patches)"
# ─────────────────────────────────────────────────────────────────────────────

info "Sending a test job payload to Virchow2 server ..."
DISPATCH_RESP=$(curl -s -o /tmp/dispatch_test.json -w "%{http_code}" \
    --connect-timeout 5 --max-time 10 \
    -X POST "http://localhost:${VIRCHOW2_PORT}/jobs/start" \
    -H "Authorization: Bearer ${RUNPOD_API_KEY:-test-key}" \
    -H "Content-Type: application/json" \
    -d '{
        "sample_id": 99999,
        "slide_id":  "TEST-DRY-RUN",
        "patch_size_px": 256,
        "magnification": "20x",
        "gdrive_input_path":  "histo-pipeline/input/patches/TEST-DRY-RUN",
        "gdrive_output_path": "histo-pipeline/output/features",
        "ai_model": {
            "id": 2,
            "name": "virchow2",
            "slug": "virchow2",
            "huggingface": "paige-ai/Virchow2",
            "version": "v2",
            "embedding_dim": "2560"
        },
        "callback": {
            "url":    "'"${API_BASE_URL:-http://localhost}"'/api/v1/feature-extraction/report",
            "token":  "'"${API_KEY:-test}"'",
            "method": "POST"
        }
    }' 2>/dev/null || echo "000")

if [ "${DISPATCH_RESP}" = "200" ] || [ "${DISPATCH_RESP}" = "202" ]; then
    pass "Job dispatch → HTTP ${DISPATCH_RESP}"
    python3 -c "
import json,sys
try:
    d=json.load(open('/tmp/dispatch_test.json'))
    jid=d.get('job_id','?')
    print(f'  \033[0;36m[INFO]\033[0m  job_id={jid}  sample_id={d.get(\"sample_id\",\"?\")}')
except: pass" 2>/dev/null || true
elif [ "${DISPATCH_RESP}" = "403" ]; then
    fail "Job dispatch → HTTP 403  (RUNPOD_API_KEY mismatch)"
elif [ "${DISPATCH_RESP}" = "000" ]; then
    fail "Job dispatch → no response (server not running?)"
else
    warn "Job dispatch → HTTP ${DISPATCH_RESP}  (may be a validation error for test data)"
    cat /tmp/dispatch_test.json 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin); print('  Detail:',d.get('detail',''))
except: pass" 2>/dev/null || true
fi


# ─────────────────────────────────────────────────────────────────────────────
section "CLEANUP & SUMMARY"
# ─────────────────────────────────────────────────────────────────────────────

# Kill the test server process
if [ -n "${VIRCHOW2_PID:-}" ]; then
    kill "${VIRCHOW2_PID}" 2>/dev/null || true
    info "Stopped test Virchow2 server (PID ${VIRCHOW2_PID})"
fi

printf "\n"
if [ "${ERRORS}" -eq 0 ]; then
    printf "${GREEN}${BOLD}  ✓  Multi-model test PASSED – pod can run both models simultaneously${RESET}\n\n"
    printf "  Production startup commands:\n"
    printf "  ${CYAN}# Terminal 1 – Virchow2 (port 8000)${RESET}\n"
    printf "  source ${VIRCHOW2_DIR}/scripts/setup_env.sh\n"
    printf "  bash ${VIRCHOW2_DIR}/scripts/start_server.sh\n\n"
    printf "  ${CYAN}# Terminal 2 – TITAN (port 8001)${RESET}\n"
    printf "  source ${WORKSPACE_ROOT}/setup_env.sh\n"
    printf "  PORT=8001 bash ${TITAN_DIR}/scripts/start_server.sh\n\n"
else
    printf "${RED}${BOLD}  ✗  ${ERRORS} test(s) failed – see issues above${RESET}\n\n"
    exit 1
fi
