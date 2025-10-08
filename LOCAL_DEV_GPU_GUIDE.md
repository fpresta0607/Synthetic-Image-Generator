# Local Development with GPU Guide

## Quick Start (GPU-Enabled)

### Prerequisites
- ✅ NVIDIA RTX 4000 Ada GPU (12GB VRAM)
- ✅ CUDA 12.1+ installed
- ✅ Python 3.9+ 
- ✅ Node.js 18+
- ✅ Git

### One-Command Start
```powershell
npm run dev:gpu
```

This will:
1. ✅ Detect your NVIDIA GPU
2. ✅ Create Python virtual environment (`.venv-gpu`)
3. ✅ Install PyTorch with CUDA 12.1 support
4. ✅ Install all dependencies (takes 5-10 min first time)
5. ✅ Start Flask backend with GPU acceleration
6. ✅ Start Node.js proxy server
7. ✅ Open http://localhost:3000

## What You'll See

### Successful GPU Startup
```
============================================================
GPU-Enabled Local Development
============================================================
[dev-gpu] ✅ NVIDIA GPU detected
[dev-gpu] nvidia-smi output:
+-------------------------------------------------------------------------+
| NVIDIA-SMI 566.03                 Driver Version: 566.03     CUDA Version: 12.8  |
|-------------------------------+----------------------+----------------------+
| GPU  Name                      | Bus-Id           | Volatile Uncorr. ECC |
| 0    NVIDIA RTX 4000 Ada       | 00000000:01:00.0 |                  N/A |
+-------------------------------------------------------------------------+

[dev-gpu] GPU venv ready!
[dev-gpu] Installing GPU dependencies from requirements-sam-gpu.txt
[dev-gpu] This may take 5-10 minutes on first run...

[dev-gpu] ✅ PyTorch verification:
PyTorch: 2.3.1+cu121
CUDA available: True
CUDA device: NVIDIA RTX 4000 Ada Generation

[SAM] Loaded model 'vit_b' from C:\Users\fpresta\...\sam_vit_b.pth on cuda
[dev-gpu] ✅ Flask backend ready!
[dev-gpu] Starting Node proxy...

============================================================
🚀 Development servers running:
   Flask (GPU): http://localhost:5001
   Node Proxy:  http://localhost:3000
============================================================
```

### Performance Comparison

| Operation | CPU (Fargate) | Local GPU | Speedup |
|-----------|---------------|-----------|---------|
| First embedding | 18-20s | **1-2s** | **10-15x faster** |
| Cached embedding | 1-3s | **0.1-0.5s** | **5-10x faster** |
| Prewarm 50 images | 15 min | **1-2 min** | **7-10x faster** |

## Troubleshooting

### Issue 1: Missing npm packages
**Error:**
```
Error [ERR_MODULE_NOT_FOUND]: Cannot find package '@aws-sdk/client-s3'
```

**Fix:**
```powershell
cd server
npm install
cd ..
npm run dev:gpu
```

### Issue 2: CUDA not detected
**Error:**
```
[dev-gpu] ⚠️  nvidia-smi not found - GPU may not be available
PyTorch: 2.3.1+cu121
CUDA available: False
```

**Fixes:**
1. **Install NVIDIA drivers:**
   - Download from: https://www.nvidia.com/download/index.aspx
   - Select: RTX 4000 Ada Generation
   - Install and reboot

2. **Install CUDA Toolkit 12.1+:**
   - Download from: https://developer.nvidia.com/cuda-downloads
   - Install and add to PATH

3. **Verify installation:**
   ```powershell
   nvidia-smi
   # Should show GPU info
   ```

### Issue 3: PyTorch DLL errors
**Error:**
```
OSError: [WinError 126] The specified module could not be found
```

**Fix:**
1. Install Visual C++ Redistributable:
   - Download: https://aka.ms/vs/17/release/vc_redist.x64.exe
   - Install and reboot

2. Reinstall PyTorch:
   ```powershell
   cd py
   .\.venv-gpu\Scripts\activate
   pip uninstall torch torchvision torchaudio
   pip install --upgrade pip
   pip install -r requirements-sam-gpu.txt
   ```

### Issue 4: Out of memory
**Error:**
```
RuntimeError: CUDA out of memory
```

**Fixes:**
1. **Reduce batch size** - Edit `py/app.py`:
   ```python
   GEN_MAX_WORKERS = int(os.environ.get('GEN_MAX_WORKERS', '1'))  # Change from 2
   ```

2. **Enable FP16** - Add to environment:
   ```powershell
   $env:SAM_FP16 = "1"
   npm run dev:gpu
   ```

3. **Reduce image size** - Edit `py/app.py`:
   ```python
   DOWNSCALE_MAX = int(os.environ.get('DOWNSCALE_MAX', '1024'))  # Change from 2048
   ```

### Issue 5: Port already in use
**Error:**
```
Error: listen EADDRINUSE: address already in use :::3000
```

