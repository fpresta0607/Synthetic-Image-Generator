# SAM Bulk Dataset Generator

This project provides a **dataset-driven bulk image generation workflow** powered by Segment Anything (SAM). Upload multiple images, define reusable templates with point prompts, configure qualitative edits per template, and stream-generate variants for your entire dataset.

**Key Features:**
- Upload datasets of multiple images (batch initialization)
- Define 1+ templates using reference images + point prompts (positive/negative)
- Apply per-template edits (brightness, contrast, gamma, hue, saturation, sharpen, noise, opacity)
- Stream-generate variants for all dataset images using saved templates
- Download all results as a ZIP archive (client-side bundling with JSZip)

**Legacy Note:** Single-image interactive segmentation (upload → point prompts → save component → edit) has been **replaced** by the dataset/template workflow. For legacy single-image usage, check the `script.js.bak` backup.

## Architecture

1. **Python Flask Service** (`py/app.py`): Hosts SAM endpoints for:
   - Dataset initialization (`/sam/dataset/init`)
   - Template saving (`/sam/dataset/template/save`)
   - Template listing (`/sam/dataset/templates`)
   - Streaming variant generation (`/sam/dataset/apply_stream`)
   - Legacy single-image endpoints (init, segment, save_component, components, apply) – *now deprecated*
   - Simple batch processing (`/sam/batch_process`, `/sam/batch_process_stream`) – *deprecated in favor of dataset workflow*

2. **Node/Express Proxy** (`server/server.js`): Serves static UI and forwards `/api/sam/*` calls to Python backend.

3. **Front-End** (`server/public/`): Dataset workflow UI with three steps:
   - **Step 1:** Upload dataset (multiple images)
   - **Step 2:** Capture templates (select reference images, add point prompts, save)
   - **Step 3:** Configure edits per template, generate all variants, download ZIP

## Color & Edit Semantics
- `brightness`: additive in normalized [0,1] range (value added per channel).
- `contrast`: scales around 0.5 (`(x-0.5)*(1+contrast)+0.5`).
- `gamma`: interpreted as delta; applied as `output = input ** (1/(1+gamma))`.
- `hue`: degrees shift (wrapped), only if source not grayscale.
- `saturation`: multiplicative delta (`1 + saturation` scale), only if source not grayscale.
- Edits are applied per component id. If no components are found, operations apply over the full object mask.
- Pixels outside the main object mask are never altered.

## Requirements
Python service dependencies pinned in `py/requirements.txt`.
Node dependencies listed in `server/package.json`.

### Model Weights / `models/` Directory
The `py/models` (or top-level `models`) directory is ignored by git (large files). You must manually place a SAM checkpoint there before running in production:

```
py/models/sam_vit_b.pth
```

Or set an explicit environment variable:

```
SAM_CHECKPOINT=/absolute/path/to/sam_vit_b.pth
```

If the checkpoint is missing the backend will load but `/sam/init` will respond with an error until the file is present.

## Quick Start (Cross-Platform)

### Recommended: Universal dev script
The `dev` script (`server/scripts/dev.mjs`) will:
1. Create `py/.venv` if missing
2. Install Python dependencies (prefers `requirements-sam.txt`, falls back to `requirements.txt`)
3. Start the Flask SAM backend
4. Start the Node proxy

```bash
cd server
npm install
npm run dev
```

On Windows PowerShell the above also works (Node handles process spawning). If you prefer a pure PowerShell flow with visible separate windows you can still use:

```powershell
cd server
npm install
npm run dev:win
```

Then open: **http://localhost:3000**

### Dataset Workflow Usage
1. **Upload Dataset**: Select 5–100 images (JPG/PNG) and click "Initialize Dataset"
2. **Capture Templates**: 
   - Click a reference image from the gallery
   - Add positive points (left click) and negative points (right/Shift+click) to define the region
   - Optionally name the template
   - Click "Save Template"
   - Repeat for additional templates (different objects or variations)
3. **Configure Edits & Generate**:
   - Adjust qualitative sliders (brightness, contrast, gamma, hue, saturation, sharpen, noise, opacity) for each template
   - Click "Generate All Variants" to stream-process all dataset images
   - Download all variants as a ZIP

If you see a model load error, confirm the checkpoint path (see Model Weights section).

