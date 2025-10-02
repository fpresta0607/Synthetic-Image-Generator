<#
  Rebuild & deploy a fresh ECS API task definition (sam-api) with an immutable tag.

  Usage (run from repo root PowerShell):
    .\scripts\deploy_api.ps1 -Region us-east-1 -Cluster sam-cluster -Service sam-api-svc -Repo sam-api [-EnableProxyDebug]

  Requirements:
    - AWS CLI configured with credentials & correct region access
    - Docker (buildx) available
    - api-td.json present in repo root

  Features:
    - Generates tag: <commit>-<yyyyMMddHHmmss>
    - Builds image (target=full) for linux/amd64
    - Pushes :latest and immutable tag
    - Optionally injects PROXY_DEBUG=1 env var
    - Registers new task definition revision (no BOM JSON)
    - Forces new ECS service deployment and waits for RUNNING
    - Outputs health check result (HTTP /health via ALB if AlbDns provided)

  Optional parameters:
    -AlbDns sam-alb-xxxx.us-east-1.elb.amazonaws.com  (to auto test health)

#>
param(
  [string]$Region = "us-east-1",
  [string]$Cluster = "sam-cluster",
  [string]$Service = "sam-api-svc",
  [string]$Repo = "sam-api",
  [string]$TaskDefFile = "api-td.json",
  [string]$AlbDns,  # optional, if provided will curl /health at the end
  [switch]$EnableProxyDebug,
  [switch]$NoCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "[deploy] Starting API deployment pipeline..." -ForegroundColor Cyan

if (!(Test-Path $TaskDefFile)) { throw "Task definition file '$TaskDefFile' not found" }

# Acquire account id
Write-Host "[deploy] Fetching AWS account id" -ForegroundColor DarkCyan
$AccountId = (aws sts get-caller-identity | ConvertFrom-Json).Account

$RepoUri = "$AccountId.dkr.ecr.$Region.amazonaws.com/$Repo"

# Compute tags
$Commit = (git rev-parse --short HEAD).Trim()
$Stamp  = (Get-Date -Format 'yyyyMMddHHmmss')
$ImmutableTag = "$Commit-$Stamp"

Write-Host "[deploy] Commit=$Commit ImmutableTag=$ImmutableTag" -ForegroundColor DarkCyan

# Ensure repo exists
Write-Host "[deploy] Ensuring ECR repository '$Repo' exists" -ForegroundColor DarkCyan
try {
  aws ecr describe-repositories --repository-names $Repo --region $Region 1>$null 2>$null
} catch {
  Write-Host "[deploy] Creating ECR repository $Repo" -ForegroundColor DarkYellow
  aws ecr create-repository --repository-name $Repo --image-scanning-configuration scanOnPush=true --region $Region | Out-Null
}

# ECR login
Write-Host "[deploy] Logging into ECR" -ForegroundColor DarkCyan
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin "$AccountId.dkr.ecr.$Region.amazonaws.com" | Out-Null

# Build & push
Write-Host "[deploy] Building image (target=full)" -ForegroundColor DarkCyan
$buildArgs = @('--platform','linux/amd64','--target','full','-t',"${RepoUri}:latest",'-t',"${RepoUri}:$ImmutableTag",'--push','.')
if ($NoCache) { $buildArgs = @('--no-cache') + $buildArgs }
docker buildx build @buildArgs

# Prepare new task definition JSON
Write-Host "[deploy] Preparing new task definition revision" -ForegroundColor DarkCyan
$jsonObj = Get-Content $TaskDefFile -Raw | ConvertFrom-Json
$jsonObj.containerDefinitions[0].image = "${RepoUri}:$ImmutableTag"
if ($EnableProxyDebug) {
  $envList = $jsonObj.containerDefinitions[0].environment
  if (-not ($envList | Where-Object { $_.name -eq 'PROXY_DEBUG' })) {
    $envList += [pscustomobject]@{ name = 'PROXY_DEBUG'; value = '1' }
  } else {
    ($envList | Where-Object { $_.name -eq 'PROXY_DEBUG' }).value = '1'
  }
  $jsonObj.containerDefinitions[0].environment = $envList
}

$outPath = "api-td-$ImmutableTag.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($outPath, ($jsonObj | ConvertTo-Json -Depth 15), $utf8NoBom)

Write-Host "[deploy] Registering task definition from $outPath" -ForegroundColor DarkCyan
$register = aws ecs register-task-definition --cli-input-json file://$outPath --region $Region | ConvertFrom-Json
$newRevision = $register.taskDefinition.revision
Write-Host "[deploy] Registered sam-api revision $newRevision" -ForegroundColor Green

# Update service
Write-Host "[deploy] Updating service '$Service' on cluster '$Cluster'" -ForegroundColor DarkCyan
aws ecs update-service --cluster $Cluster --service $Service --task-definition sam-api --force-new-deployment --desired-count 1 --region $Region | Out-Null

# Wait for RUNNING
Write-Host "[deploy] Waiting for task to reach RUNNING" -ForegroundColor DarkCyan
for ($i=0; $i -lt 60; $i++) {
  Start-Sleep -Seconds 5
  $taskArns = (aws ecs list-tasks --cluster $Cluster --service-name $Service --region $Region | ConvertFrom-Json).taskArns
  if (-not $taskArns) { continue }
  $desc = aws ecs describe-tasks --cluster $Cluster --tasks $taskArns[0] --region $Region | ConvertFrom-Json
  $last = $desc.tasks[0].lastStatus
  Write-Host "  status=$last" -ForegroundColor Gray
  if ($last -eq 'RUNNING') { break }
}

if ($AlbDns) {
  Write-Host "[deploy] Probing ALB /health via http://$AlbDns/health" -ForegroundColor DarkCyan
  try {
    $health = Invoke-RestMethod -Uri "http://$AlbDns/health" -TimeoutSec 10
    Write-Host "[deploy] Health: $(($health | ConvertTo-Json -Depth 5))" -ForegroundColor Green
  } catch { Write-Warning "Health probe failed: $_" }
}

Write-Host "[deploy] Done. New revision: sam-api:$newRevision (image tag $ImmutableTag)" -ForegroundColor Green