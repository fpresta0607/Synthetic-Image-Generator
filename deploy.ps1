# Deployment script (ECR + ECS) separated from local run
# Usage examples:
#   ./deploy.ps1 -Tag dev -AccountId 123456789012 -Region us-east-1 -UpdateService -ForceNewDeployment -Wait -Subnets subnet-1,subnet-2 -SecurityGroups sg-123
#   ./deploy.ps1 -Tag dev -SkipPush -UpdateService
param(
  [string]$Tag = 'local',
  [string]$Repository = 'photosynth-full',
  [string]$Region = 'us-east-1',
  [string]$AccountId,
  [string]$TaskDefFile = 'taskdef.json',
  [string]$Family = 'photosynth-full',
  [string]$Cluster = 'photosynth',
  [string]$Service = 'photosynth-full',
  [switch]$SkipPush,
  [switch]$UpdateService,
  [switch]$ForceNewDeployment,
  [int]$DesiredCount = 1,
  [string[]]$Subnets,
  [string[]]$SecurityGroups,
  [switch]$AssignPublicIp,
  [switch]$Wait,
  [int]$WaitTimeoutSeconds = 600,
  # Task definition creation / overrides
  [switch]$AutoCreateTaskDef,
  [int]$Cpu = 1024,
  [int]$Memory = 2048,
  [string]$ExecutionRoleArn,
  [string]$TaskRoleArn,
  [int]$LogRetentionDays = 7,
  [switch]$NoHealthCheck,
  [switch]$Debug
)

$ErrorActionPreference = 'Stop'

# Ensure docker image exists locally
$imageInfo = docker images --no-trunc --format '{{.Repository}}|{{.Tag}}|{{.ID}}' | Where-Object { $_ -like "${Repository}|$Tag|*" } | Select-Object -First 1
if (-not $imageInfo) { throw "Local image ${Repository}:$Tag not found. Build/run with run.ps1 first or docker build manually." }
$parts = $imageInfo -split '\|'; $imageId = $parts[2]
Write-Host "[Image] Using local image ID $imageId" -ForegroundColor Cyan

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw 'AWS CLI not found in PATH.' }
if (-not $AccountId) {
  try { $AccountId = (aws sts get-caller-identity --query 'Account' --output text).Trim() } catch { throw 'Unable to resolve AWS AccountId; pass -AccountId' }
}
$ecrRepo = "${AccountId}.dkr.ecr.${Region}.amazonaws.com/${Repository}"
$remoteRef = "${ecrRepo}:${Tag}"
Write-Host "[ECR] Target reference: $remoteRef" -ForegroundColor Cyan

Write-Host '[ECR] Logging in...' -ForegroundColor Cyan
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin "${AccountId}.dkr.ecr.${Region}.amazonaws.com" | Out-Null
$exists = aws ecr describe-repositories --repository-names $Repository --region $Region 2>$null
if (-not $exists) { Write-Host "[ECR] Creating repository $Repository" -ForegroundColor Yellow; aws ecr create-repository --repository-name $Repository --region $Region | Out-Null }

if (-not $SkipPush) {
  Write-Host '[ECR] Tagging & pushing image' -ForegroundColor Cyan
  docker tag $imageId $remoteRef
  docker push $remoteRef | Out-Null
  Write-Host '[ECR] Push complete' -ForegroundColor Green
} else {
  Write-Host '[ECR] SkipPush specified; skipping image push' -ForegroundColor Yellow
}

