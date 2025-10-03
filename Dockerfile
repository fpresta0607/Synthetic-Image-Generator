## syntax=docker/dockerfile:1.6
# Multi-stage build for SAM Bulk Dataset Generator
# Targets:
#  - backend: Python Flask + SAM
#  - node: Node proxy / static UI
#  - worker: Queue consumer (re-uses backend layer)
#  - full: Combined process supervisor (optional)

############################
# Base Python stage
############################
FROM python:3.11-slim AS python-base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# System deps (git for segment-anything, build essentials for some wheels)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl build-essential ca-certificates && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY py/requirements-sam.txt py/requirements.txt ./py/

# Harden pip installation + enable pip cache mount (accelerates rebuilds)
ENV PIP_DEFAULT_TIMEOUT=120 \
    PIP_RETRIES=5

# Install Python deps first (cached until requirements change)
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install --upgrade pip==24.2 setuptools wheel && \
    pip install -r py/requirements-sam.txt

# Copy application code
COPY py /app/py

# Create models dir (weights can be mounted)
RUN mkdir -p /app/py/models

ENV FLASK_PORT=5001 \
    FLASK_HOST=0.0.0.0

EXPOSE 5001

############################
# Backend runnable image
############################
FROM python-base AS backend
# Install runtime server libs (cached)
RUN --mount=type=cache,target=/root/.cache/pip pip install gunicorn waitress
WORKDIR /app/py
# Entrypoint: prefer app bootstrap (includes warm logic); fallback to gunicorn if env USE_GUNICORN=1
COPY py/app.py /app/py/app.py
ENTRYPOINT ["bash","-c","if [ \"$USE_GUNICORN\" = '1' ]; then gunicorn -w ${GUNICORN_WORKERS:-1} -b 0.0.0.0:5001 app:app; else python app.py; fi"]

############################
# Node stage
############################
FROM node:20-slim AS node
WORKDIR /app/server
# Copy manifests first for dependency layer caching
COPY server/package*.json ./
RUN --mount=type=cache,target=/root/.npm npm install --omit=dev --no-audit --no-fund
# Then copy remaining server code
COPY server /app/server
ENV PORT=3000 PY_SERVICE_URL=http://localhost:5001
EXPOSE 3000
CMD ["node","server.js"]

############################
# Combined image (backend + node via lightweight process manager)
############################
FROM python-base AS full
# Install node (using apt) for simplicity
RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm && rm -rf /var/lib/apt/lists/*
RUN --mount=type=cache,target=/root/.cache/pip pip install gunicorn waitress
WORKDIR /app
COPY --from=node /app/server /app/server
RUN cd server && npm install --production --no-audit --no-fund
# Copy backend code & deps already in base
ENV PORT=3000 PY_SERVICE_URL=http://127.0.0.1:5001
EXPOSE 3000 5001
# Simple start script launches Python then Node
COPY docker/entrypoint-full.sh /entrypoint-full.sh
RUN chmod +x /entrypoint-full.sh
ENTRYPOINT ["/entrypoint-full.sh"]

############################
# Worker stage (SQS consumer)
############################
FROM python-base AS worker
# boto3 + requests for S3/SQS/DDB + internal calls
RUN --mount=type=cache,target=/root/.cache/pip pip install boto3 requests
COPY py/worker /app/py/worker
WORKDIR /app/py/worker
ENV AWS_REGION=us-east-1 \
    DATASETS_BUCKET=unset \
    OUTPUTS_BUCKET=unset \
    MODELS_BUCKET=unset \
    JOBS_TABLE=sam_jobs \
    JOBS_QUEUE_URL=unset \
    SAM_CHECKPOINT=/app/py/models/sam_vit_b.pth
ENTRYPOINT ["python","consumer.py"]

# Usage:
#   Backend only: docker build -t sam-backend --target backend .
#   Node only:    docker build -t sam-node --target node .
#   Combined:     docker build -t sam-full --target full .
#   Worker:       docker build -t sam-worker --target worker .
# Mount weights:  docker run -v /host/models:/app/py/models sam-backend
