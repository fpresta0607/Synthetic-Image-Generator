import io
import json
import base64
import uuid
import hashlib
import threading
import os
import glob
import time
import zipfile
from typing import List, Dict, Any, Optional, Tuple

import numpy as np
from flask import Flask, request, send_file, Response, stream_with_context, jsonify
from PIL import Image
from skimage import color, filters, morphology, measure, segmentation, util
from skimage.filters import gaussian
from werkzeug.utils import secure_filename

# Optional SAM imports (lazy). If not installed, SAM endpoints will return 501.
# Try HQ-SAM first (higher quality), fall back to regular SAM
try:
    from segment_anything_hq import sam_model_registry, SamPredictor  # type: ignore
    import torch  # type: ignore
    _SAM_AVAILABLE = True
    _USING_HQ_SAM = True
except Exception:
    try:
        from segment_anything import sam_model_registry, SamPredictor  # type: ignore
        import torch  # type: ignore
        _SAM_AVAILABLE = True
        _USING_HQ_SAM = False
    except Exception:  # pragma: no cover
        _SAM_AVAILABLE = False
        _USING_HQ_SAM = False

# ---------------------------------------------------------------------------
# In-memory session store for SAM-derived components
# ---------------------------------------------------------------------------
_SESSION_LOCK = threading.Lock()
_SESSIONS: Dict[str, Dict[str, Any]] = {}
_SAM_PREDICTOR: Optional["SamPredictor"] = None
_SAM_MODEL_ID: Optional[str] = None

# ---------------------------------------------------------------------------
# DATASET (Bulk) in-memory store (non-persistent)
# ---------------------------------------------------------------------------
_DATASETS: Dict[str, Dict[str, Any]] = {}

def _get_default_model_type():
    """Get default model type based on loaded SAM package."""
    return 'vit_tiny' if _USING_HQ_SAM else 'vit_t'

# ---------------------------------------------------------------------------
# SAM Embedding Cache (Performance optimization: 3-5x speedup)
# ---------------------------------------------------------------------------
_EMBEDDING_CACHE: Dict[str, Any] = {}  # {image_hash: embedding_features}

def _ensure_datasets_dir() -> str:
    path = 'tmp_datasets'
    if not os.path.exists(path):
        os.makedirs(path, exist_ok=True)
    return path

def _predict_sam_mask(arr: np.ndarray, norm_points: List[Dict[str,Any]], cache_key: Optional[str] = None):
    """Predict SAM mask with embedding cache for 3-5x speedup."""
    import time
    start = time.time()
    
    if not _SAM_AVAILABLE:
        return None, None
    if _SAM_PREDICTOR is None and not _load_sam_model():  # Use default model (HQ-SAM vit_tiny or SAM vit_t)
        return None, None
    predictor = _SAM_PREDICTOR; assert predictor is not None
    h, w = arr.shape[:2]
    if not norm_points:
        return None, None
    
    # Use embedding cache if available (3-5x speedup)
    if cache_key and cache_key in _EMBEDDING_CACHE:
        predictor.features = _EMBEDDING_CACHE[cache_key]
        cache_hit = True
    else:
        predictor.set_image(arr)
        if cache_key:
            _EMBEDDING_CACHE[cache_key] = predictor.features
        cache_hit = False
    
    pts = np.array([[min(w-1,max(0,int(round(p['x_norm']*(w-1))))),
                     min(h-1,max(0,int(round(p['y_norm']*(h-1)))))] for p in norm_points], dtype=np.float32)
    labels = np.array([1 if p.get('positive', True) else 0 for p in norm_points], dtype=np.int32)
    
    with torch.no_grad():  # type: ignore
        masks, scores, _ = predictor.predict(point_coords=pts, point_labels=labels, multimask_output=True)
    order = np.argsort(-scores); idx = order[0]
    
    elapsed = time.time() - start
    print(f"[SAM] Predicted mask in {elapsed:.3f}s (cache_hit={cache_hit})")
    return masks[idx].astype(bool), float(scores[idx])

