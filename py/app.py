import io
import json
import base64
import uuid
import hashlib
import threading
import os
import glob
from typing import List, Dict, Any, Optional, Tuple

import numpy as np
from flask import Flask, request, send_file, Response
from PIL import Image
from skimage import color, filters, morphology, measure, segmentation, util
from skimage.filters import gaussian

# Optional SAM imports (lazy). If not installed, SAM endpoints will return 501.
try:
    from segment_anything import sam_model_registry, SamPredictor  # type: ignore
    import torch  # type: ignore
    _SAM_AVAILABLE = True
except Exception:  # pragma: no cover
    _SAM_AVAILABLE = False

# ---------------------------------------------------------------------------
# In-memory session store for SAM-derived components
# ---------------------------------------------------------------------------
_SESSION_LOCK = threading.Lock()
_SESSIONS: Dict[str, Dict[str, Any]] = {}
_SAM_PREDICTOR: Optional["SamPredictor"] = None
_SAM_MODEL_ID: Optional[str] = None

def _load_sam_model(model_type: str = 'vit_b', checkpoint_path: Optional[str] = None):
    """Attempt to load SAM model.

    Resolution order for checkpoint:
      1. Explicit function arg (checkpoint_path)
      2. Environment variable SAM_CHECKPOINT
      3. Default 'models/sam_vit_b.pth'
      4. First match of glob models/sam_vit_b*.pth or py/models/sam_vit_b*.pth
    Returns True on success, False otherwise (without raising).
    """
    global _SAM_PREDICTOR, _SAM_MODEL_ID
    if not _SAM_AVAILABLE:
        return False
    if _SAM_PREDICTOR is not None:
        return True
    env_ckpt = os.environ.get('SAM_CHECKPOINT')
    checkpoint_path = env_ckpt or checkpoint_path or 'models/sam_vit_b.pth'
    # If the provided checkpoint doesn't exist, try glob fallbacks
    if not os.path.exists(checkpoint_path):
        candidates = glob.glob('models/sam_vit_b*.pth') + glob.glob('py/models/sam_vit_b*.pth')
        if candidates:
            checkpoint_path = candidates[0]
    if not os.path.exists(checkpoint_path):
        print(f"[SAM] Checkpoint not found at '{checkpoint_path}'. Set SAM_CHECKPOINT env var or place file at models/sam_vit_b.pth")
        return False
    try:
        sam = sam_model_registry[model_type](checkpoint=checkpoint_path)
        device = 'cuda' if torch.cuda.is_available() else 'cpu'
        sam.to(device)
        _SAM_PREDICTOR = SamPredictor(sam)
        _SAM_MODEL_ID = f"{model_type}:{checkpoint_path}:{device}"
        print(f"[SAM] Loaded model '{model_type}' from {checkpoint_path} on {device}")
        return True
    except Exception as e:  # pragma: no cover
        print(f"[SAM] Failed to load model: {e}")
        _SAM_PREDICTOR = None
        return False

def _session_init(image: np.ndarray, image_bytes: bytes) -> str:
    image_id = uuid.uuid4().hex
    image_hash = hashlib.sha1(image_bytes).hexdigest()
    with _SESSION_LOCK:
        _SESSIONS[image_id] = {
            'image': image,              # original RGB (uint8)
            'image_hash': image_hash,
            'components': {},            # comp_id -> component dict
            'next_component_id': 1,
            'points': [],                # accumulated (for refinement if needed)
        }
    return image_id

def _get_session(image_id: str) -> Optional[Dict[str, Any]]:
    with _SESSION_LOCK:
        return _SESSIONS.get(image_id)

def _add_component(image_id: str, mask: np.ndarray, score: float, name: Optional[str] = None) -> Dict[str, Any]:
    sess = _get_session(image_id)
    if sess is None:
        raise ValueError('invalid image_id')
    comp_id = sess['next_component_id']
    sess['next_component_id'] += 1
    ys, xs = np.where(mask)
    bbox = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())] if xs.size else [0,0,0,0]
    comp = {
        'id': comp_id,
        'mask': mask.astype(bool),
        'bbox': bbox,
        'area': int(mask.sum()),
        'score': float(score),
        'name': name or f'component_{comp_id}'
    }
    sess['components'][comp_id] = comp
    return comp

def _list_components_public(sess: Dict[str, Any]) -> List[Dict[str, Any]]:
    out = []
    for c in sess['components'].values():
        out.append({k: c[k] for k in ('id','bbox','area','score','name')})
    return out

def _unsharp_mask(region: np.ndarray, amount: float = 0.0, sigma: float = 1.0) -> np.ndarray:
    if amount <= 0:
        return region
    blurred = gaussian(region, sigma=sigma, channel_axis=-1, preserve_range=True)
    return np.clip(region + amount * (region - blurred), 0, 1)

app = Flask(__name__)

# Helper functions

def to_png_bytes(arr: np.ndarray) -> bytes:
    if arr.dtype != np.uint8:
        arr = np.clip(arr, 0, 255).astype(np.uint8)
    img = Image.fromarray(arr)
    buf = io.BytesIO(); img.save(buf, format='PNG'); buf.seek(0)
    return buf.read()

