<#!
.SYNOPSIS
  Bootstraps the initial ECS Fargate service (task definition + service) when it does not yet exist.

.DESCRIPTION
  Creates (if missing): ECR repo, CloudWatch log group, task definition, security group (optional),
  and ECS service on an existing or new cluster. Designed for first-time environment bring-up.

.NOTES
  Requires: aws cli v2, docker (for image build/push if not skipped), permissions for ecs, ec2:Describe*, ec2:CreateSecurityGroup, logs:CreateLogGroup, iam:PassRole.
  Does NOT create IAM roles; expects an execution role (e.g. ecsTaskExecutionRole) already present or passed in.
#>
[CmdletBinding()] param(
  [Parameter(Mandatory)] [string]$Region,
  [Parameter(Mandatory)] [string]$Repository,          # photosynth-full
  [Parameter(Mandatory)] [string]$Cluster,             # photosynth
  [Parameter(Mandatory)] [string]$Service,             # photosynth-full
  [string]$ImageTag,                                   # optional specific tag (defaults to latest build or git sha)
  [int]$Cpu = 1024,
  [int]$Memory = 2048,
  [int]$DesiredCount = 1,
  [string]$ExecutionRoleArn,                          # optional; if omitted, attempts ecsTaskExecutionRole
  [string]$TaskRoleArn,                               # optional; pass if you have one; else omitted
  [string]$VpcId,                                     # optional; if omitted attempts default VPC
  [string[]]$SubnetIds,                               # optional; auto-discover first 2 public if omitted
  [string]$SecurityGroupId,                           # optional existing SG
  [switch]$CreateSecurityGroup,                       # create SG if not provided
  [switch]$SkipBuild,
  [switch]$SkipLogGroupCreation,
  [switch]$ForceCreateService,                        # if a failed ghost service exists
  [switch]$ShowTaskDefinitionJson                     # optional: output task def JSON for debugging
)

$ErrorActionPreference = 'Stop'
function Sec($m){ Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Gray }
function Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

function Get-SecurityGroupIdByName($name, $vpcId, $region){
  try {
    $id = aws ec2 describe-security-groups --group-names $name --region $region --query 'SecurityGroups[0].GroupId' --output text 2>$null
    if($id -and $id -ne 'None'){ return $id }
  } catch { }
  try {
    if($vpcId){
      $id = aws ec2 describe-security-groups --filters Name=vpc-id,Values=$vpcId Name=group-name,Values=$name --region $region --query 'SecurityGroups[0].GroupId' --output text 2>$null
      if($id -and $id -ne 'None'){ return $id }
    }
  } catch { }
  return $null
}

foreach($bin in 'aws','docker'){ if(-not (Get-Command $bin -ErrorAction SilentlyContinue)){ Fail "Required executable missing: $bin" } }

Sec 'Account'
$AccountId = aws sts get-caller-identity --query 'Account' --output text --region $Region 2>$null
if(-not $AccountId){ Fail 'Unable to resolve AWS AccountId (sts get-caller-identity failed)' }
Info "AccountId=$AccountId"

if(-not $ImageTag){
  if(Get-Command git -ErrorAction SilentlyContinue){ try { $ImageTag = (git rev-parse --short HEAD) } catch {} }
  if(-not $ImageTag){ $ImageTag = 'bootstrap' }
}
$ImageUri = "${AccountId}.dkr.ecr.${Region}.amazonaws.com/${Repository}:${ImageTag}"
Info "ImageUri=$ImageUri"

Sec 'ECR'
$repoExists = aws ecr describe-repositories --repository-names $Repository --region $Region 2>$null
if(-not $repoExists){
  Info "Creating ECR repository $Repository"
  aws ecr create-repository --repository-name $Repository --region $Region | Out-Null
}
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin "$AccountId.dkr.ecr.$Region.amazonaws.com" | Out-Null
if(-not $SkipBuild){
  Sec 'Build image'
  docker build --target full -t $ImageUri .
  if($LASTEXITCODE -ne 0){ Fail 'Docker build failed' }
  Sec 'Push image'
  docker push $ImageUri | Write-Host
} else { Warn 'Skipping build/push (-SkipBuild supplied)' }

Sec 'Cluster'
$clusterStatus = aws ecs describe-clusters --clusters $Cluster --region $Region --query 'clusters[0].status' --output text 2>$null
if(-not $clusterStatus -or $clusterStatus -eq 'None'){
  Info "Creating cluster $Cluster"
  aws ecs create-cluster --cluster-name $Cluster --region $Region | Out-Null
} else { Info "Cluster exists (status=$clusterStatus)" }