def _apply_templates(arr: np.ndarray, templates: Dict[str, Dict[str,Any]], edits: Dict[str, Dict[str,Any]]):
    out = arr.copy(); cumulative = None
    for tid, tpl in templates.items():
        if edits and tid not in edits:
            continue
        mask, score = _predict_sam_mask(out, tpl['points'])
        if mask is None:
            continue
        comp_mask = np.zeros(mask.shape, dtype=np.uint8); comp_mask[mask] = 1
        edit_vals = edits.get(tid, {}) if edits else {}
        payload = [{
            'id': 1,
            'brightness': edit_vals.get('brightness', 0),
            'contrast': edit_vals.get('contrast', 0),
            'gamma': edit_vals.get('gamma', 0),
            'hue': edit_vals.get('hue'),
            'saturation': edit_vals.get('saturation'),
            'sharpen': edit_vals.get('sharpen', 0),
            'noise': edit_vals.get('noise', 0)
        }]
        edited = apply_edits(out, mask, comp_mask, payload)
        op = edit_vals.get('opacity')
        if op is not None:
            try: ov = float(op)
            except (TypeError, ValueError): ov = 1.0
            ov = max(0.0, min(1.0, ov))
            if ov < 1.0:
                region = mask
                blend = (ov * edited[region].astype(np.float32) + (1-ov) * out[region].astype(np.float32)).astype(np.uint8)
                edited[region] = blend
        out = edited
        cumulative = mask if cumulative is None else (cumulative | mask)
    return out, cumulative