if (-not (Test-Path $TaskDefFile)) {
  if ($AutoCreateTaskDef) {
    Write-Host "[TaskDef] $TaskDefFile missing; auto-creating baseline (family=$Family cpu=$Cpu memory=$Memory)" -ForegroundColor Yellow
    $taskDefObj = @{
      family = $Family
      networkMode = 'awsvpc'
      requiresCompatibilities = @('FARGATE')
      cpu = "$Cpu"
      memory = "$Memory"
      containerDefinitions = @(
        @{
          name = 'photosynth-full'
          image = 'PLACEHOLDER'
          essential = $true
          portMappings = @(
            @{ containerPort = 3000; protocol = 'tcp' },
            @{ containerPort = 5001; protocol = 'tcp' }
          )
          logConfiguration = @{
            logDriver = 'awslogs'
            options = @{
              'awslogs-group' = "/ecs/$Family"
              'awslogs-region' = $Region
              'awslogs-stream-prefix' = 'ecs'
            }
          }
          healthCheck = @{
            command = @('CMD-SHELL', 'curl -f http://localhost:3000/api/backend/health || exit 1')
            interval = 30
            timeout = 5
            retries = 3
            startPeriod = 10
          }
        }
      )
    }
    if ($ExecutionRoleArn) { $taskDefObj.executionRoleArn = $ExecutionRoleArn }
    if ($TaskRoleArn) { $taskDefObj.taskRoleArn = $TaskRoleArn }
    $taskDefObj | ConvertTo-Json -Depth 25 | Set-Content $TaskDefFile -Encoding UTF8
    Write-Host "[TaskDef] Created $TaskDefFile" -ForegroundColor Green
  } else {
    throw "Task definition file $TaskDefFile not found (pass -AutoCreateTaskDef to scaffold a default)"
  }
}

$taskJson = Get-Content $TaskDefFile -Raw | ConvertFrom-Json
$updated = $false
$taskJson.containerDefinitions | Where-Object { $_.name -eq 'photosynth-full' } | ForEach-Object { $_.image = $remoteRef; $updated = $true }
if (-not $updated) { throw "Container definition 'photosynth-full' not found in $TaskDefFile" }
$tmp = New-TemporaryFile
$taskJson | ConvertTo-Json -Depth 25 | Set-Content $tmp -Encoding UTF8
$tmpPath = $tmp.FullName
if ($Debug) { Write-Host "[Debug] Temp taskdef JSON: $tmpPath" -ForegroundColor DarkGray }
if ($Debug) { Write-Host ([IO.File]::ReadAllText($tmpPath) | Select-Object -First 1) }

# Ensure log group exists if using awslogs
try {
  $lg = "/ecs/$Family"
  $existsLog = aws logs describe-log-groups --log-group-name-prefix $lg --region $Region --no-paginate 2>$null | ConvertFrom-Json
  if (-not ($existsLog.logGroups | Where-Object { $_.logGroupName -eq $lg })) {
    Write-Host "[Logs] Creating log group $lg" -ForegroundColor Yellow
    aws logs create-log-group --log-group-name $lg --region $Region | Out-Null
    if ($LogRetentionDays -gt 0) {
      aws logs put-retention-policy --log-group-name $lg --retention-in-days $LogRetentionDays --region $Region | Out-Null
    }
  }
} catch { Write-Host "[Logs] Skipping log group setup: $($_.Exception.Message)" -ForegroundColor DarkGray }

Write-Host '[ECS] Registering new task definition revision' -ForegroundColor Cyan
# Build container definitions array explicitly (PowerShell flattens single-item arrays otherwise)
$containerArray = @()
foreach ($c in $taskJson.containerDefinitions) { $containerArray += $c }
# Deep clone to strip healthcheck if needed
if ($NoHealthCheck) {
  foreach ($c in $containerArray) {
    if ($c.healthCheck) { $c.PSObject.Properties.Remove('healthCheck') }
  }
}
$containerDefs = ($containerArray | ConvertTo-Json -Depth 25 -Compress)
if ($Debug) { Write-Host "[Debug] ContainerDefinitions JSON: $containerDefs" -ForegroundColor DarkGray }

function Invoke-TaskDefRegistration {
  param([bool]$StripHealthCheck)
  if (-not $StripHealthCheck) { return $containerDefs }
  try {
    $mutable = $containerDefs | ConvertFrom-Json
    foreach ($c in $mutable) { if ($c.healthCheck) { $c.PSObject.Properties.Remove('healthCheck') } }
    return ($mutable | ConvertTo-Json -Depth 25 -Compress)
  } catch { return $containerDefs }
}