Sec 'Networking discovery'
if(-not $VpcId){
  $VpcId = aws ec2 describe-vpcs --filters Name=isDefault,Values=true --region $Region --query 'Vpcs[0].VpcId' --output text 2>$null
  if(-not $VpcId -or $VpcId -eq 'None'){ Fail 'No VPC specified and default VPC not found. Pass -VpcId.' }
  Info "Using default VPC $VpcId"
}
if(-not $SubnetIds -or $SubnetIds.Count -eq 0){
  $publicSubnets = aws ec2 describe-subnets --filters Name=vpc-id,Values=$VpcId --region $Region --query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' --output text 2>$null
  $SubnetIds = $publicSubnets -split '\s+' | Where-Object { $_ }
  if($SubnetIds.Count -lt 2){ Warn 'Could not find 2 public subnets; will proceed with what was found.' }
  Info "Auto-selected subnets: $($SubnetIds -join ',')"
}
if(-not $SecurityGroupId){
  $sgName = "$Service-sg"
  if($CreateSecurityGroup){
    Info "Creating security group $sgName"
    try {
      $SecurityGroupId = aws ec2 create-security-group --group-name $sgName --description "SG for $Service" --vpc-id $VpcId --region $Region --query 'GroupId' --output text 2>&1
      if($LASTEXITCODE -ne 0){
        if($SecurityGroupId -match 'InvalidGroup.Duplicate'){
          Warn "Security group already exists; reusing existing group $sgName"
          $SecurityGroupId = Get-SecurityGroupIdByName -name $sgName -vpcId $VpcId -region $Region
        } else { Fail "Failed to create security group: $SecurityGroupId" }
      }
    } catch {
      Fail "Unhandled error creating security group: $($_.Exception.Message)"
    }
    if($SecurityGroupId){
      # Attempt to add ingress rules idempotently
      foreach($port in 3000,5001){
        try { aws ec2 authorize-security-group-ingress --group-id $SecurityGroupId --protocol tcp --port $port --cidr 0.0.0.0/0 --region $Region 2>$null } catch { }
      }
    }
  }
  if(-not $SecurityGroupId){
    $SecurityGroupId = Get-SecurityGroupIdByName -name $sgName -vpcId $VpcId -region $Region
  }
  if(-not $SecurityGroupId){
    Fail 'No security group could be resolved. Supply -SecurityGroupId or use -CreateSecurityGroup.'
  }
}
Info "SecurityGroup=$SecurityGroupId"

Sec 'Roles'
if(-not $ExecutionRoleArn){ $ExecutionRoleArn = "arn:aws:iam::${AccountId}:role/ecsTaskExecutionRole" }
Info "ExecutionRoleArn=$ExecutionRoleArn"
if($TaskRoleArn){ Info "TaskRoleArn=$TaskRoleArn" } else { Info 'TaskRoleArn=<none>' }

# Validate that execution role exists (non-fatal warning)
try {
  $roleName = ($ExecutionRoleArn -split '/' | Select-Object -Last 1)
  $roleExists = aws iam get-role --role-name $roleName --region $Region --query 'Role.RoleName' --output text 2>$null
  if(-not $roleExists -or $roleExists -eq 'None'){ Warn "Execution role $roleName not found. Task definition registration may fail (iam:PassRole required)." }
} catch { Warn "Unable to validate execution role existence: $($_.Exception.Message)" }

Sec 'Log group'
$logGroup = "/ecs/$Service"
if($SkipLogGroupCreation){
  Warn 'Skipping log group creation per -SkipLogGroupCreation'
} else {
  try {
    aws logs create-log-group --log-group-name $logGroup --region $Region 2>$null
    Info "Log group ensured: $logGroup"
  } catch {
    Warn "Failed to create log group (continuing). Ensure role has logs:CreateLogGroup. Error: $($_.Exception.Message)"
  }
}

Sec 'Existing service check'
$serviceDesc = aws ecs describe-services --cluster $Cluster --services $Service --region $Region --query 'services[0].status' --output text 2>$null
if($serviceDesc -and $serviceDesc -ne 'None' -and $serviceDesc -ne 'MISSING'){
  Fail "Service $Service already exists (status=$serviceDesc). Nothing to bootstrap."
}
elseif($serviceDesc -and -not $ForceCreateService){
  Warn "Describe returned status=$serviceDesc; continuing to create (ForceCreateService override not required)."
}