def _load_sam_model(model_type: Optional[str] = None, checkpoint_path: Optional[str] = None):
    """Attempt to load SAM model.

    Resolution order for checkpoint:
      1. Explicit function arg (checkpoint_path)
      2. Environment variable SAM_CHECKPOINT
      3. Default based on model_type (vit_tiny for HQ-SAM, vit_t for SAM)
      4. Glob fallback for any sam_*.pth files
    
    Model types:
      - vit_tiny / vit_t: ViT-Tiny (~40MB, 2-3x faster, slightly less accurate) - RECOMMENDED
      - vit_b: ViT-Base (~375MB, slower, more accurate)
      - vit_h: ViT-Huge (~2.4GB, slowest, most accurate)
    
    Returns True on success, False otherwise (without raising).
    """
    global _SAM_PREDICTOR, _SAM_MODEL_ID
    if not _SAM_AVAILABLE:
        return False
    if _SAM_PREDICTOR is not None:
        return True
    
    # Allow override via environment variable, or use package-specific default
    if model_type is None:
        model_type = _get_default_model_type()
    model_type = os.environ.get('SAM_MODEL_TYPE', model_type)
    env_ckpt = os.environ.get('SAM_CHECKPOINT')
    
    # Default checkpoint paths - prioritize HQ-SAM if using HQ-SAM package
    if _USING_HQ_SAM:
        default_paths = {
            'vit_t': 'models/sam_hq_vit_tiny.pth',
            'vit_tiny': 'models/sam_hq_vit_tiny.pth',
            'vit_b': 'models/sam_hq_vit_b.pth',
            'vit_h': 'models/sam_hq_vit_h.pth'
        }
    else:
        default_paths = {
            'vit_t': 'models/sam_vit_t.pth',
            'vit_b': 'models/sam_vit_b.pth',
            'vit_h': 'models/sam_vit_h.pth'
        }
    checkpoint_path = env_ckpt or checkpoint_path or default_paths.get(model_type, default_paths.get('vit_t', 'models/sam_vit_t.pth'))
    
    # If the provided checkpoint doesn't exist, try glob fallbacks
    if not os.path.exists(checkpoint_path):
        # Try model-specific patterns first (prioritize HQ-SAM)
        patterns = [
            f'models/sam_hq_{model_type}*.pth',  # HQ-SAM specific
            f'py/models/sam_hq_{model_type}*.pth',
            f'models/sam_{model_type}*.pth',  # Regular SAM
            f'py/models/sam_{model_type}*.pth',
            'models/sam_hq_*.pth',  # Any HQ-SAM model
            'py/models/sam_hq_*.pth',
            'models/sam_vit_*.pth',  # Any SAM model
            'py/models/sam_vit_*.pth'
        ]
        candidates = []
        for pattern in patterns:
            candidates.extend(glob.glob(pattern))
        if candidates:
            checkpoint_path = candidates[0]
            # Extract model type from filename
            fname = os.path.basename(checkpoint_path)
            if 'vit_h' in fname:
                model_type = 'vit_h'
            elif 'vit_b' in fname:
                model_type = 'vit_b'
            elif 'vit_t' in fname or 'tiny' in fname:
                model_type = 'vit_tiny' if _USING_HQ_SAM else 'vit_t'
    if not os.path.exists(checkpoint_path):
        print(f"[SAM] Checkpoint not found at '{checkpoint_path}'. Set SAM_CHECKPOINT env var or place file at models/sam_vit_b.pth")
        return False
    try:
        sam = sam_model_registry[model_type](checkpoint=checkpoint_path)
        device = 'cuda' if torch.cuda.is_available() else 'cpu'
        sam.to(device)
        _SAM_PREDICTOR = SamPredictor(sam)
        _SAM_MODEL_ID = f"{model_type}:{checkpoint_path}:{device}"
        package_name = "HQ-SAM" if _USING_HQ_SAM else "SAM"
        print(f"[{package_name}] Loaded model '{model_type}' from {checkpoint_path} on {device}")
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
                blended = (opacity_val * converted[region].astype(np.float32) + (1-opacity_val) * prev[region].astype(np.float32)).astype(np.uint8)
                converted[region] = blended
        out = converted
    png_bytes = to_png_bytes(out)
    resp_obj: Dict[str, Any] = {'image_id': image_id}
    resp_obj['variant_png'] = base64.b64encode(png_bytes).decode('ascii')
    if export_mask and edits:
        # If single component, export its mask; else skip
        if len(edits) == 1:
            cid = edits[0].get('component_id')
            comp = sess['components'].get(cid)
            if comp:
                mask_img = Image.fromarray((comp['mask']*255).astype(np.uint8), mode='L')
                buf = io.BytesIO(); mask_img.save(buf, format='PNG'); buf.seek(0)
                resp_obj['component_mask_png'] = base64.b64encode(buf.read()).decode('ascii')
    return resp_obj


