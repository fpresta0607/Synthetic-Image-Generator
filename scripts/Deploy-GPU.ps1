# Build and Deploy GPU-Optimized Image to ECS
# This script builds the GPU-enabled Docker image and deploys to Fargate with GPU support

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

Write-Host "==> GPU-Optimized SAM Deployment Script" -ForegroundColor Cyan
Write-Host "    Image: $ImageUri" -ForegroundColor Gray

# Step 1: Build GPU-enabled image
if (-not $SkipBuild) {
    Write-Host ""
    Write-Host "[1/5] Building GPU-optimized Docker image..." -ForegroundColor Yellow
    docker build -f Dockerfile.gpu -t "${RepositoryName}:$ImageTag" --target full .
    if ($LASTEXITCODE -ne 0) { throw "Docker build failed" }
    Write-Host "    Build complete" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "[1/5] Skipping build" -ForegroundColor Gray
}

# Step 2: ECR login
Write-Host ""
Write-Host "[2/5] Logging into ECR..." -ForegroundColor Yellow
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin "$AccountId.dkr.ecr.$Region.amazonaws.com"
if ($LASTEXITCODE -ne 0) { throw "ECR login failed" }
Write-Host "    Logged in" -ForegroundColor Green

# Step 3: Tag image
Write-Host ""
Write-Host "[3/5] Tagging image..." -ForegroundColor Yellow
docker tag "${RepositoryName}:$ImageTag" $ImageUri
if ($LASTEXITCODE -ne 0) { throw "Docker tag failed" }
Write-Host "    Tagged: $ImageUri" -ForegroundColor Green

# Step 4: Push to ECR
if (-not $SkipPush) {
    Write-Host ""
    Write-Host "[4/5] Pushing image to ECR (this may take 5-10 minutes)..." -ForegroundColor Yellow
    docker push $ImageUri
    if ($LASTEXITCODE -ne 0) { throw "Docker push failed" }
    Write-Host "    Push complete" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "[4/5] Skipping push" -ForegroundColor Gray
}

# Step 5: Update task definition JSON with new image tag
Write-Host ""
Write-Host "[5/5] Registering GPU task definition..." -ForegroundColor Yellow
$tdContent = Get-Content td-gpu.json -Raw | ConvertFrom-Json
$tdContent.containerDefinitions[0].image = $ImageUri
$tdPath = "td-gpu-deploy.json"
$tdContent | ConvertTo-Json -Depth 10 | Set-Content $tdPath

$tdResult = aws ecs register-task-definition --cli-input-json "file://$tdPath" --region $Region | ConvertFrom-Json
$revision = $tdResult.taskDefinition.revision
$taskDefArn = $tdResult.taskDefinition.taskDefinitionArn
Write-Host "    Registered: $taskDefArn" -ForegroundColor Green

# Step 6: Update service
Write-Host ""
Write-Host "[6/6] Updating ECS service to revision $revision..." -ForegroundColor Yellow
aws ecs update-service --cluster $Cluster --service $Service --task-definition "photosynth-full:$revision" --region $Region | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Service update failed" }
Write-Host "    Service updated" -ForegroundColor Green

if ($WaitForSteady) {
    Write-Host ""
    Write-Host "Waiting for deployment to reach steady state (this may take 3-5 minutes)..." -ForegroundColor Yellow
    aws ecs wait services-stable --cluster $Cluster --services $Service --region $Region
    Write-Host "    Deployment complete!" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Deployment initiated. Monitor status with:" -ForegroundColor Cyan
    Write-Host "  aws ecs describe-services --cluster $Cluster --services $Service --region $Region" -ForegroundColor Gray
}

Write-Host ""
Write-Host "==> Deployment Summary" -ForegroundColor Cyan
Write-Host "    Image: $ImageUri" -ForegroundColor Gray
Write-Host "    Task Definition: photosynth-full:$revision" -ForegroundColor Gray
Write-Host "    GPU: 1x NVIDIA T4 (Fargate)" -ForegroundColor Gray
Write-Host "    CPU: 4 vCPU / Memory: 8 GB" -ForegroundColor Gray
Write-Host "    Optimizations: CUDA, FP16, Warm Model, 2x Workers" -ForegroundColor Gray
Write-Host ""
Write-Host "    Expected speedup: 10-30x faster inference vs CPU" -ForegroundColor Green
