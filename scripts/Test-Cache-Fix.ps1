# Quick test of cache fix with local GPU
# This tests if the cache key fix actually improves performance

Write-Host "==> Testing Cache Fix Locally" -ForegroundColor Cyan
Write-Host "    GPU: RTX 4000 Ada" -ForegroundColor Green

# Check if venv-gpu is ready
if (-not (Test-Path "venv-gpu\Scripts\python.exe")) {
    Write-Host "ERROR: venv-gpu not found. Run setup first." -ForegroundColor Red
    Write-Host "  .\scripts\Setup-Local-GPU.ps1" -ForegroundColor Yellow
    exit 1
}

# Set GPU environment variables
$env:WARM_MODEL = "1"
$env:SAM_FP16 = "1"
$env:CUDA_VISIBLE_DEVICES = "0"
$env:EMBED_CACHE_MAX = "2000"

Write-Host "`n[Test] Starting Python backend with cache fix..." -ForegroundColor Yellow
Write-Host "  Environment: WARM_MODEL=1, SAM_FP16=1, EMBED_CACHE_MAX=2000" -ForegroundColor Gray
Write-Host "`n  Watch for cache_hit=True in logs!" -ForegroundColor Cyan
Write-Host "  First request: ~20s (cache_hit=False)" -ForegroundColor Gray
Write-Host "  Second request same image: ~1-3s (cache_hit=True)" -ForegroundColor Green
Write-Host "`n  Server will start at http://localhost:5001" -ForegroundColor Gray
Write-Host "  Press Ctrl+C to stop" -ForegroundColor Gray
Write-Host "`n" -ForegroundColor Gray

# Start Flask backend
try {
    & .\venv-gpu\Scripts\python.exe py\app.py
} catch {
    Write-Host "`nERROR: $_" -ForegroundColor Red
}