### Manual Setup (If you prefer explicit steps)

#### 1. Python Service
```powershell
cd py
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements-sam.txt
python app.py  # loads SAM if checkpoint present
```
The Flask service listens on `http://localhost:5001`.

#### 2. Node Proxy
Open a new PowerShell window:
```powershell
cd server
npm install
npm start
```
Node proxy listens on `http://localhost:3000`.

## Example REST (SAM endpoints)
The classical `/segment` and `/apply` multipart endpoints were removed. Use the SAM JSON flow below (see also the Quick JSON Flow section). For quick experimentation Postman/Insomnia is recommended.

## Notes / Future Improvements
- Add GPU detection + auto torch install hint.
- Provide mask visualization overlay download.
- Optional export of all saved component masks as a ZIP.
- Add tests and validation for input fields.
- Cache per image hash to skip re-embedding for repeated sessions.

## API Reference

### Dataset Workflow Endpoints (Primary)
| Method | Path | Purpose |
|--------|------|---------|
| POST | `/sam/dataset/init` (multipart images) | Initialize a dataset, returns `dataset_id` |
| POST | `/sam/dataset/template/save` (JSON) | Save a template with normalized points `{dataset_id, image_filename, points:[{x_norm,y_norm,positive}], name?}` |
| GET  | `/sam/dataset/templates?dataset_id=...` | List all templates for a dataset |
| POST | `/sam/dataset/apply_stream` (JSON) | Stream-generate variants for all dataset images using templates `{dataset_id, templates:[{template_id, edits:{...}}]}` |

### Legacy Single-Image Endpoints (Deprecated)
| Method | Path | Purpose |
|--------|------|---------|
| POST | `/sam/init` (multipart image) | Start a SAM session, returns `image_id` |
| POST | `/sam/segment` (JSON) | Provide point prompts `{image_id, points:[{x,y,positive}], accumulate?, top_k?}` |
| POST | `/sam/save_component` (JSON) | Persist chosen mask `{image_id, mask_png, score, name?}` |
| GET  | `/sam/components?image_id=...` | List saved components |
| POST | `/sam/apply` (JSON) | Apply edits to saved components |

### Legacy Batch Endpoints (Deprecated – Use Dataset Workflow Instead)
| Method | Path | Purpose |
|--------|------|---------|
| POST | `/sam/batch_process` (multipart) | Batch process multiple images with optional center-point SAM mask & global edits |
| POST | `/sam/batch_process_stream` (multipart) | Streaming variant of batch_process |

### Installing SAM (CPU Example)
```powershell
cd py
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
# Install torch (adjust for CUDA if you have GPU)
pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
# Install Segment Anything
pip install git+https://github.com/facebookresearch/segment-anything.git
# Place SAM ViT-B checkpoint at py/models/sam_vit_b.pth (download from official repo release)
```

### Quick JSON Flow (PowerShell using curl)
```powershell
# 1. Init
$resp = curl -F "image=@sample.jpg" http://localhost:5001/sam/init | ConvertFrom-Json
$imageId = $resp.image_id
# 2. First point (positive)
$segmentReq = @{ image_id=$imageId; points=@(@{x=120;y=200;positive=$true}) } | ConvertTo-Json
curl -H "Content-Type: application/json" -d $segmentReq http://localhost:5001/sam/segment | Out-File candidates.json
# 3. Inspect candidates.json, pick a mask (mask_png & score) and save component
$cand = Get-Content candidates.json | ConvertFrom-Json
$first = $cand.candidates[0]
$saveReq = @{ image_id=$imageId; mask_png=$first.mask_png; score=$first.score; name='cap' } | ConvertTo-Json
curl -H "Content-Type: application/json" -d $saveReq http://localhost:5001/sam/save_component
# 4. Apply edit
$applyReq = @{ image_id=$imageId; edits=@(@{ component_id=1; brightness=0.1; contrast=0.15; sharpen=0.5 }) } | ConvertTo-Json
curl -H "Content-Type: application/json" -d $applyReq http://localhost:5001/sam/apply > variant.json
```

### Batch Processing Examples
You can process a folder of images in one request. Two modes:
1. `full` (default) – treat entire image as a single component and apply global edits.
2. `center_point` – run SAM with a single positive point at the image center and use the highest‑scoring mask as the component region.

