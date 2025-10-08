# How to Speed Up First Request

## The Problem
The first SAM request takes **18-20 seconds** because it must compute **image embeddings** (`set_image()` call). These embeddings are then cached, making subsequent requests on the same image ~1-3 seconds.

## Solutions (From Easiest to Most Complex)

### ✅ Option 1: Pre-Warm Cache (IMPLEMENTED - Do This!)

**What it does**: After uploading images, automatically compute embeddings for all images in the background.

**Changes made**:
- Added `/sam/dataset/prewarm` endpoint (streams progress)
- Frontend automatically calls this after `dataset/init`
- Users see "Pre-warming cache... 15/50" progress

**Result**:
- First preview/generate: **1-3 seconds** (cache hit!) ✅
- No user action needed - happens automatically

**Deploy**: Already in your code! Just rebuild and deploy:
```powershell
docker build -f Dockerfile -t photosynth-full:prewarm --target full .
.\scripts\Deploy.ps1 -ImageTag prewarm
```

---

### Option 2: Use GPU (Hardware Acceleration)

**What it does**: GPU computes embeddings ~10x faster than CPU

**Result**:
- First request: **2-3 seconds** (vs 20s on CPU)
- Cached requests: **0.3-0.5 seconds** (vs 1-3s on CPU)

**Cost**: 
- Local: $0 (you have RTX 4000 Ada)
- Fargate GPU: ~$1/hour (expensive!)
- EC2 g4dn.xlarge: $0.30/hour spot

**Recommendation**: Test locally first, then use EC2 if needed (not Fargate GPU - too expensive)

---

### Option 3: Reduce Image Resolution

**What it does**: Downscale images before processing

**Current**: `DOWNSCALE_MAX=2048` (already optimized)

**Try**: Lower to 1600 or 1200 pixels
```python
DOWNSCALE_MAX = 1600  # In py/app.py or env var
```

**Result**:
- First request: **12-15 seconds** (vs 20s)
- Some accuracy loss on very fine details

---

### Option 4: Use Smaller SAM Model

**What it does**: Use ViT-Tiny instead of ViT-Base

**Changes**:
```bash
# Download smaller model (~40MB vs 375MB)
wget https://dl.fbaipublicfiles.com/segment_anything/sam_vit_t_01ec64.pth -O models/sam_vit_t.pth

# Update environment
SAM_MODEL_TYPE=vit_t
SAM_CHECKPOINT=models/sam_vit_t.pth
```

**Result**:
- First request: **8-10 seconds** (2-3x faster)
- Slightly lower accuracy (~5-10%)

**Recommendation**: Only if Option 1 (prewarm) isn't fast enough

---

### Option 5: Lazy Loading (Advanced)

**What it does**: Start showing UI immediately, compute embeddings only when user clicks

**Implementation**:
- Don't prewarm automatically
- Add "Prepare Image" button that users click before adding points
- Show spinner during embedding computation

**Result**:
- App feels instant (no wait after upload)
- Users wait 20s only when they interact with specific images

---

## Recommended Approach

**Best solution**: Use **Option 1 (Pre-warm)** + **Option 2 (GPU locally)**

1. **Deploy pre-warm now** (already in your code):
   ```powershell
   .\scripts\Deploy-Cache-Fix.ps1  # Includes prewarm
   ```

2. **Test GPU locally** for development:
   ```powershell
   # Fix the PyTorch CUDA install issue
   .\venv-gpu\Scripts\pip.exe uninstall torch torchvision torchaudio
   .\venv-gpu\Scripts\pip.exe install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
   
   # Run locally
   .\scripts\Test-Cache-Fix.ps1
   ```

3. **For production**: Keep using Fargate CPU with pre-warm
   - Cost: ~$50-100/month (vs $700+/month for Fargate GPU)
   - Performance: Good enough with cache (1-3s per image after prewarm)

## Expected Performance

### Before (no cache fix, no prewarm):
- Every request: **20 seconds** ❌

### After (cache fix only):
- First request: **20 seconds**
- Same image: **1-3 seconds** ✅

### After (cache fix + prewarm):
- Upload completes: **Wait 5-10 minutes** for prewarm
- All requests: **1-3 seconds** ✅✅

### With GPU + cache + prewarm:
- Upload completes: **Wait 1-2 minutes** for prewarm
- All requests: **0.3-0.5 seconds** ✅✅✅

## Testing the Prewarm Feature

After deploying, test the workflow:

1. Upload dataset (10-50 images)
2. Watch status: "Pre-warming cache... 15/50"
3. Wait for "Dataset ready (cache pre-warmed: 50 embeddings)"
4. Create template - should be **instant** (1-3s)
5. Generate variants - should be **instant** (1-3s per image)

Check logs:
```powershell
aws logs tail /ecs/photosynth-full --follow --region us-east-1 | Select-String "cache_hit"
```

Should see mostly `cache_hit=True` after prewarm!