def apply_edits(img: np.ndarray, object_mask: np.ndarray, comp_mask: np.ndarray, edits: List[Dict[str, Any]]):
    if not edits:
        return img
    # Prepare HSV for color operations; keep original for final merge
    rgb = img[..., :3].astype(np.float32) / 255.0
    gray_input = np.allclose(rgb[...,0], rgb[...,1]) and np.allclose(rgb[...,1], rgb[...,2])

    # Build per-component edit dict
    edit_map = {e.get('id'): e for e in edits if 'id' in e}

    result = rgb.copy()

    # We'll adjust brightness/contrast/gamma even for grayscale; hue/saturation if not grayscale.
    hsv = color.rgb2hsv(result) if not gray_input else None

    for cid, edit in edit_map.items():
        mask = (comp_mask == cid) if comp_mask is not None and comp_mask.max() > 0 else object_mask
        if mask.sum() == 0:
            continue
        region = result[mask]
        # Brightness: additive in [0,1] range
        brightness = float(edit.get('brightness', 0.0))  # +/- 1 maybe
        if brightness != 0:
            region = np.clip(region + brightness, 0, 1)
        # Contrast: scale around 0.5
        contrast = float(edit.get('contrast', 0.0))
        if contrast != 0:
            region = np.clip((region - 0.5)*(1+contrast) + 0.5, 0, 1)
        # Gamma: power law (>0)
        gamma = float(edit.get('gamma', 0.0))
        if gamma != 0:
            gamma_val = max(1e-3, 1 + gamma)  # edit gamma as delta around 1
            region = np.clip(region ** (1.0 / gamma_val), 0, 1)
        result[mask] = region
        if not gray_input and hsv is not None:
            hregion = hsv[...,0][mask]
            sregion = hsv[...,1][mask]
            # Hue shift (in degrees or 0-1?) assume edit.hue in degrees
            if 'hue' in edit:
                hue_shift = float(edit['hue']) / 360.0
                hregion = (hregion + hue_shift) % 1.0
            if 'saturation' in edit:
                sat_scale = 1 + float(edit['saturation'])
                sregion = np.clip(sregion * sat_scale, 0, 1)
            hsv[...,0][mask] = hregion
            hsv[...,1][mask] = sregion
        # Sharpen (unsharp amount) in 0..2 typical
        sharpen_amt = float(edit.get('sharpen', 0.0))
        if sharpen_amt != 0:
            region = result[mask]
            region = _unsharp_mask(region, amount=sharpen_amt, sigma=1.0)
            result[mask] = region
        # Gaussian noise (std 0..0.2) deterministic: seed via hash of pixel count + cid
        noise_std = float(edit.get('noise', 0.0))
        if noise_std > 0:
            cid_int = int(cid) if cid is not None else 0
            seed_val = int((int(mask.sum()) * (cid_int + 13)) % (2**32-1))
            rng = np.random.default_rng(seed_val)
            n = rng.normal(0, noise_std, size=(mask.sum(), 3))
            region = result[mask]
            region = np.clip(region + n, 0, 1)
            result[mask] = region
    if not gray_input and hsv is not None:
        result = color.hsv2rgb(hsv)
    # If object_mask covers full image (SAM path passes component mask as object_mask), just rebuild array
    if object_mask.dtype != bool:
        object_mask = object_mask.astype(bool)
    out = img.copy().astype(np.uint8)
    out[object_mask] = (result[object_mask] * 255).astype(np.uint8)
    return out

def mask_to_base64_png(mask: np.ndarray) -> str:
    # Encode component mask (uint8) as grayscale PNG
    mask_img = Image.fromarray(mask.astype(np.uint8), mode='L')
    buf = io.BytesIO()
    mask_img.save(buf, format='PNG')
    return base64.b64encode(buf.getvalue()).decode('ascii')

@app.route('/health', methods=['GET'])
def health():
    return {'status': 'ok', 'sam_loaded': _SAM_PREDICTOR is not None}

# ---------------------------------------------------------------------------
# SAM Endpoints
# ---------------------------------------------------------------------------

@app.route('/sam/init', methods=['POST'])
def sam_init():
    if 'image' not in request.files:
        return {'error': 'image file required'}, 400
    if not _SAM_AVAILABLE:
        return {'error': 'SAM not available (install torch + segment-anything)'}, 501
    # Attempt load
    _load_sam_model(model_type='vit_b')
    if _SAM_PREDICTOR is None:
        return {'error': 'SAM model load failed (missing checkpoint?)'}, 500
    file = request.files['image']
    data = file.read()
    img = Image.open(io.BytesIO(data)).convert('RGB')
    arr = np.array(img)
    image_id = _session_init(arr, data)
    return {'image_id': image_id, 'width': arr.shape[1], 'height': arr.shape[0]}