Multipart form fields:
- `images`: one or more files (repeat field)
- `mode`: `full` | `center_point`
- `edits`: JSON string of global edit parameters (same keys as per-component: brightness, contrast, gamma, hue, saturation, sharpen, noise, opacity)
- `export_mask`: `1` to include the component mask PNG (base64) per image

PowerShell example (center point mode applying slight contrast + sharpen):
```powershell
$files = Get-ChildItem .\batch_in -Filter *.jpg
$form = @{}
foreach($f in $files){ $form["images"] = Get-Item $f.FullName }
$edits = @{ contrast=0.15; sharpen=0.5; opacity=1 } | ConvertTo-Json -Compress
curl -F "mode=center_point" -F "edits=$edits" -F "export_mask=1" @(
		$files | ForEach-Object { "-F images=@$($_.FullName)" }
) http://localhost:5001/sam/batch_process -o batch_results.json
```

NOTE: PowerShell's `curl` alias uses `Invoke-WebRequest`; for complex multipart with many files consider a loop or use `Invoke-RestMethod` with `-Form`.

Example response snippet:
```json
{
	"results": [
		{"filename": "img1.jpg", "image_id": "...", "variant_png": "<base64>", "mode": "center_point", "score": 0.912, "component_mask_png": "<base64>"},
		{"filename": "img2.jpg", "image_id": "...", "variant_png": "<base64>", "mode": "center_point", "score": 0.887, "component_mask_png": "<base64>"}
	],
	"count": 2
}
```

To decode the base64 variant to a file in PowerShell:
```powershell
$data = Get-Content batch_results.json | ConvertFrom-Json
$i = 0
foreach($r in $data.results){
	$pngBytes = [Convert]::FromBase64String($r.variant_png)
	[IO.File]::WriteAllBytes("batch_out/$($r.filename)_variant.png", $pngBytes)
	if($r.component_mask_png){
		$maskBytes = [Convert]::FromBase64String($r.component_mask_png)
		[IO.File]::WriteAllBytes("batch_out/$($r.filename)_mask.png", $maskBytes)
	}
	$i++
}
```

### Dataset Workflow Details

#### Step 1: Dataset Initialization
- Upload 5–100 images (JPG/PNG) via multipart form
- Backend stores images in-memory or temp directory, indexed by `dataset_id`
- Returns `{dataset_id, count}` for subsequent template operations

#### Step 2: Template Capture
- Select a reference image from the first 3 dataset images
- Add point prompts (positive/negative) by clicking on the image
- Points are **normalized** to [0,1] range (`x_norm = x / image_width`) for resolution independence
- Save template with optional name → backend returns `template_id`
- Repeat for multiple templates (e.g., "background blur", "object sharpen", "color shift")

#### Step 3: Edit Configuration & Generation
- For each template, configure qualitative edits:
  - **Brightness**: -1 (darker) to +1 (lighter)
  - **Contrast**: -1 (flatter) to +1 (punchier)
  - **Gamma**: -0.9 (lift shadows) to +2 (deepen shadows)
  - **Hue**: -180° to +180° (color rotation)
  - **Saturation**: -1 (muted) to +3 (vivid)
  - **Sharpen**: 0 (softer) to 2 (sharper)
  - **Noise**: 0 (clean) to 0.2 (textured grain)
  - **Opacity**: 0 (transparent) to 1 (solid blend)
- Click "Generate All Variants" to stream-process:
  - For each dataset image, apply each template (denormalize points, run SAM, apply edits)
  - Stream results as SSE (`data: {filename, variant_png, template_name}`)
  - Frontend incrementally displays results
- Download all variants as ZIP (client-side bundling via JSZip)

#### Template Reusability
- Templates are stored with normalized points, so they work across different image resolutions
- One template can be applied to all dataset images (e.g., "enhance subject" template)
- Multiple templates can be applied to the same image (e.g., "background blur" + "subject sharpen")

#### Streaming Performance
- Results stream incrementally (no need to wait for all images to finish)
- Each image processes independently (can parallelize in future with worker pool)
- Large datasets (50+ images) complete in ~1–5 minutes depending on SAM model size and CPU/GPU

