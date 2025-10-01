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

