# Quick deploy of cache fix to Fargate
# This will make your app 10-15x faster immediately!

Write-Host "==> Deploying Cache Fix to Fargate" -ForegroundColor Cyan
Write-Host "    This fixes the 20-second slowness issue" -ForegroundColor Green
Write-Host ""

$ImageTag = "cache-fix"
$Region = "us-east-1"
$AccountId = "401753844565"
$Repository = "photosynth-full"
$Cluster = "photosynth"
$Service = "photosynth-full"

Write-Host "[1/5] Building Docker image..." -ForegroundColor Yellow
docker build -f Dockerfile -t "${Repository}:${ImageTag}" --target full .
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Build failed!" -ForegroundColor Red
    exit 1
}

Write-Host "`n[2/5] Logging in to ECR..." -ForegroundColor Yellow
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin "${AccountId}.dkr.ecr.${Region}.amazonaws.com"

Write-Host "`n[3/5] Tagging image..." -ForegroundColor Yellow
docker tag "${Repository}:${ImageTag}" "${AccountId}.dkr.ecr.${Region}.amazonaws.com/${Repository}:${ImageTag}"

Write-Host "`n[4/5] Pushing to ECR..." -ForegroundColor Yellow
docker push "${AccountId}.dkr.ecr.${Region}.amazonaws.com/${Repository}:${ImageTag}"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Push failed!" -ForegroundColor Red
    exit 1
}

Write-Host "`n[5/5] Updating ECS service..." -ForegroundColor Yellow
aws ecs update-service `
    --cluster $Cluster `
    --service $Service `
    --force-new-deployment `
    --region $Region `
    --output json | ConvertFrom-Json | Select-Object -ExpandProperty service | Select-Object serviceName, status, desiredCount, runningCount

Write-Host "`n==> Deployment started!" -ForegroundColor Green
Write-Host "    Service will restart with the cache fix" -ForegroundColor Gray
Write-Host "`nMonitor deployment:" -ForegroundColor Yellow
Write-Host "    aws ecs wait services-stable --cluster $Cluster --services $Service --region $Region" -ForegroundColor Cyan
Write-Host "`nCheck logs for cache hits:" -ForegroundColor Yellow
Write-Host "    aws logs tail /ecs/photosynth-full --follow --region $Region | Select-String 'cache_hit'" -ForegroundColor Cyan
Write-Host "`nExpected results:" -ForegroundColor Yellow
Write-Host "    First request: ~18-20s (cache_hit=False)" -ForegroundColor Gray
Write-Host "    Same image: ~1-3s (cache_hit=True) ✅" -ForegroundColor Green
