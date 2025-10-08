# Run the application locally with GPU acceleration

Write-Host "==> Starting PhotoSynth with GPU Acceleration" -ForegroundColor Cyan

# Check if venv-gpu exists
if (-not (Test-Path "venv-gpu\Scripts\python.exe")) {
    Write-Host "ERROR: GPU environment not found!" -ForegroundColor Red
    Write-Host "Run setup first: .\scripts\Setup-Local-GPU.ps1" -ForegroundColor Yellow
    exit 1
}

# Set environment variables for GPU
$env:WARM_MODEL = "1"
$env:SAM_FP16 = "1"
$env:CUDA_VISIBLE_DEVICES = "0"
$env:GEN_MAX_WORKERS = "4"
$env:MODEL_CACHE_SIZE = "5000"

Write-Host "Environment:" -ForegroundColor Gray
Write-Host "  WARM_MODEL: $env:WARM_MODEL" -ForegroundColor Gray
Write-Host "  SAM_FP16: $env:SAM_FP16" -ForegroundColor Gray
Write-Host "  CUDA_VISIBLE_DEVICES: $env:CUDA_VISIBLE_DEVICES" -ForegroundColor Gray
Write-Host "  GEN_MAX_WORKERS: $env:GEN_MAX_WORKERS" -ForegroundColor Gray
Write-Host ""

# Start Node.js server in background
Write-Host "[1/2] Starting Node.js server..." -ForegroundColor Yellow
Push-Location server
$nodeJob = Start-Job -ScriptBlock {
    param($serverPath)
    Set-Location $serverPath
    npm start
} -ArgumentList (Get-Location).Path
Pop-Location
Write-Host "    Node.js server starting (PID: $($nodeJob.Id))..." -ForegroundColor Green

# Give Node.js a moment to start
Start-Sleep -Seconds 2

# Start Python backend with GPU
Write-Host "`n[2/2] Starting Python backend with GPU..." -ForegroundColor Yellow
Write-Host "    Check logs for 'on cuda' to confirm GPU usage" -ForegroundColor Gray
Write-Host ""

try {
    .\venv-gpu\Scripts\python.exe py\app.py
} finally {
    Write-Host "`n==> Stopping services..." -ForegroundColor Yellow
    Stop-Job $nodeJob
    Remove-Job $nodeJob
}