$env:AWS_PAGER = ''  # disable pager to avoid swallowed output

# Build minimal full task definition JSON for file-based registration (more reliable on Windows)
$taskRoot = [ordered]@{
  family = $Family
  networkMode = 'awsvpc'
  requiresCompatibilities = @('FARGATE')
  cpu = "$Cpu"
  memory = "$Memory"
  containerDefinitions = ($containerDefs | ConvertFrom-Json)
}
if ($ExecutionRoleArn) { $taskRoot.executionRoleArn = $ExecutionRoleArn }
if ($TaskRoleArn) { $taskRoot.taskRoleArn = $TaskRoleArn }

$miniFile = New-TemporaryFile
($taskRoot | ConvertTo-Json -Depth 25) | Set-Content $miniFile -Encoding UTF8
$filePath = $miniFile.FullName
$fileUri = "file://$filePath"
if ($Debug) {
  Write-Host "[Debug] TaskDef file: $filePath" -ForegroundColor DarkGray
  Get-Content $miniFile | Select-Object -First 40 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
}

$regCmd = @('ecs','register-task-definition','--cli-input-json',$fileUri,'--region',$Region)
if ($Debug) { Write-Host "[Debug] aws $($regCmd -join ' ')" -ForegroundColor DarkGray }
$regOut = aws @regCmd 2>&1 | Tee-Object -Variable _rawRegOut
$exit = $LASTEXITCODE
if ($exit -ne 0) {
  Write-Host "[Error] Registration failed (exit $exit)" -ForegroundColor Red
  $_rawRegOut | ForEach-Object { Write-Host $_ -ForegroundColor Red }
  # If execution role pass-role issue, surface hint
  if ($_rawRegOut -join ' ' -match 'AccessDenied|PassRole') {
    Write-Host '[Hint] Ensure caller has iam:PassRole on the execution/task roles.' -ForegroundColor Yellow
  }
  # Try a last-resort stripped healthCheck (if present and not already stripped)
  $hasHC = ($containerArray | Where-Object { $_.healthCheck }).Count -gt 0
  if ($hasHC -and -not $NoHealthCheck) {
    Write-Host '[Retry] Stripping healthCheck and retrying...' -ForegroundColor Yellow
    foreach ($c in $containerArray) { if ($c.healthCheck) { $c.PSObject.Properties.Remove('healthCheck') } }
    $taskRoot.containerDefinitions = $containerArray
    ($taskRoot | ConvertTo-Json -Depth 25) | Set-Content $miniFile -Encoding UTF8
    $regOut2 = aws @regCmd 2>&1 | Tee-Object -Variable _rawRegOut2
    if ($LASTEXITCODE -ne 0) {
      Write-Host '[Error] Retry also failed' -ForegroundColor Red
      $_rawRegOut2 | ForEach-Object { Write-Host $_ -ForegroundColor Red }
      throw 'Task definition registration failed after retry'
    } else {
      try { $jd = $regOut2 | ConvertFrom-Json; $taskDefArn = $jd.taskDefinition.taskDefinitionArn } catch {}
      if (-not $taskDefArn) { throw 'Registration retry succeeded but ARN missing' }
      Write-Host "[ECS] Registered (no healthCheck): $taskDefArn" -ForegroundColor Green
    }
  } else {
    throw 'Task definition registration failed'
  }
} else {
  try { $jd = $regOut | ConvertFrom-Json; $taskDefArn = $jd.taskDefinition.taskDefinitionArn } catch {}
  if (-not $taskDefArn) { Write-Host '[Error] Could not parse ARN from success output' -ForegroundColor Red; throw 'Missing taskDefArn' }
  Write-Host "[ECS] Registered: $taskDefArn" -ForegroundColor Green
}

