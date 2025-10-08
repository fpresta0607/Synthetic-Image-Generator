# Image Deduplication & Smart Caching

## Overview
Enhanced the system with **automatic image deduplication** and **persistent embedding cache tracking** to dramatically speed up repeated uploads and avoid redundant pre-warming.

## What Was Added

### 1. Database Schema Enhancements (`py/db.py`)

Added two new fields to the `Image` table:

```python
content_hash: Mapped[Optional[str]]        # SHA256 hash of image content
embedding_cached: Mapped[Optional[bool]]   # Whether SAM embedding is cached
```

**New Functions:**
- `find_image_by_hash(content_hash)` - Check if image already has cached embeddings
- `mark_embedding_cached(dataset_id, image_id, cached)` - Mark embedding status
- `get_cached_images_count(dataset_id)` - Count pre-cached images

### 2. Upload Deduplication (`py/app.py`)

**During Upload (`/sam/dataset/init`):**
1. Computes SHA256 hash of each uploaded image
2. Checks database for existing images with same hash
3. If found with cached embeddings, marks as `embedding_cached=1`
4. Returns duplicate count to frontend

```python
# Compute content hash for deduplication
with open(p, 'rb') as f:
    content_hash = hashlib.sha256(f.read()).hexdigest()

# Check if this image already has cached embeddings
existing = _db.find_image_by_hash(content_hash)
if existing and existing['embedding_cached']:
    duplicate_count += 1
    embedding_cached = 1
```

**Response Example:**
```json
{
  "dataset_id": "abc123",
  "images": [...],
  "duplicates_found": 15,
  "duplicates_message": "15 image(s) already cached, prewarm will be faster"
}
```

### 3. Smart Pre-warming (`/sam/dataset/prewarm`)

**Enhanced Algorithm:**
1. Uses **content hash as global cache key** (works across all datasets)
2. **Skips images** that already have embeddings cached
3. Tracks `computed` vs `skipped` counts
4. Marks newly computed embeddings in database

```python
# Use content hash as global cache key
content_hash = im.get('content_hash')
cache_key = f"hash_{content_hash}" if content_hash else f"{ds_id}_img_{im['id']}"

# Skip if already cached
if cache_key in _EMBEDDING_CACHE:
    skipped += 1
    yield {"skipped": true, ...}
    continue

# Otherwise compute and cache
_SAM_PREDICTOR.set_image(arr)
_EMBEDDING_CACHE[cache_key] = _SAM_PREDICTOR.features
_db.mark_embedding_cached(ds_id, im['id'], True)
computed += 1
```

**SSE Stream Response:**
```json
// During processing
{"index": 5, "total": 50, "filename": "img.jpg", "skipped": true, "ms": 5}
{"index": 6, "total": 50, "filename": "img2.jpg", "computed": true, "ms": 18500}

// Final
{"done": true, "total": 50, "computed": 35, "skipped": 15, "cache_size": 150}
```

### 4. Global Cache Keys

**Before (dataset-specific):**
```python
cache_key = f"{ds_id}_img_{image_id}"  # Each dataset had separate cache
```

**After (content-based):**
```python
cache_key = f"hash_{content_hash}"  # Same image = same cache across datasets
```

**Applied to all endpoints:**
- `/sam/dataset/prewarm` - Pre-warming
- `/sam/dataset/point_preview` - Point prompts
- `/sam/dataset/template/preview` - Template preview
- `/sam/dataset/apply_stream` - Bulk generation

### 5. Frontend Updates (`server/public/`)

**Upload Feedback:**
```javascript
if (data.duplicates_found > 0) {
  datasetStatus.textContent = `✓ ${data.duplicates_message}`;
}
```

**Smart Progress Display:**
```javascript
// Shows different status for skipped vs computed
const statusIcon = obj.skipped ? '⚡' : '⏳';
const action = obj.skipped ? 'skipped (cached)' : 'computing';
prewarmTitle.textContent = `${statusIcon} Pre-warming cache... ${completed}/${total}`;
```

