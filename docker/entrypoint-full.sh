#!/usr/bin/env bash
set -euo pipefail

# Start backend
(
  cd /app/py
  echo "[entrypoint] starting python backend..."
  python app.py &
)

# Wait for backend health
echo "[entrypoint] waiting for backend health..."
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:5001/health >/dev/null 2>&1; then
    echo "[entrypoint] backend healthy"

    # Log checkpoint situation (helps diagnose missing model in container)
    CKPT_PATH="${SAM_CHECKPOINT:-models/sam_vit_b.pth}"
    if [ -f "/app/py/$CKPT_PATH" ]; then
      echo "[entrypoint] SAM checkpoint present at /app/py/$CKPT_PATH"
    else
      if [ -f "/app/$CKPT_PATH" ]; then
        echo "[entrypoint] SAM checkpoint found at /app/$CKPT_PATH (consider using /app/py/models)"
      else
        echo "[entrypoint] SAM checkpoint NOT found (expected /app/py/$CKPT_PATH). If using S3 auto-fetch ensure MODELS_BUCKET + SAM_CHECKPOINT_KEY env vars are set or mount a volume: -v $(pwd)/models:/app/py/models:ro"
      fi
    fi
    break
  fi
  sleep 1
  if [ "$i" = "60" ]; then
    echo "Backend failed to become healthy" >&2
    exit 1
  fi
done

# Start node proxy
cd /app/server
echo "[entrypoint] starting node proxy..."
node server.js