# ---------------------------------------------------------------------------
# Batch Processing Endpoint
# ---------------------------------------------------------------------------
@app.route('/sam/batch_process', methods=['POST'])
def sam_batch_process():
    """Process a batch of images in a single request.

    Multipart form fields:
      images: one or more image files (required)
      edits: (optional) JSON string of global edits to apply to the selected region/component
      mode: (optional) 'full' (default) treats entire image as one component; 'center_point' runs a single positive point at image center using SAM
      export_mask: (optional) '1' to include component mask for each image

    Returns JSON: { results: [ { filename, image_id, variant_png, component_mask_png? } ] }
    """
    files = request.files.getlist('images')
    if not files:
        return {'error': 'at least one image file required (field name: images)'}, 400

    mode = request.form.get('mode', 'full')
    export_mask = request.form.get('export_mask', '0') == '1'
    edits_raw = request.form.get('edits')
    try:
        global_edits = json.loads(edits_raw) if edits_raw else {}
    except Exception:
        return {'error': 'invalid edits JSON'}, 400

    # Normalize edits into expected structure for apply_edits (list of dict with id=1)
    comp_edit = {
        'id': 1,
        'brightness': global_edits.get('brightness', 0),
        'contrast': global_edits.get('contrast', 0),
        'gamma': global_edits.get('gamma', 0),
        'hue': global_edits.get('hue'),
        'saturation': global_edits.get('saturation'),
        'sharpen': global_edits.get('sharpen', 0),
        'noise': global_edits.get('noise', 0)
    }
    opacity_val = global_edits.get('opacity')

    results = []

    # Ensure SAM model if needed
    need_sam = mode == 'center_point'
    if need_sam:
        if not _SAM_AVAILABLE:
            return {'error': 'SAM not available for center_point mode'}, 501
        if _SAM_PREDICTOR is None and not _load_sam_model('vit_b'):
            return {'error': 'SAM model load failed'}, 500

    for f in files:
        try:
            data = f.read()
            img = Image.open(io.BytesIO(data)).convert('RGB')
            arr = np.array(img)
        except Exception:
            results.append({'filename': f.filename, 'error': 'decode_failed'})
            continue

        # Create session (so user could later inspect components if desired)
        image_id = _session_init(arr, data)
        mask = None
        score = 1.0

        if mode == 'center_point':
            try:
                predictor = _SAM_PREDICTOR
                assert predictor is not None
                predictor.set_image(arr)
                h, w = arr.shape[:2]
                cx, cy = w // 2, h // 2
                pts = np.array([[cx, cy]], dtype=np.float32)
                labels = np.array([1], dtype=np.int32)
                with torch.no_grad():  # type: ignore
                    masks, scores, _ = predictor.predict(point_coords=pts, point_labels=labels, multimask_output=True)
                # pick highest scoring mask
                order = np.argsort(-scores)
                m = masks[order][0].astype(bool)
                score = float(scores[order][0])
                mask = m
            except Exception as e:  # pragma: no cover
                results.append({'filename': f.filename, 'image_id': image_id, 'error': f'sam_failed:{e}'})
                continue
        else:
            # Full image mask
            mask = np.ones(arr.shape[:2], dtype=bool)

        comp = _add_component(image_id, mask, score, name='batch_component')

        # Apply edits if any non-zero / provided OR opacity specified
        edited = arr.copy()
        any_edit = any(
            (comp_edit.get(k) not in (0, None) for k in ('brightness','contrast','gamma','hue','saturation','sharpen','noise'))
        ) or opacity_val is not None
        comp_mask = np.zeros(mask.shape, dtype=np.uint8)
        comp_mask[mask] = 1
        if any_edit:
            edited_candidate = apply_edits(arr, mask, comp_mask, [comp_edit])
            if opacity_val is not None:
                try:
                    ov = float(opacity_val)
                except (TypeError, ValueError):
                    ov = 1.0
                ov = max(0.0, min(1.0, ov))
                if ov < 1.0:
                    region = mask
                    blended = (ov * edited_candidate[region].astype(np.float32) + (1-ov) * arr[region].astype(np.float32)).astype(np.uint8)
                    edited_candidate[region] = blended
            edited = edited_candidate

        png_bytes = to_png_bytes(edited)
        result_obj: Dict[str, Any] = {
            'filename': f.filename,
            'image_id': image_id,
            'variant_png': base64.b64encode(png_bytes).decode('ascii'),
            'mode': mode,
            'score': score
        }
        if export_mask:
            result_obj['component_mask_png'] = mask_to_base64_png(mask.astype(np.uint8)*255)
        results.append(result_obj)

    return {'results': results, 'count': len(results)}