**Final Summary:**
```
Dataset ready (cache: 150 embeddings, computed: 35, skipped: 15)
```

## Benefits

### 🚀 Performance Improvements

**First Upload (50 images):**
```
Upload: 2s
Prewarm: 15 minutes (50 images × 18s each)
Total: ~15m 2s
```

**Second Upload (same 50 images):**
```
Upload: 2s (detects duplicates)
Prewarm: 5s (all 50 images skipped!)
Total: ~7s
```

**Partial Overlap (25 new, 25 duplicates):**
```
Upload: 2s
Prewarm: 7m 35s (25 computed, 25 skipped)
Total: ~7m 37s (50% time saved!)
```

### 💡 Use Cases

1. **Re-uploading Test Datasets**: Instant prewarm if images unchanged
2. **Multiple Projects with Shared Images**: Global cache works across all datasets
3. **Iterative Template Development**: Upload → Test → Delete → Re-upload = fast!
4. **Dataset Versioning**: Only new images are computed
5. **Team Collaboration**: If teammate already uploaded images, yours skip prewarm

### 📊 Cache Efficiency

**Before:**
- Cache key: `dataset123_img_abc456`
- Same image in different datasets = computed twice
- No persistence tracking

**After:**
- Cache key: `hash_sha256...`
- Same image anywhere = computed once
- Database tracks which images are cached
- Pre-warm skips already-cached images

## Database Migration

### Automatic Migration
The system automatically creates new columns on startup. For existing databases:

```sql
-- SQLite migration
ALTER TABLE images ADD COLUMN content_hash VARCHAR(64);
ALTER TABLE images ADD COLUMN embedding_cached INTEGER DEFAULT 0;
CREATE INDEX idx_content_hash ON images(content_hash);

-- For existing images, hashes will be computed on next upload
```

### Manual Migration (Optional)
If you want to hash existing images:

```python
import hashlib
from py.db import Session, _ENGINE, Image

with Session(_ENGINE) as s:
    images = s.query(Image).filter(Image.content_hash == None).all()
    for img in images:
        try:
            with open(img.path, 'rb') as f:
                img.content_hash = hashlib.sha256(f.read()).hexdigest()
        except Exception as e:
            print(f"Failed to hash {img.filename}: {e}")
    s.commit()
```

## Testing

### Test Deduplication

1. **Upload Dataset:**
   ```bash
   # Upload 10 images
   curl -F "images=@img1.jpg" ... http://localhost:3000/api/sam/dataset/init
   ```
   
   Response:
   ```json
   {"dataset_id": "abc123", "duplicates_found": 0}
   ```

2. **Re-upload Same Images:**
   ```bash
   # Upload same 10 images again
   curl -F "images=@img1.jpg" ... http://localhost:3000/api/sam/dataset/init
   ```
   
   Response:
   ```json
   {
     "dataset_id": "def456",
     "duplicates_found": 10,
     "duplicates_message": "10 image(s) already cached, prewarm will be faster"
   }
   ```

3. **Check Prewarm Speed:**
   - First dataset: 10 images × 18s = ~3 minutes
   - Second dataset: 10 images × 0.01s = ~0.1 seconds (all skipped!)

### Verify Cache Keys

Check logs during generation:
```
[SAM] Predicted mask in 18.5s (cache_hit=False)  # First time
[SAM] Predicted mask in 1.2s (cache_hit=True)    # Second time (hash-based)
```

## Configuration

### Environment Variables

```bash
# Enable database (required for persistence)
DATABASE_URL=sqlite:///data/app.db

# Cache settings
EMBED_CACHE_MAX=2000  # Max embeddings in memory
```

### Adjusting Cache Size

If you have lots of RAM and want to cache more:

```python
# py/app.py
_EMBED_CACHE_MAX = int(os.environ.get('EMBED_CACHE_MAX', '5000'))
```

With 12GB RAM: `5000 embeddings × ~40MB = ~200GB` theoretical max (actual much less)

## Monitoring

### Check Database

