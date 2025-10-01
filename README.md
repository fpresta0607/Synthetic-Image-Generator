# SAM-Only Interactive Image Segmentation & Editing

This project now focuses on a single interactive workflow powered by Segment Anything (SAM) via a Python Flask backend and a lightweight Node/Express proxy + static UI. Classical (Otsu / watershed) segmentation paths were removed to simplify usage.

## Current Architecture

1. **Python Flask Service**: Hosts SAM endpoints (`/sam/*`) to initialize a session, generate candidate masks from point prompts, save components, and apply per-component edits (brightness, contrast, gamma, hue, saturation, sharpen, noise).
2. **Node/Express Proxy**: Serves the static front-end and forwards SAM API calls (`/api/sam/*`).

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

## Quick Start (Cross‑Platform)

You now have two options:

### A. Universal single command (Node-managed) – recommended
The `dev` script (`server/scripts/dev.mjs`) will:
1. Create `py/.venv` if missing.
2. Install Python dependencies (prefers `requirements-sam.txt`, falls back to `requirements.txt`).
3. Start the Flask SAM backend.
4. Start the Node proxy.

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

Then open: http://localhost:3000

Upload an image, click "Init SAM", add 1–3 positive points (left click) and optional negative points (right click or Shift+left), select a candidate mask, save it, adjust sliders, and Apply.

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

## SAM Point-Prompt Segmentation API
The backend exposes these endpoints (all now primary):

### Endpoints
| Method | Path | Purpose |
|--------|------|---------|
| POST | `/sam/init` (multipart image) | Start a SAM session, returns `image_id`. |
| POST | `/sam/segment` (JSON) | Provide point prompts `{image_id, points:[{x,y,positive}], accumulate?, top_k?}` returns top candidate masks with scores. |
| POST | `/sam/save_component` (JSON) | Persist chosen mask `{image_id, mask_png, score, name?}`. |
| GET  | `/sam/components?image_id=...` | List saved components. |
| POST | `/sam/apply` (JSON) | Apply edits to saved components; returns variant PNG (base64) and optional mask. |

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

### Determinism
- Noise addition uses a seeded RNG (component area + id) for consistent results per component.
- Re-running segmentation with identical points, model, and image produces the same masks.

### Front-End Status
The front-end is SAM-only: classical segmentation UI has been removed.

## Production Deployment

You will run two processes (Python SAM backend + Node static/proxy) behind an optional reverse proxy (NGINX, Caddy, etc.). Below are minimal approaches.

### 1. Environment Variables
| Variable | Purpose | Default |
|----------|---------|---------|
| `SAM_CHECKPOINT` | Absolute path to SAM weight file | `models/sam_vit_b.pth` search fallback |
| `PY_SERVICE_URL` (Node) | URL Node uses to reach Flask | `http://localhost:5001` |
| `PORT` (Node) | Node listen port | `3000` |
| `FLASK_PORT` | (Optional) Flask listen port | `5001` |
| `FLASK_HOST` | (Optional) Bind host | `0.0.0.0` |
| `PYTHONUNBUFFERED` | Real-time logs | (unset) |

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

### 7. Scaling Considerations
- SAM model memory: each Python worker loads the full model; scale vertically before horizontally.
- Add an LRU cache keyed by image hash if repeated inits are common.
- Enable HTTP keep-alive / compression at the reverse proxy layer.

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

## Minimal Production Checklist
- [ ] SAM checkpoint present / env var set
- [ ] Python service supervisored (systemd, gunicorn, or waitress)
- [ ] Node proxy running with `PY_SERVICE_URL` correctly pointing to Python
- [ ] Reverse proxy (optional) forwarding 80/443 → Node
- [ ] Health endpoints monitored
- [ ] Upload size limits enforced
- [ ] Logs retained & rotated

## License
MIT (add a LICENSE file if needed).#   S y n t h e t i c - I m a g e - G e n e r a t o r  
 