if ($UpdateService) {
  # Ensure cluster exists
  $clusterDesc = aws ecs describe-clusters --clusters $Cluster --region $Region | ConvertFrom-Json
  if (-not ($clusterDesc.clusters | Where-Object { $_.status -eq 'ACTIVE' })) {
    Write-Host "[ECS] Cluster '$Cluster' not found. Creating..." -ForegroundColor Yellow
    aws ecs create-cluster --cluster-name $Cluster --region $Region | Out-Null
    Write-Host '[ECS] Cluster created' -ForegroundColor Green
  }
  # Check service existence
  $svcDescRaw = aws ecs describe-services --cluster $Cluster --services $Service --region $Region | ConvertFrom-Json
  $serviceExists = $false
  if ($svcDescRaw.services -and $svcDescRaw.services[0].status -and $svcDescRaw.failures.Count -eq 0) { $serviceExists = $true }
  if (-not $serviceExists) {
    if (-not $Subnets -or -not $SecurityGroups) { throw 'Creating service requires -Subnets and -SecurityGroups.' }
    $assignPublic = if ($AssignPublicIp) { 'ENABLED' } else { 'DISABLED' }
    Write-Host "[ECS] Creating service $Service (desiredCount=$DesiredCount)" -ForegroundColor Cyan
    $createArgs = @(
      'ecs','create-service',
      '--cluster',$Cluster,
      '--service-name',$Service,
      '--task-definition',$taskDefArn,
      '--desired-count',$DesiredCount,
      '--launch-type','FARGATE',
      '--region',$Region,
      '--network-configuration',
      ('awsvpcConfiguration={subnets=[' + ($Subnets -join ',') + '],securityGroups=[' + ($SecurityGroups -join ',') + '],assignPublicIp=' + $assignPublic + '}')
    )
    $createOut = aws @createArgs 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host $createOut -ForegroundColor Red; throw 'Service creation failed' }
    Write-Host '[ECS] Service created' -ForegroundColor Green
  } else {
    Write-Host '[ECS] Updating existing service' -ForegroundColor Cyan
    $updateArgs = @('ecs','update-service','--cluster',$Cluster,'--service',$Service,'--task-definition',$taskDefArn,'--region',$Region)
    if ($ForceNewDeployment) { $updateArgs += '--force-new-deployment' }
    if ($DesiredCount -gt 0) { $updateArgs += @('--desired-count',$DesiredCount) }
    $updateOut = aws @updateArgs 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host $updateOut -ForegroundColor Red; throw 'Service update failed' }
    Write-Host '[ECS] Service update initiated' -ForegroundColor Green
  }
  if ($Wait) {
    Write-Host "[ECS] Waiting for stability (timeout ${WaitTimeoutSeconds}s)" -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
    while ($true) {
      Start-Sleep -Seconds 6
      $svc = aws ecs describe-services --cluster $Cluster --services $Service --region $Region | ConvertFrom-Json
      $svcObj = $svc.services[0]
      if (-not $svcObj) { Write-Host '[ECS][Wait] Describe failed; retrying' -ForegroundColor Yellow; continue }
      $prim = $svcObj.deployments | Where-Object { $_.status -eq 'PRIMARY' }
      Write-Host ("[ECS][Wait] running={0} pending={1} desired={2} rolloutState={3}" -f $svcObj.runningCount,$svcObj.pendingCount,$svcObj.desiredCount,$prim.rolloutState) -ForegroundColor DarkGray
      if ($prim.rolloutState -eq 'COMPLETED' -and $svcObj.runningCount -eq $svcObj.desiredCount -and $svcObj.pendingCount -eq 0) { Write-Host '[ECS] Deployment stable' -ForegroundColor Green; break }
      if ((Get-Date) -gt $deadline) { throw "Timeout waiting for service stability after ${WaitTimeoutSeconds}s" }
    }
  } else {
    Write-Host '[ECS] Skipping wait (pass -Wait)' -ForegroundColor DarkGray
  }
} else {
  Write-Host '[ECS] Skipping service update (omit -UpdateService)' -ForegroundColor Yellow
}

Write-Host '[Deploy] Complete' -ForegroundColor Green
