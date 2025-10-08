# Quick Local GPU Setup - Step by Step Guide

Write-Host @"
=============================================================================
          PhotoSynth Local GPU Setup Guide
=============================================================================

Your System:
  GPU: NVIDIA RTX 4000 Ada (12GB VRAM) ✓
  CUDA: 12.8 ✓
  Python: 3.13 (needs 3.11 for PyTorch)

"@ -ForegroundColor Cyan

Write-Host "STEP 1: Install Python 3.11" -ForegroundColor Yellow
Write-Host "---------------------------------------------------------------"
Write-Host "PyTorch doesn't support Python 3.13 yet. You need 3.11."
Write-Host ""
Write-Host "Option A: Download installer (recommended)" -ForegroundColor Green
Write-Host "  1. Open: https://www.python.org/ftp/python/3.11.8/python-3.11.8-amd64.exe"
Write-Host "  2. Run installer"
Write-Host "  3. Check 'Add Python to PATH'"
Write-Host "  4. Click 'Install Now'"
Write-Host ""
Write-Host "Option B: Use winget" -ForegroundColor Green
Write-Host "  winget install Python.Python.3.11"
Write-Host ""
Write-Host "Option C: Use Chocolatey" -ForegroundColor Green
Write-Host "  choco install python311"
Write-Host ""

$response = Read-Host "Do you want to download Python 3.11 installer now? (y/n)"

if ($response -eq 'y') {
    Write-Host "`nOpening download page..." -ForegroundColor Green
    Start-Process "https://www.python.org/ftp/python/3.11.8/python-3.11.8-amd64.exe"
    Write-Host "`nAfter installing Python 3.11, run this script again:" -ForegroundColor Yellow
    Write-Host "  .\scripts\Setup-Local-GPU.ps1" -ForegroundColor Cyan
} else {
    Write-Host "`nOK. Install Python 3.11 manually, then run:" -ForegroundColor Yellow
    Write-Host "  .\scripts\Setup-Local-GPU.ps1" -ForegroundColor Cyan
}

Write-Host @"

=============================================================================
QUICK START (after Python 3.11 is installed):
=============================================================================
1. Setup:     .\scripts\Setup-Local-GPU.ps1
2. Run app:   .\scripts\Run-Local-GPU.ps1
3. Open:      http://localhost:3000

Expected performance: 50-150ms per image (vs 800-1200ms on CPU)
=============================================================================
"@ -ForegroundColor Gray