@app.route('/sam/segment', methods=['POST'])
def sam_segment():
    if not _SAM_AVAILABLE:
        return {'error': 'SAM not available'}, 501
    if _SAM_PREDICTOR is None and not _load_sam_model('vit_b'):
        return {'error': 'SAM model not loaded'}, 500
    payload = request.get_json(force=True, silent=True) or {}
    image_id = str(payload.get('image_id')) if payload.get('image_id') else ''
    points = payload.get('points', [])  # list of {x,y,positive}
    accumulate = bool(payload.get('accumulate', True))
    top_k = int(payload.get('top_k', 3))
    sess = _get_session(image_id)
    if not sess:
        return {'error': 'invalid image_id'}, 400
    # Accumulate points
    if accumulate:
        sess['points'].extend(points)
    else:
        sess['points'] = points
    if not sess['points']:
        return {'error': 'no points provided'}, 400
    img = sess['image']
    predictor = _SAM_PREDICTOR
    assert predictor is not None
    predictor.set_image(img)
    pts = np.array([[p['x'], p['y']] for p in sess['points']], dtype=np.float32)
    labels = np.array([1 if p.get('positive', True) else 0 for p in sess['points']], dtype=np.int32)
    with torch.no_grad():  # type: ignore
        masks, scores, _ = predictor.predict(point_coords=pts, point_labels=labels, multimask_output=True)
    # Sort by score desc
    order = np.argsort(-scores)
    masks = masks[order]
    scores = scores[order]
    top_k = min(top_k, masks.shape[0])
    results = []
    for i in range(top_k):
        m = masks[i].astype(bool)
        area = int(m.sum())
        ys, xs = np.where(m)
        bbox = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())] if xs.size else [0,0,0,0]
        # Encode mask PNG base64 (grayscale 0/255)
        mask_img = Image.fromarray((m*255).astype(np.uint8), mode='L')
        buf = io.BytesIO(); mask_img.save(buf, format='PNG'); buf.seek(0)
        mask_b64 = base64.b64encode(buf.read()).decode('ascii')
        results.append({
            'rank': i+1,
            'score': float(scores[i]),
            'area': area,
            'bbox': bbox,
            'mask_png': mask_b64
        })
    pos_count = int(labels.sum())
    neg_count = int(len(labels) - pos_count)
    return {
        'candidates': results,
        'points': sess['points'],
        'image_id': image_id,
        'point_summary': {
            'total': int(len(labels)),
            'positive': pos_count,
            'negative': neg_count
        }
    }

@app.route('/sam/save_component', methods=['POST'])
def sam_save_component():
    payload = request.get_json(force=True, silent=True) or {}
    image_id = str(payload.get('image_id')) if payload.get('image_id') else ''
    mask_png = payload.get('mask_png')
    score = float(payload.get('score', 0.0))
    name = payload.get('name')
    sess = _get_session(image_id)
    if not sess:
        return {'error': 'invalid image_id'}, 400
    if not mask_png:
        return {'error': 'mask_png required'}, 400
    # Decode mask
    try:
        data = base64.b64decode(mask_png)
        mask_img = Image.open(io.BytesIO(data)).convert('L')
        mask = (np.array(mask_img) > 127)
    except Exception:
        return {'error': 'invalid mask_png'}, 400
    comp = _add_component(image_id, mask, score, name)
    return {'component': {k: comp[k] for k in ('id','bbox','area','score','name')}}

@app.route('/sam/components', methods=['GET'])
def sam_components():
    image_id = request.args.get('image_id') or ''
    sess = _get_session(image_id) if image_id else None
    if not sess:
        return {'error': 'invalid image_id'}, 400
    return {'components': _list_components_public(sess)}

@app.route('/sam/apply', methods=['POST'])
def sam_apply():
    payload = request.get_json(force=True, silent=True) or {}
    image_id = str(payload.get('image_id')) if payload.get('image_id') else ''
    edits = payload.get('edits', [])  # list of {component_id, brightness,...}
    export_mask = bool(payload.get('export_mask', False))
    sess = _get_session(image_id)
    if not sess:
        return {'error': 'invalid image_id'}, 400
    base_img = sess['image']
    # Build combined mask per component and perform per-component edits
    out = base_img.copy()
    for e in edits:
        cid = e.get('component_id')
        comp = sess['components'].get(cid) if cid in sess['components'] else None
        if not comp:
            continue
        mask = comp['mask']
        # Reuse apply_edits by constructing a synthetic comp_mask with single id
        comp_mask = np.zeros(mask.shape, dtype=np.uint8)
        comp_mask[mask] = 1
        prev = out.copy()
        converted = apply_edits(out, mask, comp_mask, [{
            'id': 1,
            'brightness': e.get('brightness', 0),
            'contrast': e.get('contrast', 0),
            'gamma': e.get('gamma', 0),
            'hue': e.get('hue'),
            'saturation': e.get('saturation'),
            'sharpen': e.get('sharpen', 0),
            'noise': e.get('noise', 0)
        }])
        # If opacity provided (<1) blend edited region with previous version
        opacity = e.get('opacity')
        if opacity is not None:
            try:
                opacity_val = float(opacity)
            except (TypeError, ValueError):
                opacity_val = 1.0
            opacity_val = max(0.0, min(1.0, opacity_val))
            if opacity_val < 1.0:
                region = mask
                blended = (opacity_val * converted[region].astype(np.float32) + (1-opacity_val) * prev[region].astype(np.float