### Determinism
- Noise addition uses a seeded RNG (component area + id) for consistent results per component
- Re-running segmentation with identical points, model, and image produces the same masks
- Template application is deterministic given the same points, edits, and source images

### Front-End Status
The front-end is **dataset-only**: single-image interactive segmentation UI has been removed. For legacy single-image workflow, restore `server/public/script.js.bak`.

## Production Deployment

You will run two processes (Python SAM backend + Node static/proxy) behind an optional reverse proxy (NGINX, Caddy, etc.). Below are minimal approaches.

### 1. Environment Variables (Backend & Proxy)

Core model & server:
- `SAM_CHECKPOINT` – Absolute path to SAM (or HQ-SAM) weight file. If unset the loader searches common names under `models/`.
- `SAM_MODEL_TYPE` – Force model variant (`vit_tiny`, `vit_t`, `vit_b`, `vit_h`). Defaults to `vit_tiny` when HQ-SAM is present, else `vit_t`.
- `FLASK_HOST` – Bind host (default `0.0.0.0`).
- `FLASK_PORT` – Bind port (default `5001`).
- `WARM_MODEL` – `1` (default) preloads SAM at startup, `0` lazy loads on first request.

Performance & quality knobs:
- `PRECOMPUTE_EMBEDDINGS` – `1` (default) enables embedding precompute endpoint & auto precompute on dataset init; set `0` to disable.
- `DOWNSCALE_MAX` – Max longer image side before inference (default `1600`). Lower for speed (e.g. `1200` or `1024`).
- `OUTPUT_FORMAT` – `WEBP` (default) or `PNG` for streamed/generated variants.
- `WEBP_QUALITY` – WEBP quality (default `88`). Lower (75–80) for faster, smaller outputs.
- `SAM_FP16` – `1` to enable half precision on CUDA devices (saves memory, speeds up), `0` (default) disables / keeps full precision or on CPU.
- `EMBED_CACHE_MAX` – Max cached image embedding entries (default `1000`). Set lower to bound memory, `0` to disable eviction limit.
- `MAX_IMAGES_PER_DATASET` – Cap dataset size (default `150`). Rejects larger uploads early.
- `MAX_FILE_MB` – Reject images larger than this size in MB (default `40`).
- `DATASET_TTL_HOURS` – Dataset auto-expiration window (default `6`). Cleanup occurs opportunistically on new dataset init.

Node proxy / UI:
- `PY_SERVICE_URL` – URL the Node server uses to reach Python (`http://localhost:5001`).
- `PORT` – Node listen port (`3000`).

General:
- `PYTHONUNBUFFERED=1` – Immediate log flushing (recommended for Docker/systemd).

### 2. Python Service (Production Style)
Create (or reuse) a virtualenv, install deps, and run with a WSGI/ASGI server for robustness. The current app is a simple Flask instance; using `gunicorn` with workers is suggested for concurrent requests (SAM inference is heavy, so start with 1–2 workers; more may duplicate model memory use).

Example (Linux/macOS):
```bash
cd py
python -m venv .venv
source .venv/bin/activate
pip install -r requirements-sam.txt
pip install gunicorn
export SAM_CHECKPOINT=/opt/models/sam_vit_b.pth
export FLASK_HOST=0.0.0.0
export FLASK_PORT=5001
gunicorn -w 1 -b 0.0.0.0:5001 app:app
```

On Windows (PowerShell) use `pip install waitress` instead of gunicorn:
```powershell
cd py
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements-sam.txt
pip install waitress
$env:SAM_CHECKPOINT="C:\\models\\sam_vit_b.pth"
python -m waitress --listen=0.0.0.0:5001 app:app
```

If you prefer to let the built-in bootstrap run (it can start Waitress automatically), you can simply:
```powershell
python app.py
```
and it will attempt a production-friendly startup (model warm if `WARM_MODEL=1`).

### 3. Node Proxy (Production Build)
The UI is static so you can serve directly via Node (`express`) or any static server (NGINX). Current Node service also proxies SAM API calls, so keep it if you want a single origin.

```bash
cd server
npm ci --only=production
PORT=3000 PY_SERVICE_URL=http://localhost:5001 node server.js
```

