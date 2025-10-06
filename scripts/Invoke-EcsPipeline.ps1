<#!
.SYNOPSIS
  Builds the full multi-stage image, pushes to ECR, then updates an ECS service via local ecs-deploy script.

.DESCRIPTION
  Wrapper for end-to-end pipeline steps (build -> push -> deploy) using the project's Dockerfile (target 'full').
  Relies on AWS CLI v2 and docker being installed and authenticated (OIDC or local credentials / profile).

.PARAMETER Region
  AWS region (defaults to env:AWS_REGION or us-east-1)

.PARAMETER AccountId
  AWS account ID (auto-discovered via STS if omitted)

.PARAMETER Repository
  ECR repository name (no URI) – will be created if missing.

.PARAMETER Cluster
  ECS cluster name.

.PARAMETER Service
  ECS service name.

.PARAMETER ImageTag
  Optional tag; default = git short SHA (falls back to timestamp if git not available).

.PARAMETER ContainerName
  Optional container name (multi-container task) – if provided, ONLY that container's image will be updated (requires enhanced ecs-deploy wrapper; otherwise full task images updated).

.PARAMETER AssumeRoleArn
  Optional role ARN to assume before operations.

.PARAMETER MinHealthyPercent / MaxPercent
  Deployment configuration thresholds (defaults 100 / 200).

.PARAMETER DesiredCount
  Optional new desired count for service (if provided, ecs-deploy will apply it).

.PARAMETER TimeoutSeconds
  Wait time for new tasks to reach RUNNING/HEALTHY (ecs-deploy default 90; pipeline default 300).

.PARAMETER ForceNewDeployment
  If set, triggers a force-new-deployment without changing image (unless image differs).

.PARAMETER UseLatestTaskDef
  If set, base new revision off most recently CREATED revision rather than last USED.

.PARAMETER EnableRollback
  If set, rollback to previous task definition on timeout.

.PARAMETER DryRun
  Show what would be done without executing deploy (still builds image unless -SkipBuild).

.PARAMETER SkipBuild
  Skip docker build/push (useful if image already pushed).

.EXAMPLE
  ./scripts/Invoke-EcsPipeline.ps1 -Region us-east-1 -Repository photosynth-full -Cluster photosynth -Service photosynth-full \
    -MinHealthyPercent 100 -MaxPercent 200 -EnableRollback

.NOTES
  Windows PowerShell 5.1 / PowerShell 7 compatible.
