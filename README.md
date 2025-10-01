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

## License
MIT (add a LICENSE file if needed).