### 4. Reverse Proxy (Optional NGINX Snippet)
```nginx
server {
	listen 80;
	server_name your.domain.tld;

	location /sam/ { # Direct to Python if you want to bypass Node proxy
		proxy_pass http://127.0.0.1:5001;
		proxy_set_header Host $host;
	}

	location /api/ {
		proxy_pass http://127.0.0.1:3000;
		proxy_set_header Host $host;
	}

	location / {
		proxy_pass http://127.0.0.1:3000;
		proxy_set_header Host $host;
		add_header Cache-Control "no-store";
	}
}
```

If using only the Node proxy, you can omit the direct `/sam/` block.

### 5. Docker (Outline Only)
You can containerize both services or keep separate images:
1. Base image with Python + model weights volume.
2. Node image serving static and proxy.
3. Use docker-compose to join networks.

Suggested volume mount for weights:
```yaml
volumes:
	sam_models:

services:
	sam:
		image: python:3.11-slim
		volumes:
			- sam_models:/app/models
		environment:
			- SAM_CHECKPOINT=/app/models/sam_vit_b.pth
```

### 6. Health & Readiness
- Python: `GET /health` returns `{ status: 'ok', sam_loaded: bool }` (add a readiness probe that waits for `sam_loaded: true` if you preload the model after container start).
- Node: `GET /health` returns `{ status: 'ok' }`.

Additional:
- Precompute endpoint: `POST /sam/dataset/precompute {"dataset_id": "..."}` warms embeddings (speeds later generation). Returns counts added / total.
- Dataset preview endpoint: `POST /sam/dataset/point_preview` (used internally by UI) safely rescales mask without distorting via proper PIL resize.

### 7. Scaling Considerations
- SAM model memory: each Python worker loads the full model; scale vertically (bigger GPU / more RAM) before horizontally (more replicas) to avoid duplicate weights cost.
- Embedding cache: Speeds repeated template application; tune `EMBED_CACHE_MAX` per memory headroom. Eviction is FIFO by insertion order.
- Downscaling: `DOWNSCALE_MAX` is a major speed lever; measure accuracy trade-off on fine objects.
- Parallelism: Current endpoint is single-process; for CPU-bound pre/post work you can wrap generation loops with a small thread or process pool (be mindful of GIL and model object thread safety—prefer process pool for heavy SAM calls if memory allows).
- Queue Architecture: For many simultaneous users, front-end submits a job; background workers (GPU nodes) consume jobs and push progress events (SSE/WebSocket) to clients.
- Static Assets: Offload UI static files to CDN (e.g., CloudFront/S3) and keep Python workers focused on inference.
- HTTP features: Enable gzip/br compression for JSON, but skip for large binary base64 streams if it adds latency.

### 8. Security / Hardening
- Restrict file size on upload (multer limit) to avoid huge images.
- Serve over HTTPS (proxy termination).
- Optionally require an API token header checked in Node before proxy.

### 9. Logging & Monitoring
- Add structured logging (JSON) for `/sam/*` latency.
- Track mask selection frequency, edit usage patterns for optimization.

### 10. GPU Deployment
- Install CUDA-enabled torch wheel matching your GPU.
- Set `TORCH_CUDA_ARCH_LIST` appropriately in container builds for smaller binaries.

### 11. Windows Service Deployment (Example with NSSM + Caddy)
1. Install Python & Node (system-wide) and place model weights at `C:\models`.
2. Create virtualenv & install deps (as above) under `py` and `server`.
3. Install Caddy (single binary) to serve on :80 and reverse proxy to Node / Python (sample Caddyfile):
```
your.domain.com {
	encode gzip
	reverse_proxy /api/* 127.0.0.1:3000
	reverse_proxy /sam/* 127.0.0.1:5001
	reverse_proxy 127.0.0.1:3000
}
```
4. Use NSSM to install two services:
	 - `nssm install sam-backend C:\Path\to\python.exe C:\Path\to\py\app.py`
	 - `nssm install sam-ui C:\Path\to\node.exe C:\Path\to\server\server.js`
5. Set environment variables for each service (Checkpoint, DOWNSCALE_MAX, etc.).
6. Start services, verify `http://localhost:3000` works locally, then configure DNS to point to your host.

### 12. Autoscale Architecture (Reference Design)
Target: National usage, unpredictable load spikes.

