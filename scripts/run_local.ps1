Param(
  [string]$RepositoryName = "sam-api",
  [string]$Region = $(if($Env:AWS_REGION){$Env:AWS_REGION}else{"us-east-1"}),
  [switch]$Push,
  [string]$ModelBucket,
  [string]$CheckpointKey = "sam_vit_b.pth",
  [switch]$Warm,
  [int]$HostPort = 3000,
  [switch]$AutoPort,  # if set, will find next free host port starting at HostPort
  [switch]$IncludeAwsCreds, # inject current AWS CLI credentials into container env (local dev only)
  [switch]$PreferLocalModel # if set, mount ./models as /app/py/models when checkpoint file present
  , [switch]$NoCache # if set, force --no-cache build
)

$ErrorActionPreference = 'Stop'

function Write-Info($m){ Write-Host "[run_local] $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Host "[run_local] $m" -ForegroundColor Yellow }
function Write-Err($m){ Write-Host "[run_local] $m" -ForegroundColor Red }

function Test-PortInUseDocker([int]$p){
  $inUse = docker ps --format '{{.Ports}}' 2>$null | Where-Object { $_ -match "0.0.0.0:$p->" }
  return [bool]$inUse
}

if($AutoPort){
  $original = $HostPort
  for($try=0; $try -lt 20; $try++){
    if(-not (Test-PortInUseDocker $HostPort)) { break }
    $HostPort++
  }
  if($original -ne $HostPort){ Write-Warn "Port $original in use, selected alternative $HostPort" }
}

if(-not (Get-Command aws -ErrorAction SilentlyContinue)){ throw 'aws CLI not found in PATH' }
if(-not (Get-Command docker -ErrorAction SilentlyContinue)){ throw 'docker not found in PATH' }

Write-Info "Using AWS region $Region"
$acct = aws sts get-caller-identity --query Account --output text 2>$null
if(-not $acct){ throw 'Could not resolve AWS account (check credentials)' }

# Resolve / create ECR repository
$repoUri = aws ecr describe-repositories --repository-names $RepositoryName --query "repositories[0].repositoryUri" --output text 2>$null
if(-not $repoUri -or $repoUri -eq 'None'){
  Write-Info "Creating ECR repository $RepositoryName"
  aws ecr create-repository --repository-name $RepositoryName --image-scanning-configuration scanOnPush=true | Out-Null
  $repoUri = aws ecr describe-repositories --repository-names $RepositoryName --query "repositories[0].repositoryUri" --output text
}
Write-Info "Repo URI: $repoUri"

# Compute tags
$commit = (git rev-parse --short HEAD 2>$null)
if(-not $commit){ $commit = (Get-Date -Format 'yyyyMMddHHmmss') }
$localTag = "${repoUri}:local"
$commitTag = "${repoUri}:$commit"
Write-Info "Tags => local: $localTag , commit: $commitTag"

# Build image
Write-Info 'Building image (target full)...'
$buildCmd = @('docker','build','--progress=plain','-t',$localTag,'-t',$commitTag,'--target','full','.')
if($NoCache){ $buildCmd = @('docker','build','--no-cache') + $buildCmd[2..($buildCmd.Length-1)] }
& $buildCmd

if($LASTEXITCODE -ne 0){ throw "docker build failed with exit code $LASTEXITCODE" }

if($Push){
  Write-Info 'Logging into ECR...'
  $registry = ($repoUri -split '/')[0]
  aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $registry | Out-Null
  Write-Info 'Pushing tags...'
  docker push $localTag
  docker push $commitTag
}

# Run container
$envArgs = @()
if($ModelBucket){ $envArgs += '-e'; $envArgs += "MODELS_BUCKET=$ModelBucket"; $envArgs += '-e'; $envArgs += "SAM_CHECKPOINT_KEY=$CheckpointKey" }
if($Warm){ $envArgs += '-e'; $envArgs += 'WARM_MODEL=1' } else { $envArgs += '-e'; $envArgs += 'WARM_MODEL=0' }

if($IncludeAwsCreds){
  Write-Info 'Including AWS credentials from current profile (DO NOT USE IN PROD CONTAINERS)'
  $ak = aws configure get aws_access_key_id 2>$null
  $sk = aws configure get aws_secret_access_key 2>$null
  $st = aws configure get aws_session_token 2>$null
  if($ak -and $sk){
    $envArgs += '-e'; $envArgs += "AWS_ACCESS_KEY_ID=$ak"
    $envArgs += '-e'; $envArgs += "AWS_SECRET_ACCESS_KEY=$sk"
    if($st){ $envArgs += '-e'; $envArgs += "AWS_SESSION_TOKEN=$st" }
    $envArgs += '-e'; $envArgs += "AWS_REGION=$Region"
  } else {
    Write-Warn 'Could not read AWS credentials; skipping credential injection.'
  }
}

# Optional local model mount
$volArgs = @()
if($PreferLocalModel){
  $modelsPath = $(Resolve-Path -ErrorAction SilentlyContinue ./models)
  if($modelsPath){
    $ckPath = Join-Path $modelsPath $CheckpointKey
    if(Test-Path $ckPath){
      Write-Info "Mounting local model directory: $($modelsPath.Path) (contains $CheckpointKey)"
      $volArgs += '-v'; $volArgs += "$($modelsPath.Path):/app/py/models:ro"
    } else {
      Write-Warn "-PreferLocalModel specified but checkpoint file not found at $ckPath. Skipping mount."
    }
  } else {
    Write-Warn "-PreferLocalModel specified but ./models directory not found. Skipping mount."
  }
}

Write-Info "Starting container (host:$HostPort -> container:3000) with model bucket: $ModelBucket"
if(-not $AutoPort){
  # Only stop existing if user explicitly targets this port
  $existing = docker ps --filter "publish=$HostPort" --format '{{.ID}}'
  if($existing){ Write-Warn "Stopping existing containers on port $HostPort"; $existing | ForEach-Object { docker stop $_ | Out-Null } }
} else {
  if(Test-PortInUseDocker $HostPort){ Write-Err "Selected port $HostPort still appears busy; aborting"; exit 2 }
}

& docker run --name sam-api-local --rm -p ${HostPort}:3000 @volArgs @envArgs $localTag