```sql
-- Count images with cached embeddings
SELECT COUNT(*) FROM images WHERE embedding_cached = 1;

-- Find duplicate images
SELECT content_hash, COUNT(*) as cnt 
FROM images 
WHERE content_hash IS NOT NULL
GROUP BY content_hash 
HAVING cnt > 1;

-- Total cache coverage
SELECT 
  COUNT(*) as total_images,
  SUM(CASE WHEN embedding_cached = 1 THEN 1 ELSE 0 END) as cached,
  ROUND(100.0 * SUM(CASE WHEN embedding_cached = 1 THEN 1 ELSE 0 END) / COUNT(*), 2) as pct_cached
FROM images;
```

### Check Logs

```bash
# Watch for deduplication
aws logs tail /ecs/photosynth-full --follow | grep "DEDUP"

# Output:
[DEDUP] Found duplicate image: img1.jpg (hash: a3f21b8c..., cached: True)
```

### Memory Usage

```python
# Check embedding cache size
import sys
print(f"Cache entries: {len(_EMBEDDING_CACHE)}")
print(f"Approx size: {sys.getsizeof(_EMBEDDING_CACHE) / 1024 / 1024:.1f} MB")
```

## Troubleshooting

### Issue: Duplicates Not Detected

**Symptoms:**
- Upload same images, no "duplicates_found" message
- Prewarm doesn't skip any images

**Solutions:**
1. Check database is enabled: `_USE_DB=True`
2. Verify images actually identical (same bytes)
3. Check database has content_hash column
4. Look for errors in logs: `grep "DEDUP" logs.txt`

### Issue: Cache Not Persisting

**Symptoms:**
- Restart server, all images need prewarm again
- `embedding_cached` always 0 in database

**Solutions:**
1. Database tracks metadata, not actual embeddings (by design)
2. Embeddings stored in-memory `_EMBEDDING_CACHE` (cleared on restart)
3. If cache is cleared, prewarm will recompute but detect duplicates
4. For true persistence, would need to serialize torch tensors (complex)

### Issue: Out of Memory

**Symptoms:**
- Server crashes after pre-warming many images
- `EMBED_CACHE_MAX` reached frequently

**Solutions:**
1. Reduce `EMBED_CACHE_MAX` to lower value
2. Increase ECS task memory allocation
3. Restart tasks periodically to clear cache
4. Use smaller images (`DOWNSCALE_MAX=1024`)

## Future Enhancements

### Potential Improvements

1. **Persistent Embedding Storage**: Serialize embeddings to disk/S3
2. **LRU Cache with Time-to-Live**: Auto-expire old embeddings
3. **Perceptual Hashing**: Detect similar (not just identical) images
4. **Redis Cache**: Share embeddings across multiple instances
5. **Compression**: Store embeddings in compressed format
6. **Lazy Loading**: Load embeddings from disk on-demand

### Example: Redis Integration

```python
import redis
import pickle

_REDIS = redis.Redis(host='localhost', port=6379)

def _get_embedding(cache_key):
    # Try memory first
    if cache_key in _EMBEDDING_CACHE:
        return _EMBEDDING_CACHE[cache_key]
    
    # Try Redis
    data = _REDIS.get(cache_key)
    if data:
        features = pickle.loads(data)
        _EMBEDDING_CACHE[cache_key] = features
        return features
    
    return None

def _set_embedding(cache_key, features):
    _EMBEDDING_CACHE[cache_key] = features
    _REDIS.set(cache_key, pickle.dumps(features), ex=86400)  # 24h TTL
```

## Summary

This feature adds **intelligent deduplication** that:
- ✅ Detects duplicate images on upload
- ✅ Skips pre-warming for already-cached images
- ✅ Uses content-based cache keys (works across datasets)
- ✅ Tracks cache status in database
- ✅ Shows detailed progress (computed vs skipped)
- ✅ Can save 50-100% of prewarm time for repeated images

**Expected Impact:**
- First upload: No change (all images computed)
- Repeated uploads: 90-99% faster prewarm (skip cached images)
- Mixed uploads: Proportional speedup (only compute new images)
- User experience: Clear feedback on cache efficiency
