# Deploy Image Deduplication Feature
# This script builds and deploys the enhanced version with smart caching

Write-Host "=" -ForegroundColor Cyan
Write-Host "==> Deploying Image Deduplication Feature" -ForegroundColor Cyan
Write-Host "    Adds smart caching to avoid redundant prewarm" -ForegroundColor Cyan
Write-Host "=" -ForegroundColor Cyan

$IMAGE_NAME = "photosynth-full"
$TAG = "dedup"
$ECR_REPO = "401753844565.dkr.ecr.us-east-1.amazonaws.com/$IMAGE_NAME"
$REGION = "us-east-1"
$CLUSTER = "photosynth"
$SERVICE = "photosynth-full"

# Step 1: Build Docker image
Write-Host "`n[1/5] Building Docker image..." -ForegroundColor Yellow
docker build -t "${IMAGE_NAME}:${TAG}" .
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Docker build failed" -ForegroundColor Red
    exit 1
}
Write-Host "✅ Image built: ${IMAGE_NAME}:${TAG}" -ForegroundColor Green

# Step 2: Login to ECR
Write-Host "`n[2/5] Logging in to ECR..." -ForegroundColor Yellow
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REPO
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ ECR login failed" -ForegroundColor Red
    exit 1
}
Write-Host "✅ Logged in to ECR" -ForegroundColor Green

# Step 3: Tag image
Write-Host "`n[3/5] Tagging image..." -ForegroundColor Yellow
docker tag "${IMAGE_NAME}:${TAG}" "${ECR_REPO}:${TAG}"
docker tag "${IMAGE_NAME}:${TAG}" "${ECR_REPO}:latest"
Write-Host "✅ Tagged for ECR" -ForegroundColor Green

# Step 4: Push to ECR
Write-Host "`n[4/5] Pushing to ECR..." -ForegroundColor Yellow
Write-Host "This may take 5-10 minutes..." -ForegroundColor Gray
docker push "${ECR_REPO}:${TAG}"
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Docker push failed" -ForegroundColor Red
    exit 1
}
docker push "${ECR_REPO}:latest"
Write-Host "✅ Pushed to ECR" -ForegroundColor Green

# Step 5: Update ECS service
Write-Host "`n[5/5] Updating ECS service..." -ForegroundColor Yellow
aws ecs update-service `
    --cluster $CLUSTER `
    --service $SERVICE `
    --force-new-deployment `
    --region $REGION `
    --no-cli-pager
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ ECS update failed" -ForegroundColor Red
    exit 1
}
Write-Host "✅ ECS service updated" -ForegroundColor Green

# Summary
Write-Host "`n" -ForegroundColor Cyan
Write-Host "=" -ForegroundColor Cyan
Write-Host "==> Deployment Complete!" -ForegroundColor Cyan
Write-Host "=" -ForegroundColor Cyan
Write-Host "`nNew features:" -ForegroundColor White
Write-Host "  ✅ Image deduplication (SHA256 hashing)" -ForegroundColor Green
Write-Host "  ✅ Smart prewarm (skips cached images)" -ForegroundColor Green
Write-Host "  ✅ Loading wheel with time estimation" -ForegroundColor Green
Write-Host "  ✅ Global cache keys (works across datasets)" -ForegroundColor Green
Write-Host "  ✅ Duplicate detection feedback" -ForegroundColor Green

Write-Host "`nMonitoring commands:" -ForegroundColor White
Write-Host "  # Watch deployment" -ForegroundColor Gray
Write-Host "  aws ecs describe-services --cluster $CLUSTER --services $SERVICE --region $REGION --query 'services[0].deployments'" -ForegroundColor Gray
Write-Host ""
Write-Host "  # Check logs for deduplication" -ForegroundColor Gray
Write-Host "  aws logs tail /ecs/photosynth-full --follow --region $REGION | Select-String 'DEDUP'" -ForegroundColor Gray
Write-Host ""
Write-Host "  # Verify cache performance" -ForegroundColor Gray
Write-Host "  aws logs tail /ecs/photosynth-full --follow --region $REGION | Select-String 'cache_hit'" -ForegroundColor Gray

Write-Host "`nTesting:" -ForegroundColor White
Write-Host "  1. Upload a dataset with 10-20 images" -ForegroundColor Gray
Write-Host "  2. Wait for prewarm to complete (~3-5 minutes)" -ForegroundColor Gray
Write-Host "  3. Upload THE SAME images again (new dataset)" -ForegroundColor Gray
Write-Host "  4. Should see: '10 image(s) already cached, prewarm will be faster'" -ForegroundColor Gray
Write-Host "  5. Prewarm should skip all 10 images (takes <5 seconds)" -ForegroundColor Gray
Write-Host "  6. Check logs: should see [DEDUP] messages" -ForegroundColor Gray

Write-Host "`n✨ Expected performance:" -ForegroundColor Yellow
Write-Host "  - First upload: Normal (18s per image)" -ForegroundColor Gray
Write-Host "  - Repeated uploads: 90-99% faster (skip cached)" -ForegroundColor Gray
Write-Host "  - Partial overlap: Proportional speedup" -ForegroundColor Gray