Core components:
- Static UI: S3 + CloudFront (immutable deploy). Build-time inject `API_BASE` pointing to an API layer.
- API Gateway / ALB: Receives user requests (dataset init, template save, job submit).
- Job Queue: Amazon SQS (or Redis stream) holds generation jobs `{job_id, dataset_id, templates, edits}`.
- GPU Workers: ECS (Fargate GPU) or EKS nodes running the Python container. Each worker:
	1. Polls SQS for a job
	2. Downloads dataset images (S3 prefix like `datasets/{dataset_id}/`)
	3. Runs precompute (if not already cached) and streaming generation
	4. Emits progress events (option A: push to WebSocket service keyed by job id; option B: write progress JSON objects to S3 with object versioning; option C: publish SNS -> Lambda -> WebSocket broadcast)
	5. Writes final variants to S3 under `outputs/{job_id}/`.
- Metadata Store: DynamoDB (jobs table: partition `job_id`, attributes: status, progress, created_at, dataset_id), optional TTL for cleanup.
- Progress Delivery:
	- WebSocket API (API Gateway) with connection IDs & a simple Lambda broadcaster.
	- Or long-polling / SSE from a lightweight Node proxy that subscribes to an internal channel.
- AuthN/AuthZ: API key or Cognito JWT gating dataset/job operations.

Data Flow:
1. Client uploads images directly to S3 with pre-signed POST (bypassing inference nodes).
2. Client calls `POST /jobs` (API) with template definitions.
3. API enqueues job in SQS, returns `job_id`.
4. Worker processes and streams progress -> WebSocket.
5. Client downloads zipped outputs from S3 (optionally request a pre-signed archive URL).

Scaling Levers:
- Increase SQS visibility timeout proportional to worst-case dataset time.
- AutoScale policy on ECS service for Average GPU utilization or queue depth.
- Use `DOWNSCALE_MAX` / model variant to offer “FAST” vs “QUALITY” modes.
- Introduce result CDN caching for repeated variant retrieval.

Cost Optimization:
- Spot instances for non-critical workers.
- Tiered retention: auto-delete datasets after `DATASET_TTL_HOURS`.
- Compress variants (WEBP) for bandwidth reduction.

### 13. Performance Tuning Playbook
| Goal | Lever | Notes |
|------|-------|-------|
| Faster mask inference | Use `vit_tiny` (HQ-SAM) or `vit_t` | Smallest viable model first |
| Lower latency | `DOWNSCALE_MAX=1200` | Validate small-object fidelity |
| Reduce bandwidth | `OUTPUT_FORMAT=WEBP`, lower `WEBP_QUALITY` | Quality 80 still visually strong |
| Memory stability | Lower `EMBED_CACHE_MAX` | Evict oldest embeddings |
| Warm first request | `WARM_MODEL=1` | Avoid cold start pause |
| Faster GPU throughput | `SAM_FP16=1` | Only if CUDA + supports fp16 |
| Faster region reuse | Precompute endpoint | Call after dataset init before generation |

### 14. Maintenance & Cleanup
- Datasets older than `DATASET_TTL_HOURS` removed opportunistically (triggered on new dataset init). For continuous cleanup in long-lived processes add a lightweight background thread calling the internal cleanup every N minutes.
- Embedding cache eviction triggers when size exceeds `EMBED_CACHE_MAX` (simple FIFO). Consider LRU if usage patterns diverge.
- Log rotation: rely on systemd journald, Docker log driver, or external aggregation (ELK/OTel).
- Backups: Model checkpoints should be stored in an artifact bucket (treat local copy as cache).
- Upgrades: Test new SAM checkpoints or model variants in a staging environment with representative images to benchmark speed & mask quality.

### 15. API Additions (Beyond Earlier Sections)
| Method | Path | Purpose |
|--------|------|---------|
| POST | `/sam/dataset/precompute` | Precompute & cache image embeddings for a dataset (faster subsequent template application) |
| POST | `/sam/dataset/point_preview` | (UI internal) Return mask preview for a single template point set |
| POST | `/api/presign` | (Cloud) Create S3 presigned POST for dataset uploads (requires API key if set) |
| POST | `/api/jobs` | (Cloud) Enqueue a remote generation job into SQS + record in DynamoDB |
| GET  | `/api/jobs/:id` | (Cloud) Poll job status from DynamoDB |

