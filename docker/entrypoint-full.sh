#!/usr/bin/env bash
# NOTE: Must use LF endings. This script orchestrates starting the Python backend then the Node proxy.
set -Eeuo pipefail
trap 'code=$?; echo "[entrypoint] ERROR (exit $code) at line $LINENO" >&2; exit $code' ERR

BACKEND_DIR=/app/py
SERVER_DIR=/app/server
BACKEND_HEALTH_TIMEOUT="${BACKEND_START_TIMEOUT:-180}" # seconds (can adjust via env)
HEALTH_CANDIDATES="${BACKEND_HEALTH_PATH:-/health} /api/backend/health"
BACKEND_CMD="${BACKEND_START_CMD:-python app.py}"

echo "[entrypoint] runtime versions:"
python -c 'import sys;print("  python",sys.version.split()[0])'
if command -v node >/dev/null 2>&1; then node -v || true; else echo "  node: <missing>"; fi

echo "[entrypoint] starting python backend: $BACKEND_CMD"
cd "$BACKEND_DIR"
sh -c "$BACKEND_CMD" &
BACK_PID=$!
cd - >/dev/null 2>&1 || true

if [ "${SKIP_BACKEND_WAIT:-0}" = "1" ]; then
  echo "[entrypoint] SKIP_BACKEND_WAIT=1 -> skipping health wait"
  HEALTH_READY=1
fi

if [ -z "${HEALTH_READY:-}" ]; then
  echo "[entrypoint] waiting for backend health (timeout=${BACKEND_HEALTH_TIMEOUT}s)..."
  for ((i=1;i<=BACKEND_HEALTH_TIMEOUT;i++)); do
    for p in $HEALTH_CANDIDATES; do
      if curl -fsS "http://127.0.0.1:5001$p" >/dev/null 2>&1; then
        echo "[entrypoint] backend healthy via path $p"
        CKPT_PATH="${SAM_CHECKPOINT:-models/sam_vit_b.pth}"
        case "$CKPT_PATH" in
          /*) CHECK_ABS="$CKPT_PATH" ;;
          *)  CHECK_ABS="/app/py/$CKPT_PATH" ;;
        esac
        if [ -f "$CHECK_ABS" ]; then
          echo "[entrypoint] SAM checkpoint present at $CHECK_ABS"
        else
          ALT="/app/$CKPT_PATH"
          if [ -f "$ALT" ]; then
            echo "[entrypoint] SAM checkpoint found at $ALT (consider relocating to /app/py/models)"
          else
            echo "[entrypoint] SAM checkpoint NOT found (expected $CHECK_ABS). If using S3 auto-fetch ensure MODELS_BUCKET + SAM_CHECKPOINT_KEY are set or mount -v $(pwd)/models:/app/py/models:ro"
          fi
        fi
        HEALTH_READY=1
        break 2
      fi
    done
    if ! kill -0 "$BACK_PID" 2>/dev/null; then
      echo "[entrypoint] backend process exited prematurely" >&2
      wait "$BACK_PID" || true
      exit 1
    fi
    sleep 1
  done
fi

if [ -z "${HEALTH_READY:-}" ]; then
  echo "[entrypoint] Backend failed to become healthy after ${BACKEND_HEALTH_TIMEOUT}s" >&2
  exit 1
fi

echo "[entrypoint] environment summary: WARM_MODEL=${WARM_MODEL:-unset} SAM_MODEL_TYPE=${SAM_MODEL_TYPE:-unset} MODELS_BUCKET=${MODELS_BUCKET:-unset} SAM_CHECKPOINT_KEY=${SAM_CHECKPOINT_KEY:-unset} SAM_CHECKPOINT=${SAM_CHECKPOINT:-unset}"

cd "$SERVER_DIR"
echo "[entrypoint] starting node proxy on :${PORT:-3000}..."
exec node server.js