@app.route('/sam/batch_process_stream', methods=['POST'])
def sam_batch_process_stream():
    """Stream per-file batch processing progress.

    Emits Server-Sent-Events style lines (text/event-stream) but is tolerant of fetch streaming parser:
      data: {json}\n\n for each processed image
      data: [DONE]\n\n sentinel at completion.

    Accepts same multipart form fields as /sam/batch_process.
    """
    files = request.files.getlist('images')
    if not files:
        return {'error': 'at least one image file required (field name: images)'}, 400
    mode = request.form.get('mode', 'full')
    export_mask = request.form.get('export_mask', '0') == '1'
    edits_raw = request.form.get('edits')
    try:
        global_edits = json.loads(edits_raw) if edits_raw else {}
    except Exception:
        return {'error': 'invalid edits JSON'}, 400
    comp_edit = {
        'id': 1,
        'brightness': global_edits.get('brightness', 0),
        'contrast': global_edits.get('contrast', 0),
        'gamma': global_edits.get('gamma', 0),
        'hue': global_edits.get('hue'),
        'saturation': global_edits.get('saturation'),
        'sharpen': global_edits.get('sharpen', 0),
        'noise': global_edits.get('noise', 0)
    }
    opacity_val = global_edits.get('opacity')
    need_sam = mode == 'center_point'
    if need_sam:
        if not _SAM_AVAILABLE:
            return {'error': 'SAM not available for center_point mode'}, 501
        if _SAM_PREDICTOR is None and not _load_sam_model('vit_b'):
            return {'error': 'SAM model load failed'}, 500

    def _gen():
        for f in files:
            out_obj: Dict[str, Any] = {'filename': f.filename, 'mode': mode}
            try:
                data = f.read()
                img = Image.open(io.BytesIO(data)).convert('RGB')
                arr = np.array(img)
                image_id = _session_init(arr, data)
                out_obj['image_id'] = image_id
                mask: Optional[np.ndarray]
                score = 1.0
                if mode == 'center_point':
                    predictor = _SAM_PREDICTOR
                    assert predictor is not None
                    predictor.set_image(arr)
                    h, w = arr.shape[:2]
                    cx, cy = w // 2, h // 2
                    pts = np.array([[cx, cy]], dtype=np.float32)
                    labels = np.array([1], dtype=np.int32)
                    with torch.no_grad():  # type: ignore
                        masks, scores, _ = predictor.predict(point_coords=pts, point_labels=labels, multimask_output=True)
                    order = np.argsort(-scores)
                    m = masks[order][0].astype(bool)
                    score = float(scores[order][0])
                    mask = m
                else:
                    mask = np.ones(arr.shape[:2], dtype=bool)
                out_obj['score'] = score
                assert mask is not None
                _add_component(image_id, mask, score, name='batch_component')
                comp_mask = np.zeros(mask.shape, dtype=np.uint8); comp_mask[mask] = 1
                any_edit = any(
                    (comp_edit.get(k) not in (0, None) for k in ('brightness','contrast','gamma','hue','saturation','sharpen','noise'))
                ) or opacity_val is not None
                edited = arr
                if any_edit:
                    edited_candidate = apply_edits(arr, mask, comp_mask, [comp_edit])
                    if opacity_val is not None:
                        try:
                            ov = float(opacity_val)
                        except (TypeError, ValueError):
                            ov = 1.0
                        ov = max(0.0, min(1.0, ov))
                        if ov < 1.0:
                            region = mask
                            blended = (ov * edited_candidate[region].astype(np.float32) + (1-ov) * arr[region].astype(np.float32)).astype(np.uint8)
                            edited_candidate[region] = blended
                    edited = edited_candidate
                png_bytes = to_png_bytes(edited)
                out_obj['variant_png'] = base64.b64encode(png_bytes).decode('ascii')
                if export_mask and mask is not None:
                    out_obj['component_mask_png'] = mask_to_base64_png(mask.astype(np.uint8)*255)
            except Exception as e:  # pragma: no cover
                out_obj['error'] = f'processing_failed:{e}'
            # Emit event
            chunk = json.dumps(out_obj, separators=(',',':'))
            yield f'data: {chunk}\n\n'
        yield 'data: [DONE]\n\n'

    headers = {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'X-Accel-Buffering': 'no'
    }
    return Response(stream_with_context(_gen()), headers=headers)

