#!/usr/bin/env bash
set -euo pipefail

# Start backend
(
  cd /app/py
  echo "[entrypoint] starting python backend..."
  python app.py &
)

# Wait for backend health (probe both /health and /api/backend/health)
echo "[entrypoint] waiting for backend health..."
HEALTH_CANDIDATES="${BACKEND_HEALTH_PATH:-/health} /api/backend/health"
for i in $(seq 1 60); do
  for p in $HEALTH_CANDIDATES; do
    if curl -fsS "http://127.0.0.1:5001$p" >/dev/null 2>&1; then
      echo "[entrypoint] backend healthy via path $p"
      CKPT_PATH="${SAM_CHECKPOINT:-models/sam_vit_b.pth}"
      # Normalize absolute vs relative path; only prepend /app/py if relative
      case "$CKPT_PATH" in
        /*) CHECK_ABS="$CKPT_PATH" ;;
        *) CHECK_ABS="/app/py/$CKPT_PATH" ;;
      esac
      if [ -f "$CHECK_ABS" ]; then
        echo "[entrypoint] SAM checkpoint present at $CHECK_ABS"
      else
        # Secondary legacy location check
        ALT="/app/$CKPT_PATH"
        if [ -f "$ALT" ]; then
          echo "[entrypoint] SAM checkpoint found at $ALT (consider relocating to /app/py/models)"
        else
          echo "[entrypoint] SAM checkpoint NOT found (expected $CHECK_ABS). If using S3 auto-fetch ensure MODELS_BUCKET + SAM_CHECKPOINT_KEY are set or mount: -v $(pwd)/models:/app/py/models:ro"
        fi
      fi
      HEALTH_READY=1
      break 2
    fi
  done
  sleep 1
done

if [ -z "${HEALTH_READY:-}" ]; then
  echo "[entrypoint] Backend failed to become healthy after 60s" >&2
  exit 1
fi

echo "[entrypoint] environment summary: WARM_MODEL=${WARM_MODEL:-unset} SAM_MODEL_TYPE=${SAM_MODEL_TYPE:-unset} MODELS_BUCKET=${MODELS_BUCKET:-unset} SAM_CHECKPOINT_KEY=${SAM_CHECKPOINT_KEY:-unset} SAM_CHECKPOINT=${SAM_CHECKPOINT:-unset}" 

# Start node proxy
cd /app/server
echo "[entrypoint] starting node proxy on :${PORT:-3000}..."
node server.js
