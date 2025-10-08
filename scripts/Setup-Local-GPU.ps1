# Local GPU Setup Script for Windows
# This sets up your local environment to use your RTX 4000 Ada GPU

Write-Host "==> Setting up Local GPU Environment" -ForegroundColor Cyan
Write-Host "    GPU: NVIDIA RTX 4000 Ada (12GB)" -ForegroundColor Green
Write-Host "    CUDA: 12.8" -ForegroundColor Green

# Check if Python 3.11 is available
$python311Paths = @(
    "C:\Python311\python.exe",
    "C:\Program Files\Python311\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
)

$python311 = $null
foreach ($path in $python311Paths) {
    if (Test-Path $path) {
        $python311 = $path
        break
    }
}

if (-not $python311) {
    Write-Host "`nERROR: Python 3.11 not found!" -ForegroundColor Red
    Write-Host "PyTorch doesn't support Python 3.13 yet." -ForegroundColor Yellow
    Write-Host "`nPlease install Python 3.11 from:" -ForegroundColor Yellow
    Write-Host "https://www.python.org/downloads/release/python-3118/" -ForegroundColor Cyan
    Write-Host "`nOr use this direct link:" -ForegroundColor Yellow
    Write-Host "https://www.python.org/ftp/python/3.11.8/python-3.11.8-amd64.exe" -ForegroundColor Cyan
    exit 1
}

Write-Host "`n[1/5] Found Python 3.11: $python311" -ForegroundColor Green

# Create virtual environment
Write-Host "`n[2/5] Creating virtual environment..." -ForegroundColor Yellow
if (Test-Path "venv-gpu") {
    Write-Host "    Removing existing venv-gpu..." -ForegroundColor Gray
    Remove-Item -Recurse -Force "venv-gpu"
}

& $python311 -m venv venv-gpu
Write-Host "    Created: venv-gpu" -ForegroundColor Green

# Activate and upgrade pip
Write-Host "`n[3/5] Upgrading pip..." -ForegroundColor Yellow
& .\venv-gpu\Scripts\python.exe -m pip install --upgrade pip

# Install PyTorch with CUDA 12.1 support (compatible with CUDA 12.8)
Write-Host "`n[4/5] Installing PyTorch with CUDA support..." -ForegroundColor Yellow
Write-Host "    This will download ~2.5GB. Please wait..." -ForegroundColor Gray

& .\venv-gpu\Scripts\pip.exe install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# Install application dependencies
Write-Host "`n[5/5] Installing application dependencies..." -ForegroundColor Yellow

$packages = @(
    "flask==3.0.3",
    "numpy==1.26.4",
    "scikit-image==0.23.2",
    "Pillow==10.3.0",
    "SQLAlchemy==2.0.32",
    "alembic==1.13.2",
    "opencv-python==4.10.0.84",
    "requests==2.32.3",
    "boto3==1.34.127",
    "gunicorn==22.0.0",
    "waitress==3.0.0",
    "git+https://github.com/facebookresearch/segment-anything.git"
)

foreach ($package in $packages) {
    Write-Host "    Installing $package..." -ForegroundColor Gray
    & .\venv-gpu\Scripts\pip.exe install $package --quiet
}

Write-Host "`n==> Testing GPU Access..." -ForegroundColor Cyan

$testScript = @"
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'CUDA version: {torch.version.cuda}')
    print(f'GPU device: {torch.cuda.get_device_name(0)}')
    print(f'GPU memory: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB')
"@

& .\venv-gpu\Scripts\python.exe -c $testScript

Write-Host "`n==> Setup Complete!" -ForegroundColor Green
Write-Host "`nTo activate the GPU environment:" -ForegroundColor Yellow
Write-Host "    .\venv-gpu\Scripts\Activate.ps1" -ForegroundColor Cyan
Write-Host "`nTo run the app with GPU:" -ForegroundColor Yellow
Write-Host "    `$env:WARM_MODEL='1'; `$env:SAM_FP16='1'; `$env:CUDA_VISIBLE_DEVICES='0'" -ForegroundColor Cyan
Write-Host "    .\venv-gpu\Scripts\python.exe py/app.py" -ForegroundColor Cyan
Write-Host "`nOr use the provided run-local-gpu.ps1 script" -ForegroundColor Gray