Sec 'Register initial task definition'
$containerDef = [ordered]@{
  name = $Service
  image = $ImageUri
  essential = $true
  portMappings = @(@{containerPort=3000;protocol='tcp'},@{containerPort=5001;protocol='tcp'})
  environment = @(
    @{ name='FLASK_PORT'; value='5001' },
    @{ name='PY_SERVICE_URL'; value='http://127.0.0.1:5001' }
  )
  healthCheck = @{ command=@('CMD-SHELL','curl -f http://localhost:3000/api/backend/health || curl -f http://localhost:3000/ || exit 1'); interval=30; timeout=5; retries=3; startPeriod=10 }
}
if(-not $SkipLogGroupCreation){
  $containerDef.logConfiguration = @{ logDriver='awslogs'; options=@{ 'awslogs-group'=$logGroup; 'awslogs-region'=$Region; 'awslogs-stream-prefix'='ecs' } }
}
$taskRoot = [ordered]@{
  family = $Service
  networkMode = 'awsvpc'
  requiresCompatibilities = @('FARGATE')
  cpu = "$Cpu"
  memory = "$Memory"
  executionRoleArn = $ExecutionRoleArn
  containerDefinitions = @($containerDef)
}
if($TaskRoleArn){ $taskRoot.taskRoleArn = $TaskRoleArn }
$tdJson = ($taskRoot | ConvertTo-Json -Depth 30)
if($ShowTaskDefinitionJson){ Sec 'Task definition JSON'; $tdJson | Write-Host }

$tempFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "taskdef-${Service}-$(Get-Random).json")
Set-Content -Path $tempFile -Value $tdJson -Encoding utf8
try {
  $normTemp = $tempFile -replace '\\','/'  # normalize for file:// usage
  $regOutput = aws ecs register-task-definition --cli-input-json file://$normTemp --region $Region --query 'taskDefinition.taskDefinitionArn' --output text 2>&1
  if($LASTEXITCODE -ne 0 -or -not $regOutput -or $regOutput -eq 'None'){
    Warn "First registration attempt did not return ARN (exit=$LASTEXITCODE). Retrying without --query for diagnostics..."
    $fullOutput = aws ecs register-task-definition --cli-input-json file://$normTemp --region $Region 2>&1
    if($LASTEXITCODE -ne 0){
      Fail "Task definition registration failed (second attempt). Output:`n$fullOutput`nTaskDef JSON file: $tempFile"
    }
    # Try to parse ARN from full JSON
    try {
      $jsonObj = $fullOutput | ConvertFrom-Json -ErrorAction Stop
      $TaskDefArn = $jsonObj.taskDefinition.taskDefinitionArn
    } catch { }
    if(-not $TaskDefArn){ Fail "Could not extract taskDefinitionArn from registration output. Raw:`n$fullOutput" }
  } else {
    $TaskDefArn = $regOutput.Trim()
  }
  Info "Registered task definition: $TaskDefArn"
} catch {
  $excMsg = $_.Exception.Message
  Warn "Exception thrown during registration attempt: $excMsg"
  # Fallback: attempt to find an existing task definition for this family
  try {
    $existingTd = aws ecs list-task-definitions --family-prefix $Service --sort DESC --max-items 1 --region $Region --query 'taskDefinitionArns[0]' --output text 2>$null
    if($existingTd -and $existingTd -ne 'None'){
      Warn "Using existing latest task definition: $existingTd"
      $TaskDefArn = $existingTd
    } else {
      Fail "Exception during task definition registration and no existing task definition found. File: $tempFile Error: $excMsg"
    }
  } catch {
    Fail "Registration and fallback both failed. File: $tempFile PrimaryError: $excMsg SecondaryError: $($_.Exception.Message)"
  }
} finally {
  if(Test-Path $tempFile){ Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
}

Sec 'Create service'
$subnetList = ($SubnetIds | ForEach-Object { $_ }) -join ','
aws ecs create-service `
  --cluster $Cluster `
  --service-name $Service `
  --task-definition $TaskDefArn `
  --desired-count $DesiredCount `
  --launch-type FARGATE `
  --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200" `
  --network-configuration "awsvpcConfiguration={subnets=[$subnetList],securityGroups=[$SecurityGroupId],assignPublicIp=ENABLED}" `
  --region $Region | Out-Null
Info 'Service creation initiated.'

Sec 'Wait for initial stabilization'
$deadline=(Get-Date).AddMinutes(10)
while((Get-Date) -lt $deadline){
  Start-Sleep 6
  $depCount = aws ecs describe-services --cluster $Cluster --services $Service --region $Region --query 'services[0].deployments | length(@)' --output text 2>$null
  if($depCount -eq '1'){ Info 'Stable'; break }
}
if($depCount -ne '1'){ Warn 'Initial deployment not yet stable (continuing anyway).' }

Sec 'Summary'
aws ecs describe-services --cluster $Cluster --services $Service --region $Region --query 'services[0].{status:status,desired:desiredCount,running:runningCount,taskDef:taskDefinition}'
Write-Host "Bootstrap complete. Next deploys can use Invoke-EcsPipeline or Deploy-EcsSimple scripts." -ForegroundColor Green