# ---------------- Dataset Bulk Endpoints ----------------
@app.route('/sam/dataset/init', methods=['POST'])
def dataset_init():
    files = request.files.getlist('images')
    zip_file = request.files.get('zip')
    if not files and not zip_file:
        return {'error':'provide images[] or zip'}, 400
    ds_id = uuid.uuid4().hex
    root_dir = _ensure_datasets_dir()
    ds_dir = os.path.join(root_dir, ds_id)
    os.makedirs(ds_dir, exist_ok=True)
    collected = []
    if zip_file:
        try:
            with zipfile.ZipFile(zip_file.stream) as zf:
                for name in zf.namelist():
                    if name.lower().endswith(('.png','.jpg','.jpeg','.bmp','.tif','.tiff')):
                        data = zf.read(name)
                        fn = secure_filename(os.path.basename(name))
                        outp = os.path.join(ds_dir, fn)
                        with open(outp,'wb') as f: f.write(data)
                        collected.append(outp)
        except Exception as e:
            return {'error': f'zip_error:{e}'}, 400
    for f in files:
        fn = secure_filename(f.filename)
        outp = os.path.join(ds_dir, fn)
        f.save(outp)
        collected.append(outp)
    images_meta = []
    for p in collected:
        try:
            img = Image.open(p).convert('RGB'); w,h = img.size
            t = img.copy(); t.thumbnail((160,160)); buf = io.BytesIO(); t.save(buf, format='PNG')
            images_meta.append({'id': uuid.uuid4().hex,'filename': os.path.basename(p),'path': p,'w': w,'h': h,'thumb_b64': base64.b64encode(buf.getvalue()).decode('ascii')})
        except Exception:
            continue
    _DATASETS[ds_id] = {'images': images_meta, 'templates': {}, 'created_at': time.time()}
    return {'dataset_id': ds_id, 'images': [{'id':m['id'],'filename':m['filename'],'thumb_b64':m['thumb_b64']} for m in images_meta]}

@app.route('/sam/dataset/template/save', methods=['POST'])
def dataset_template_save():
    data = request.get_json(force=True, silent=True) or {}
    ds = _DATASETS.get(data.get('dataset_id',''))
    if not ds: return {'error':'dataset_not_found'}, 404
    pts = data.get('points', [])
    if not pts: return {'error':'no_points'}, 400
    name = data.get('name') or 'Template'
    template_class = data.get('class', '')  # 'pass', 'fail', or '' for all
    # Accept pre-normalized points directly (x_norm, y_norm already calculated by frontend)
    norm = []
    for p in pts:
        if 'x_norm' in p and 'y_norm' in p:
            norm.append({'x_norm': float(p['x_norm']), 'y_norm': float(p['y_norm']), 'positive': bool(p.get('positive',True))})
    if not norm: return {'error':'no_valid_points'}, 400
    tid = uuid.uuid4().hex
    ds['templates'][tid] = {'id': tid, 'name': name, 'class': template_class, 'points': norm, 'created_at': time.time()}
    return {'template_id': tid, 'name': name, 'class': template_class, 'count': len(norm)}

@app.route('/sam/dataset/templates', methods=['GET'])
def dataset_templates():
    ds_id = request.args.get('dataset_id','')
    ds = _DATASETS.get(ds_id)
    if not ds: return {'error':'dataset_not_found'}, 404
    return {'templates': [{'id':t['id'],'name':t['name'],'class':t.get('class',''),'points_count':len(t['points'])} for t in ds['templates'].values()]}