These supplement previously documented dataset endpoints.

### 16. Future Roadmap (Suggested)
- Background worker pool for parallel image variant generation.
- LRU embedding cache with size-aware eviction (tensor bytes not just count).
- Auth tokens / rate limiting (per IP / API key) for public-facing deployments.
- S3 / object storage adapter abstraction (pluggable persistence layer).
- Configurable job priority queue (fast small jobs vs large slow ones).
- Vectorized multi-mask application to reduce per-image Python overhead.

## Minimal Production Checklist
- [ ] SAM checkpoint present / env var set
- [ ] Python service supervisored (systemd, gunicorn, or waitress)
- [ ] Node proxy running with `PY_SERVICE_URL` correctly pointing to Python
- [ ] Reverse proxy (optional) forwarding 80/443 → Node
- [ ] Health endpoints monitored
- [ ] Upload size limits enforced
- [ ] Logs retained & rotated
- [ ] (Cloud) S3 buckets + SQS queue + DynamoDB table provisioned
- [ ] (Cloud) Worker service running with correct IAM (GetObject/PutObject, Send/Receive/DeleteMessage, UpdateItem)

### Docker Compose (Local Cloud Emulation)
Provided `docker-compose.yml` spins up:
- `sam-backend` (Flask/SAM)
- `sam-node` (UI + proxy + AWS API endpoints)
- `sam-worker` (queue consumer)
- `localstack` (emulated S3/SQS/DynamoDB)

After `docker compose up --build`, create resources inside LocalStack:
```bash
awslocal s3 mb s3://local-datasets
awslocal s3 mb s3://local-outputs
awslocal s3 mb s3://local-models
awslocal dynamodb create-table --table-name sam_jobs --attribute-definitions AttributeName=job_id,AttributeType=S --key-schema AttributeName=job_id,KeyType=HASH --billing-mode PAY_PER_REQUEST
awslocal sqs create-queue --queue-name sam-jobs
```
Then upload a checkpoint into `local-models` bucket (or mount a local volume) to enable the worker to fetch it.

### ECS Fargate CI/CD (CodePipeline + CodeBuild)

This repository includes an opinionated AWS CodePipeline + CodeBuild setup (`infra/pipeline.yaml`) to build and deploy the combined Node (UI + proxy) + Python backend container to ECS Fargate.

Components provisioned:
- ECR repository (immutable tags; `latest` also published for convenience)
- ECS cluster, task definition, service (single container using the `full` Docker target)
- ALB target group + listener rule (requires existing ALB listener ARN input)
- CloudWatch Log Group `/ecs/<project>-api`
- CodeBuild project (Docker build + push + imageDefinitions artifact)
- CodePipeline (GitHub source -> build -> ECS deploy)
- Supporting IAM roles (execution, task, codebuild, pipeline)

#### 1. Prerequisites
- Existing Application Load Balancer & HTTP listener (supply the listener ARN)
- VPC ID and at least two public subnet IDs (for Fargate public deployment) OR modify template for private + NAT
- GitHub Personal Access Token with `repo` scope stored/updated in Secrets Manager after stack create
- Model weights accessible (S3 or baked into image). Current template expects runtime S3 access for weights & datasets (broad S3 permissions in sample—tighten for prod)

#### 2. Deploy the Pipeline Stack
Package parameters (example):

| Parameter | Example |
|-----------|---------|
| ProjectName | sam-bulk-gen |
| GitHubOwner | your-gh-username |
| GitHubRepo  | Synthetic-Image-Generator |
| GitHubBranch| main |
| GitHubTokenSecretName | gh-token-sam-bulk |
| VpcId | vpc-0123456789abcdef0 |
| PublicSubnets | subnet-aaa,subnet-bbb |
| ListenerArn | arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/your-alb/... |
| HealthCheckPath | /api/backend/health |

CLI example (PowerShell):
```powershell
aws cloudformation deploy `
	--stack-name sam-bulk-gen-pipeline `
	--template-file .\infra\pipeline.yaml `
	--capabilities CAPABILITY_NAMED_IAM `
	--parameter-overrides `
		ProjectName=sam-bulk-gen `
		GitHubOwner=youruser `
		GitHubRepo=Synthetic-Image-Generator `
		GitHubBranch=main `
		GitHubTokenSecretName=gh-token-sam-bulk `
		VpcId=vpc-0123456789abcdef0 `
		PublicSubnets="subnet-aaa,subnet-bbb" `
		ListenerArn=arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/your-alb/abcd/efgh `
		HealthCheckPath=/api/backend/health
