# Build and Deploy GPU-Optimized Image to ECS
param(
    [string]$ImageTag = "gpu-optimized",
    [string]$Region = "us-east-1",
    [string]$AccountId = "401753844565",
    [string]$Cluster = "photosynth",
    [string]$Service = "photosynth-full",
    [switch]$SkipBuild,
    [switch]$SkipPush,
    [switch]$WaitForSteady
)

$ErrorActionPreference = "Stop"
$RepositoryName = "photosynth-full"
$ImageUri = "$AccountId.dkr.ecr.$Region.amazonaws.com/${RepositoryName}:$ImageTag"

Write-Host "==> GPU Deployment Script" -ForegroundColor Cyan
Write-Host "    Image: $ImageUri" -ForegroundColor Gray

if (-not $SkipBuild) {
    Write-Host "`n[1/5] Building GPU image..." -ForegroundColor Yellow
    docker build -f Dockerfile.gpu -t "${RepositoryName}:$ImageTag" --target full .
    if ($LASTEXITCODE -ne 0) { throw "Build failed" }
    Write-Host "    Build complete" -ForegroundColor Green
} else {
    Write-Host "`n[1/5] Skipping build" -ForegroundColor Gray
}

Write-Host "`n[2/5] Logging into ECR..." -ForegroundColor Yellow
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin "$AccountId.dkr.ecr.$Region.amazonaws.com"
if ($LASTEXITCODE -ne 0) { throw "ECR login failed" }

Write-Host "`n[3/5] Tagging image..." -ForegroundColor Yellow
docker tag "${RepositoryName}:$ImageTag" $ImageUri

if (-not $SkipPush) {
    Write-Host "`n[4/5] Pushing to ECR (5-10 min)..." -ForegroundColor Yellow
    docker push $ImageUri
    if ($LASTEXITCODE -ne 0) { throw "Push failed" }
}

Write-Host "`n[5/5] Registering task definition..." -ForegroundColor Yellow
$tdContent = Get-Content td-gpu.json -Raw | ConvertFrom-Json
$tdContent.containerDefinitions[0].image = $ImageUri
$tdPath = "td-gpu-deploy.json"
$tdContent | ConvertTo-Json -Depth 10 | Set-Content $tdPath

$tdResult = aws ecs register-task-definition --cli-input-json "file://$tdPath" --region $Region | ConvertFrom-Json
$revision = $tdResult.taskDefinition.revision

Write-Host "`n[6/6] Updating ECS service..." -ForegroundColor Yellow
aws ecs update-service --cluster $Cluster --service $Service --task-definition "photosynth-full:$revision" --region $Region | Out-Null

if ($WaitForSteady) {
    Write-Host "`nWaiting for steady state..." -ForegroundColor Yellow
    aws ecs wait services-stable --cluster $Cluster --services $Service --region $Region
    Write-Host "    Deployment complete!" -ForegroundColor Green
}

Write-Host "`n==> Deployment Summary" -ForegroundColor Cyan
Write-Host "    Task: photosynth-full:$revision" -ForegroundColor Gray
Write-Host "    GPU: 1x NVIDIA T4 / 4 vCPU / 8 GB" -ForegroundColor Gray