@app.route('/sam/dataset/point_preview', methods=['POST'])
def dataset_point_preview():
    """Generate SAM mask preview for current points (realtime feedback)."""
    data = request.get_json(force=True, silent=True) or {}
    ds_id = data.get('dataset_id')
    image_id = data.get('image_id')
    points = data.get('points', [])
    
    if not ds_id or not image_id or not points:
        return {'error':'dataset_id, image_id, and points required'}, 400
    
    ds = _DATASETS.get(ds_id)
    if not ds: return {'error':'dataset_not_found'}, 404
    
    if _SAM_PREDICTOR is None and not _load_sam_model('vit_b'):
        return {'error':'sam_model_not_loaded'}, 500
    
    # Find image
    img_meta = next((im for im in ds['images'] if im['id'] == image_id), None)
    if not img_meta: return {'error':'image_not_found'}, 404
    
    try:
        img = Image.open(img_meta['path']).convert('RGB')
        arr = np.array(img)
        
        # Optional downscale for preview speed (keeps aspect ratio, uses proper interpolation)
        # Previous implementation used np.resize which merely reshaped/repeated data and produced
        # unrealistic inputs causing the mask to frequently cover the whole image. Using a real
        # resample prevents that while still reducing compute on very large images.
        MAX_PREVIEW_DIM = 800
        h, w = arr.shape[:2]
        if max(h, w) > MAX_PREVIEW_DIM:
            scale = MAX_PREVIEW_DIM / max(h, w)
            new_w = int(w * scale)
            new_h = int(h * scale)
            try:
                resample = Image.Resampling.BILINEAR  # Pillow >= 9
            except AttributeError:  # Pillow < 9 fallback
                resample = Image.BILINEAR  # type: ignore
            img_small = img.resize((new_w, new_h), resample)
            arr = np.array(img_small)
            # Points are normalized (0-1) so no coordinate adjustment needed.
        
        # Use cache key for embedding reuse
        cache_key = f"{ds_id}_{image_id}_preview"
        mask, score = _predict_sam_mask(arr, points, cache_key=cache_key)
        if mask is None:
            return {'error':'segmentation_failed'}, 500
        
        # Encode mask as PNG (grayscale 0/255)
        mask_img = Image.fromarray((mask*255).astype(np.uint8), mode='L')
        buf = io.BytesIO()
        mask_img.save(buf, format='PNG')
        return {
            'mask_png': base64.b64encode(buf.getvalue()).decode('ascii'),
            'score': float(score) if score else 0.0
        }
    except Exception as e:
        return {'error': f'preview_failed:{e}'}, 500

@app.route('/sam/dataset/template/preview', methods=['POST'])
def dataset_template_preview():
    """Generate a preview of template applied to specific or first matching image."""
    data = request.get_json(force=True, silent=True) or {}
    ds_id = data.get('dataset_id')
    if not ds_id: return {'error':'dataset_id_required'}, 400
    ds = _DATASETS.get(ds_id)
    if not ds: return {'error':'dataset_not_found'}, 404
    if not ds['templates']: return {'error':'no_templates'}, 400
    if _SAM_PREDICTOR is None and not _load_sam_model('vit_b'):
        return {'error':'sam_model_not_loaded'}, 500
    
    edits = data.get('edits', {})
    if not ds['images']: return {'error':'no_images'}, 400
    
    # Use specified image or find first matching by class filter
    target_img = None
    image_id = data.get('image_id')
    class_filter = data.get('class_filter', '').lower()
    
    if image_id:
        target_img = next((im for im in ds['images'] if im['id'] == image_id), None)
    elif class_filter:
        target_img = next((im for im in ds['images'] if class_filter in im['filename'].lower()), None)
    
    if not target_img:
        target_img = ds['images'][0]
    
    first_img = target_img
    
    try:
        img = Image.open(first_img['path']).convert('RGB')
        arr = np.array(img)
        # Apply templates with class filtering - use cache key for embedding reuse
        cache_key = f"{ds_id}_template_preview_{first_img['id']}"
        edited, _ = _apply_templates_with_class_filter(arr, ds['templates'], edits, first_img['filename'], cache_key=cache_key)
        buf = io.BytesIO()
        Image.fromarray(edited).save(buf, format='PNG')
        return {
            'variant_png': base64.b64encode(buf.getvalue()).decode('ascii'),
            'filename': first_img['filename']
        }
    except Exception as e:
        return {'error': f'preview_failed:{e}'}, 500

