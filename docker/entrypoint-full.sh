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