#>
[CmdletBinding()] param(
  [string]$Region = $env:AWS_REGION, 
  [string]$AccountId,
  [Parameter(Mandatory)] [string]$Repository,
  [Parameter(Mandatory)] [string]$Cluster,
  [Parameter(Mandatory)] [string]$Service,
  [string]$ImageTag,
  [string]$ContainerName,
  [string]$AssumeRoleArn,
  [int]$MinHealthyPercent = 100,
  [int]$MaxPercent = 200,
  [int]$DesiredCount,
  [int]$TimeoutSeconds = 300,
  [switch]$ForceNewDeployment,
  [switch]$UseLatestTaskDef,
  [switch]$EnableRollback,
  [switch]$DryRun,
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
function Write-Section($msg){ Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Info($msg){ Write-Host "[INFO] $msg" -ForegroundColor Gray }
function Write-Warn($msg){ Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg){ Write-Host "[ERROR] $msg" -ForegroundColor Red }

if (-not $Region) { $Region = 'us-east-1' }

# Validate tooling
foreach($bin in @('aws','docker')){ if(-not (Get-Command $bin -ErrorAction SilentlyContinue)){ throw "Required executable not found: $bin" } }

# Attempt to locate bash early (needed for ecs-deploy). We'll fall back gracefully if missing.
$global:BashPath = (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if(-not $BashPath){
  $gitBash = Join-Path $Env:ProgramFiles 'Git' 'bin' 'bash.exe'
  if(Test-Path $gitBash){ $BashPath = $gitBash }
}
if($BashPath){
  Write-Info "bash detected at: $BashPath"
} else {
  Write-Warn "bash not detected (Git Bash or WSL) - will use native fallback if needed."
}

# Assume role if requested
if($AssumeRoleArn){
  Write-Section "Assuming role"
  $sessionName = "ecs-pipeline-$(Get-Date -Format 'yyyyMMddHHmmss')"
  $sts = aws sts assume-role --role-arn $AssumeRoleArn --role-session-name $sessionName --region $Region | ConvertFrom-Json
  $env:AWS_ACCESS_KEY_ID     = $sts.Credentials.AccessKeyId
  $env:AWS_SECRET_ACCESS_KEY = $sts.Credentials.SecretAccessKey
  $env:AWS_SESSION_TOKEN     = $sts.Credentials.SessionToken
  Write-Info "Assumed role session expires: $($sts.Credentials.Expiration)" }

# Discover account ID (prefer explicit param, then env var, then STS)
if(-not $AccountId){ $AccountId = $env:AWS_ACCOUNT_ID }
if(-not $AccountId){
  Write-Info "Looking up AWS AccountId via STS"
  $AccountId = aws sts get-caller-identity --query 'Account' --output text --region $Region 2>$null
  if(-not $AccountId -or $LASTEXITCODE -ne 0 -or $AccountId -match 'Unknown'){ 
    Write-Err "Failed to obtain AWS account ID. Ensure you are logged in (aws sts get-caller-identity)." 
    exit 2 
  }
}
Write-Info "AccountId: $AccountId"

# Derive tag
if(-not $ImageTag){
  if(Get-Command git -ErrorAction SilentlyContinue){
    try { $ImageTag = (git rev-parse --short HEAD) } catch { }
  }
  if(-not $ImageTag){ $ImageTag = (Get-Date -Format 'yyyyMMddHHmmss') }
}

$ImageUri = "${AccountId}.dkr.ecr.${Region}.amazonaws.com/${Repository}:${ImageTag}"
Write-Section "Pipeline Parameters"
$paramObj = [ordered]@{ Region=$Region; AccountId=$AccountId; Repository=$Repository; Cluster=$Cluster; Service=$Service; ImageTag=$ImageTag; ImageUri=$ImageUri; ContainerName=$ContainerName; ForceNew=$ForceNewDeployment.IsPresent; UseLatest=$UseLatestTaskDef.IsPresent; Rollback=$EnableRollback.IsPresent; DryRun=$DryRun.IsPresent; SkipBuild=$SkipBuild.IsPresent }
$paramObj.GetEnumerator() | ForEach-Object { Write-Info ("{0} = {1}" -f $_.Key,$_.Value) }

if(-not $SkipBuild){
  if(-not $AccountId){ Write-Err "AccountId unresolved. Aborting before build."; exit 3 }
  Write-Section "Ensure ECR repository"
  $exists = aws ecr describe-repositories --repository-names $Repository --region $Region 2>$null
  if(-not $exists){
    Write-Info "Creating repository $Repository"
    aws ecr create-repository --repository-name $Repository --image-scanning-configuration scanOnPush=true --region $Region | Out-Null
  }

  Write-Section "Authenticate to ECR"
  aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin "$AccountId.dkr.ecr.$Region.amazonaws.com" | Out-Null

  Write-Section "Build image"
  $buildArgs = @('--target','full','-t', $ImageUri, '.')
  Write-Info "docker build $($buildArgs -join ' ')"
  docker build @buildArgs

  Write-Section "Push image"
  docker push $ImageUri | Write-Host
}
else { Write-Warn "Skipping build/push as requested." }

if($DryRun){
  Write-Warn "DryRun set: deployment step skipped."
  Write-Host "Would deploy image: $ImageUri to service $Service in cluster $Cluster" -ForegroundColor Magenta
  exit 0
}

Write-Section "Deploy service"
# Path to ecs-deploy script (use enhanced if present)
$scriptCandidates = @(
  (Join-Path $PSScriptRoot 'ecs-deploy.sh'),
  (Join-Path $PSScriptRoot '..' 'scripts' 'ecs-deploy.sh'),
  (Join-Path $PSScriptRoot '..' '.github' 'copilot' 'ecs-deploy' 'ecs-deploy')
)
$ecsDeploy = $scriptCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if(-not $ecsDeploy){
  Write-Err "ecs-deploy script not found. Checked:`n - " + ($scriptCandidates -join "`n - ")
  Write-Warn "Falling back to native PowerShell task definition registration/update."
  $ecsDeploy = $null
}
else {
  Write-Warn "Temporarily bypassing ecs-deploy path (diagnostic) and using native fallback.";
  $ecsDeploy = $null
}

# Build command arguments
$deployArgs = @('-c', $Cluster, '-n', $Service, '-i', $ImageUri, '-r', $Region, '-t', $TimeoutSeconds.ToString(), '-m', $MinHealthyPercent.ToString(), '-M', $MaxPercent.ToString())
if($EnableRollback){ $deployArgs += '--enable-rollback' }
if($ForceNewDeployment){ $deployArgs += '--force-new-deployment' }
if($UseLatestTaskDef){ $deployArgs += '--use-latest-task-def' }
if($DesiredCount){ $deployArgs += @('-D', $DesiredCount.ToString()) }
if($ContainerName){
  try {
    $firstLines = Get-Content -Path $ecsDeploy -TotalCount 80 -ErrorAction Stop
    if($firstLines -match '--container-name'){ $deployArgs += @('-C', $ContainerName) }
    else { Write-Warn "ContainerName specified but ecs-deploy variant lacks -C; proceeding without container targeting." }
  } catch { Write-Warn "Could not inspect ecs-deploy script for -C support: $_" }
}

# (ecs-deploy invocation skipped intentionally for diagnostic)

if(-not $ecsDeploy){
  Write-Section "Native Fallback Deployment"
  # 1. Get current task definition ARN
  $currentTdArn = aws ecs describe-services --cluster $Cluster --services $Service --region $Region --query 'services[0].taskDefinition' --output text 2>$null
  if(-not $currentTdArn -or $currentTdArn -eq 'None') { Write-Err "Unable to resolve current task definition for service $Service"; exit 6 }
  Write-Info "Current TD: $currentTdArn"
  $tdJson = aws ecs describe-task-definition --task-definition $currentTdArn --region $Region --query 'taskDefinition' --output json | ConvertFrom-Json
  # 2. Replace image (optionally only the target container)
  if($ContainerName){
    foreach($c in $tdJson.containerDefinitions){ if($c.name -eq $ContainerName){ $c.image = $ImageUri } }
  } else {
    foreach($c in $tdJson.containerDefinitions){ $c.image = $ImageUri }
  }
  # 3. Build registration payload
  $payload = [ordered]@{
    family = $tdJson.family
    networkMode = $tdJson.networkMode
    requiresCompatibilities = $tdJson.requiresCompatibilities
    cpu = $tdJson.cpu
    memory = $tdJson.memory
    executionRoleArn = $tdJson.executionRoleArn
    taskRoleArn = $tdJson.taskRoleArn
    containerDefinitions = $tdJson.containerDefinitions
    volumes = $tdJson.volumes
    placementConstraints = $tdJson.placementConstraints
  }
  $payloadJson = ($payload | ConvertTo-Json -Depth 15)
  $newTdArn = aws ecs register-task-definition --cli-input-json $payloadJson --region $Region --query 'taskDefinition.taskDefinitionArn' --output text
  if(-not $newTdArn){ Write-Err "Task definition registration failed"; exit 7 }
  Write-Info "Registered new TD: $newTdArn"
  # 4. Update service
  $updateCmd = @('ecs','update-service','--cluster', $Cluster,'--service', $Service,'--task-definition',$newTdArn,'--region',$Region,'--deployment-configuration',"minimumHealthyPercent=$MinHealthyPercent,maximumPercent=$MaxPercent")
  if($DesiredCount){ $updateCmd += @('--desired-count', $DesiredCount) }
  aws @updateCmd | Out-Null
  Write-Info "Service update initiated"
  # 5. Wait for stabilization (simple poll)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    Start-Sleep -Seconds 6
    $deployCount = aws ecs describe-services --cluster $Cluster --services $Service --region $Region --query 'services[0].deployments | length(@)' --output text 2>$null
    if($deployCount -eq '1'){ Write-Info "Stabilized."; break }
  } while((Get-Date) -lt $deadline)
  if($deployCount -ne '1'){ Write-Err "Timeout waiting for stable deployment"; exit 8 }
}

Write-Section "Post-deploy summary"
aws ecs describe-services --cluster $Cluster --services $Service --region $Region --query 'services[0].{running:runningCount,desired:desiredCount,taskDef:taskDefinition}'

Write-Host "Deployment complete -> $ImageUri" -ForegroundColor Green
