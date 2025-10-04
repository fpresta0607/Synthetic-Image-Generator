# Local build & run script (separated from deployment)
# Usage:
#   ./run.ps1 -Tag dev
#   ./run.ps1 -Tag dev -SkipBuild
param(
  [string]$Tag = 'local',
  [switch]$SkipBuild,
  [int]$Port = 3000,
  [int]$BackendPort = 5001,
  [string]$EnvFile = '.env',
  [switch]$NoRun
)

$ErrorActionPreference = 'Stop'

if (-not $SkipBuild) {
  Write-Host "[Build] Building full image photosynth-full:$Tag" -ForegroundColor Cyan
  docker build --target full -t photosynth-full:$Tag .
  if ($LASTEXITCODE -ne 0) { throw "Docker build failed with exit code $LASTEXITCODE" }
} else {
  Write-Host "[Build] Skipping build (using existing photosynth-full:$Tag)" -ForegroundColor Yellow
}

Write-Host '[Env] Loading environment variables' -ForegroundColor Cyan
$extraEnvArgs = @()
if (Test-Path $EnvFile) {
  Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim(); if (-not $line) { return }; if ($line.StartsWith('#')) { return }; if (-not $line.Contains('=')) { return }
    $kv = $line.Split('=',2); $k=$kv[0].Trim(); $v=$kv[1].Trim()
    if ($v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1,$v.Length-2) }
    if ($v.StartsWith("'") -and $v.EndsWith("'")) { $v = $v.Substring(1,$v.Length-2) }
    if ($k) { $extraEnvArgs += @('--env',"$k=$v") }
  }
  Write-Host "[Env] Loaded $($extraEnvArgs.Count/2) vars from $EnvFile" -ForegroundColor Green
} else {
  Write-Host "[Env] File $EnvFile not found; continuing without it" -ForegroundColor Yellow
}

if ($NoRun) { Write-Host '[Run] NoRun specified; skipping container start' -ForegroundColor Yellow; exit 0 }

if (-not $Port -or $Port -le 0) { $Port = 3000 }
if (-not $BackendPort -or $BackendPort -le 0) { $BackendPort = 5001 }
Write-Host "[Run] Using host ports node=$Port backend=$BackendPort" -ForegroundColor Cyan

$imageInfo = docker images --no-trunc --format '{{.Repository}}|{{.Tag}}|{{.ID}}' | Where-Object { $_ -like "photosynth-full|$Tag|*" } | Select-Object -First 1
if (-not $imageInfo) { throw "Image photosynth-full:$Tag not found locally (build may have failed)" }
$parts = $imageInfo -split '\|'; $imageId = $parts[2]
Write-Host "[Image] $imageId" -ForegroundColor DarkCyan

$existing = docker ps -a --filter 'name=photosynth-full' --format '{{.ID}}'
if ($existing) { Write-Host '[Clean] Removing existing container' -ForegroundColor Yellow; docker rm -f photosynth-full | Out-Null }

$hostMapNode = "${Port}:3000"; $hostMapBackend = "${BackendPort}:5001"
$runArgs = @(
  'run','--name','photosynth-full',
  '-p',$hostMapNode,
  '-p',$hostMapBackend,
  '--env','PORT=3000'
) + $extraEnvArgs + @("photosynth-full:$Tag")
Write-Host "[Run] docker $($runArgs -join ' ')" -ForegroundColor DarkGray

docker @runArgs
