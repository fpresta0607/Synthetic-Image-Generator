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
  [string]$TaskDefFile = "api-td.json",  # optional: if absent we clone existing registered task def (family inferred from Service)
  [string]$TaskFamily = "sam-api",       # family name (used when cloning existing definition)
  [string]$AlbDns,  # optional, if provided will curl /health at the end
  [switch]$EnableProxyDebug,
  [switch]$NoCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "[deploy] Starting API deployment pipeline..." -ForegroundColor Cyan

# Acquire / synthesize task definition JSON (either from file or by cloning existing family)
$usingTempClone = $false
if (Test-Path $TaskDefFile) {
  Write-Host "[deploy] Using provided task definition file '$TaskDefFile'" -ForegroundColor DarkCyan
} else {
  Write-Host "[deploy] Local task def file not found. Attempting to clone existing family '$TaskFamily' from ECS" -ForegroundColor DarkYellow
  try {
    $raw = aws ecs describe-task-definition --task-definition $TaskFamily --region $Region | ConvertFrom-Json
  } catch {
    throw "Could not describe existing task definition family '$TaskFamily'. Provide -TaskDefFile or register one manually first. Error: $_"
  }
  $td = $raw.taskDefinition | ConvertTo-Json -Depth 50 | ConvertFrom-Json  # dup object
  # Remove read-only / server-populated properties
  $null = $td.PSObject.Properties.Remove('registeredAt')
  $null = $td.PSObject.Properties.Remove('deregisteredAt')
  $null = $td.PSObject.Properties.Remove('taskDefinitionArn')
  $null = $td.PSObject.Properties.Remove('revision')
  $null = $td.PSObject.Properties.Remove('status')
  $null = $td.PSObject.Properties.Remove('requiresAttributes')
  $null = $td.PSObject.Properties.Remove('compatibilities')
  $null = $td.PSObject.Properties.Remove('registeredBy')
  # Write to a temp file to re-use existing pipeline logic
  $TaskDefFile = "_cloned-${TaskFamily}-base.json"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($TaskDefFile, ($td | ConvertTo-Json -Depth 50), $utf8NoBom)
  $usingTempClone = $true
  Write-Host "[deploy] Cloned current task def to $TaskDefFile" -ForegroundColor DarkCyan
}

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

<#
 Prepare new task definition revision by loading JSON (original or cloned), updating image & optional env.
#>
Write-Host "[deploy] Preparing new task definition revision" -ForegroundColor DarkCyan
$jsonObj = Get-Content $TaskDefFile -Raw | ConvertFrom-Json
if (-not $jsonObj.containerDefinitions -or $jsonObj.containerDefinitions.Count -lt 1) { throw 'Container definitions missing in task definition JSON' }
$jsonObj.containerDefinitions[0].image = "${RepoUri}:$ImmutableTag"
if ($EnableProxyDebug) {
  $envList = $jsonObj.containerDefinitions[0].environment
  if (-not $envList) { $envList = @() }
  if (-not ($envList | Where-Object { $_.name -eq 'PROXY_DEBUG' })) {
    $envList += [pscustomobject]@{ name = 'PROXY_DEBUG'; value = '1' }
  } else {
    ($envList | Where-Object { $_.name -eq 'PROXY_DEBUG' }).value = '1'
  }
  $jsonObj.containerDefinitions[0].environment = $envList
}

$outPath = "api-td-$ImmutableTag.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($outPath, ($jsonObj | ConvertTo-Json -Depth 50), $utf8NoBom)

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

if ($usingTempClone -and (Test-Path $TaskDefFile)) {
  Remove-Item $TaskDefFile -Force -ErrorAction SilentlyContinue | Out-Null
  Write-Host "[deploy] Cleaned up temporary cloned task definition file" -ForegroundColor DarkGray
}

Write-Host "[deploy] Done. New revision: sam-api:$newRevision (image tag $ImmutableTag)" -ForegroundColor Green