**Fix:**
```powershell
# Find and kill process using port 3000
netstat -ano | findstr :3000
taskkill /PID <PID> /F

# Or change port
$env:PORT = "3001"
npm run dev:gpu
```

## Environment Variables

### GPU Configuration
```powershell
# Force CUDA device (default: auto-detect)
$env:SAM_DEVICE = "cuda"

# Enable half precision for 2x memory savings
$env:SAM_FP16 = "1"

# Select specific GPU (if you have multiple)
$env:CUDA_VISIBLE_DEVICES = "0"

# Set CUDA architecture for your GPU
$env:TORCH_CUDA_ARCH_LIST = "8.9"  # RTX 4000 Ada
```

### Application Settings
```powershell
# Pre-warm model on startup
$env:WARM_MODEL = "1"

# Max concurrent workers
$env:GEN_MAX_WORKERS = "2"

# Image downscale limit
$env:DOWNSCALE_MAX = "2048"

# Cache size
$env:EMBED_CACHE_MAX = "2000"

# Enable database
$env:USE_DB = "1"
$env:DATABASE_URL = "sqlite:///data/app.db"
```

## CPU Development (Fallback)

If GPU isn't working, use regular dev mode:
```powershell
npm run dev
```

This uses:
- CPU-only PyTorch
- Slower inference (18-20s per image)
- Lower memory usage
- No CUDA required

## File Structure

```
Synthetic0/
├── py/
│   ├── .venv/           # CPU virtual environment
│   ├── .venv-gpu/       # GPU virtual environment (created by dev:gpu)
│   ├── app.py           # Flask backend (auto-detects GPU)
│   ├── requirements-sam.txt      # CPU dependencies
│   └── requirements-sam-gpu.txt  # GPU dependencies (CUDA 12.1)
├── server/
│   ├── scripts/
│   │   ├── dev.mjs      # CPU dev script
│   │   └── dev-gpu.mjs  # GPU dev script
│   ├── server.js        # Node.js proxy
│   └── package.json
└── package.json         # Root scripts
```

## Testing GPU Performance

### 1. Upload Test Dataset
```powershell
# Open browser to http://localhost:3000
# Upload 10-20 images
# Watch console for GPU usage
```

### 2. Check GPU Utilization
```powershell
# In another terminal
nvidia-smi -l 1  # Update every 1 second
```

Expected output during inference:
```
+-------------------------------------------------------------------------+
| Processes:                                                              |
|  GPU   GI   CI        PID   Type   Process name              GPU Memory |
|        ID   ID                                                Usage      |
|=========================================================================|
|    0   N/A  N/A      12345    C   python.exe                  ~2000MiB  |
+-------------------------------------------------------------------------+
```

### 3. Benchmark Prewarm Speed
```powershell
# Time to prewarm 50 images:
# CPU: ~15 minutes (18s per image)
# GPU: ~1-2 minutes (1-2s per image)
```

## Development Workflow

### Daily Development
```powershell
# 1. Start servers
npm run dev:gpu

# 2. Make changes to code
# - py/app.py for backend
# - server/public/*.{html,js,css} for frontend

# 3. Backend auto-reloads (Flask debug mode)
# 4. Frontend: refresh browser

# 5. Stop servers: Ctrl+C
```

### Database Migrations
```powershell
# Run migration for deduplication feature
python scripts/migrate_database.py
```

### Testing Deduplication
```powershell
# 1. Upload images
# 2. Wait for prewarm
# 3. Upload SAME images again
# 4. Should see: "X image(s) already cached, prewarm will be faster"
# 5. Prewarm should skip cached images (instant)
```

## Common Commands

```powershell
# Start with GPU
npm run dev:gpu

# Start with CPU
npm run dev

# Install dependencies
npm install

# Install Python GPU dependencies
cd py
.\.venv-gpu\Scripts\activate
pip install -r requirements-sam-gpu.txt

# Check GPU status
nvidia-smi

# Monitor GPU usage live
nvidia-smi -l 1

# Run database migration
python scripts/migrate_database.py

# Build Docker image
docker build -t photosynth-full:local .

# Test Docker image locally
docker run -p 3000:3000 --gpus all photosynth-full:local
```

## Next Steps

1. ✅ Start development server: `npm run dev:gpu`
2. ✅ Open browser: http://localhost:3000
3. ✅ Upload test images and verify GPU acceleration
4. ✅ Make code changes and test
5. ✅ Check logs for `[DEDUP]` and `cache_hit=True` messages
6. ✅ Deploy to Fargate when ready: `.\scripts\Deploy-Dedup-Feature.ps1`

## Support

- **GPU Issues**: Check NVIDIA drivers and CUDA toolkit
- **Python Issues**: Verify Python 3.9+ installed
- **Node Issues**: Verify Node.js 18+ installed
- **Port Conflicts**: Change PORT environment variable

Your laptop's **RTX 4000 Ada** is perfect for this - expect **10-15x faster** inference compared to Fargate CPU! 🚀