def _apply_templates_with_class_filter(arr: np.ndarray, templates: Dict[str, Dict[str,Any]], edits: Dict[str, Dict[str,Any]], filename: str, cache_key: Optional[str] = None):
    """Apply templates with class-based filtering (pass/fail)."""
    out = arr.copy()
    cumulative = None
    
    # Determine image class from filename
    filename_lower = filename.lower()
    image_class = None
    if 'pass' in filename_lower:
        image_class = 'pass'
    elif 'fail' in filename_lower:
        image_class = 'fail'
    
    for tid, tpl in templates.items():
        template_class = tpl.get('class', '')
        # Skip if template has class filter and doesn't match image
        if template_class and image_class and template_class != image_class:
            continue
        
        if edits and tid not in edits:
            continue
        mask, score = _predict_sam_mask(out, tpl['points'], cache_key=cache_key)
        if mask is None:
            continue
        comp_mask = np.zeros(mask.shape, dtype=np.uint8)
        comp_mask[mask] = 1
        edit_vals = edits.get(tid, {}) if edits else {}
        payload = [{
            'id': 1,
            'brightness': edit_vals.get('brightness', 0),
            'contrast': edit_vals.get('contrast', 0),
            'gamma': edit_vals.get('gamma', 0),
            'hue': edit_vals.get('hue'),
            'saturation': edit_vals.get('saturation'),
            'sharpen': edit_vals.get('sharpen', 0),
            'noise': edit_vals.get('noise', 0)
        }]
        edited = apply_edits(out, mask, comp_mask, payload)
        op = edit_vals.get('opacity')
        if op is not None:
            try:
                ov = float(op)
            except (TypeError, ValueError):
                ov = 1.0
            ov = max(0.0, min(1.0, ov))
            if ov < 1.0:
                region = mask
                blend = (ov * edited[region].astype(np.float32) + (1-ov) * out[region].astype(np.float32)).astype(np.uint8)
                edited[region] = blend
        out = edited
        cumulative = mask if cumulative is None else (cumulative | mask)
    return out, cumulative

@app.route('/sam/dataset/apply_stream', methods=['POST'])
def dataset_apply_stream():
    payload = request.get_json(force=True, silent=True) or {}
    ds_id = payload.get('dataset_id') or request.args.get('dataset_id')
    if not ds_id: return {'error':'dataset_id_required'}, 400
    ds = _DATASETS.get(ds_id)
    if not ds: return {'error':'dataset_not_found'}, 404
    edits = payload.get('edits', {})
    export_mask = bool(payload.get('export_mask', False))
    if _SAM_PREDICTOR is None and not _load_sam_model('vit_b'):
        return {'error':'sam_model_not_loaded'}, 500
    images = ds['images']
    if not ds['templates']: return {'error':'no_templates'}, 400
    def _stream():
        total = len(images)
        for idx, im in enumerate(images):
            start = time.time()
            out = {'index': idx, 'total': total, 'filename': im['filename'], 'image_id': im['id']}
            try:
                img = Image.open(im['path']).convert('RGB')
                arr = np.array(img)
                # Apply templates with class filtering - use cache key for embedding reuse
                cache_key = f"{ds_id}_gen_{im['id']}"
                edited, cum_mask = _apply_templates_with_class_filter(arr, ds['templates'], edits, im['filename'], cache_key=cache_key)
                buf = io.BytesIO(); Image.fromarray(edited).save(buf, format='PNG')
                out['variant_png'] = base64.b64encode(buf.getvalue()).decode('ascii')
                if export_mask and cum_mask is not None:
                    mb = io.BytesIO(); Image.fromarray((cum_mask*255).astype(np.uint8)).save(mb, format='PNG')
                    out['mask_png'] = base64.b64encode(mb.getvalue()).decode('ascii')
                out['ms'] = int((time.time()-start)*1000)
            except Exception as e:
                out['error'] = str(e)
            yield f'data: {json.dumps(out,separators=(",",":"))}\n\n'
        yield 'data: {"done":true}\n\n'
    return Response(stream_with_context(_stream()), headers={'Content-Type':'text/event-stream','Cache-Control':'no-cache'})


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001, debug=True)