```

After stack creation, open Secrets Manager and update the secret named `gh-token-sam-bulk` with your real PAT JSON, e.g.:
```json
{"token":"ghp_xxxxxxxxxxxxxxxxxxx"}
```

Trigger the first pipeline run manually (or push a commit if webhooks/polling enabled) to build & deploy.

#### 3. Build Process (buildspec.yml)
`buildspec.yml` performs:
1. ECR login
2. Docker build of `--target full` tagged with `latest` and short commit SHA
3. Push both tags
4. Emit `imagedefinitions.json` consumed by ECS deploy stage

If you add environment variables or container fields, update the TaskDefinition in `infra/pipeline.yaml` or migrate to a task-def JSON rewrite step.

#### 4. Customizing the Task Definition
Edit `infra/pipeline.yaml` section `TaskDefinition.ContainerDefinitions` to inject additional env vars (S3 bucket names, API keys, feature flags). Re-deploy the CloudFormation stack; subsequent pipeline runs will use the updated task family revision.

#### 5. Model Weights Strategy
Options:
- Bake into image during Docker build (COPY) – increases image size, faster cold start.
- Download at runtime from S3 (current approach via existing logic). Ensure TaskRole has least-privilege S3 read.
- EFS volume mount (share across tasks) – lower duplicate storage, higher complexity.

#### 6. Zero-Downtime Deployments
The ECS service uses default rolling update (min healthy 50%, max 200%). Increase `DesiredCount` for true blue/green style safety and/or integrate CodeDeploy (not included in this template) for canary/linear strategies.

#### 7. Private Subnets / NAT
For production hardening deploy tasks in private subnets with `AssignPublicIp: DISABLED` and route outbound traffic via NAT Gateway. Update template parameters & remove direct public IP assignment.

#### 8. Adding the Worker Service
This template only deploys the API/UI container. To add the SQS worker:
1. Duplicate `TaskDefinition` & `Service` resources with adjusted `Family` (e.g., `${ProjectName}-worker`).
2. Remove ALB sections; keep network config.
3. Add environment (QUEUE URL, TABLE NAME, BUCKETS, API_KEY). Ensure TaskRole includes required SQS/DynamoDB ops.
4. Extend CodeBuild post_build to also craft `imagedefinitions-worker.json` or adopt separate build project.
5. Add second ECS deploy action in Pipeline (Deploy stage) referencing new image definitions file.

#### 9. GitHub Webhooks vs Polling
The ThirdParty GitHub source in classic CodePipeline supports either manual webhook creation or periodic polling. For webhooks, create a GitHub personal access token with appropriate scopes and ensure pipeline has permissions. (Consider migrating to CodeStarSourceConnection for GitHub App integration in the future.)

#### 10. Observability
- Logs: CloudWatch Log Group `/ecs/<project>-api`
- ALB Target Group health check at `/api/backend/health`
- Add metrics & alarms (CPUUtilization, MemoryUtilization, 5XX from ALB) post initial deployment.

#### 11. Security Hardening To-Do
- Restrict S3/Dynamo/SQS IAM resources to specific ARNs.
- Use Secrets Manager for API keys or model selection flags.
- Add WAF on ALB for public exposure.
- Enforce TLS (add HTTPS listener + ACM cert) and redirect HTTP.

#### 12. Pipeline Cleanup / Deletion
Delete the CloudFormation stack. ECR images and S3 artifact bucket are retained (manual cleanup required). Update `DeletionPolicy` if you want automatic removal.

#### 13. Local → Cloud Parity Tips
- Match `DOWNSCALE_MAX`, `SAM_MODEL_TYPE`, and performance flags to mirror production behavior in dev.
- Use immutable tags (short SHA) for traceability; `latest` is convenience only.

---
For advanced deployment models (blue/green, multi-env dev/stage/prod) consider duplicating the stack with different `ProjectName` prefixes and adding a manual approval stage between build and prod deploy.

