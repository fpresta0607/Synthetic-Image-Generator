[CmdletBinding()] param(
  [Parameter(Mandatory)] [string]$Region,
  [Parameter(Mandatory)] [string]$Repository,
  [Parameter(Mandatory)] [string]$Cluster,
  [Parameter(Mandatory)] [string]$Service,
  [string]$ContainerName,
  [string]$ImageTag,
  [switch]$SkipBuild
)
$ErrorActionPreference='Stop'
function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Gray }
function Sec($m){ Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Fail($m){ Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

if(-not $ImageTag){ if(Get-Command git -ErrorAction SilentlyContinue){ try{ $ImageTag=(git rev-parse --short HEAD) }catch{} }; if(-not $ImageTag){ $ImageTag=(Get-Date -Format 'yyyyMMddHHmmss') } }
$acct = aws sts get-caller-identity --query 'Account' --output text --region $Region 2>$null
if(-not $acct){ Fail 'Could not resolve AWS account (aws sts get-caller-identity)' }
$image = "${acct}.dkr.ecr.${Region}.amazonaws.com/${Repository}:${ImageTag}"
Sec 'Parameters'
Info "Region=$Region Account=$acct Repo=$Repository Cluster=$Cluster Service=$Service Image=$image ContainerName=$ContainerName SkipBuild=$($SkipBuild.IsPresent)"

# Ensure repo
Sec 'ECR'
$exists = aws ecr describe-repositories --repository-names $Repository --region $Region 2>$null
if(-not $exists){ Info "Creating ECR repo $Repository"; aws ecr create-repository --repository-name $Repository --region $Region | Out-Null }
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin "$acct.dkr.ecr.$Region.amazonaws.com" | Out-Null

if(-not $SkipBuild){
  Sec 'Build'
  docker build --target full -t $image .
  if($LASTEXITCODE -ne 0){ Fail 'Docker build failed' }
  Sec 'Push'
  docker push $image | Write-Host
}else{ Info 'Skipping build/push' }

Sec 'Describe current task def'
$curr = aws ecs describe-services --cluster $Cluster --services $Service --region $Region --query 'services[0].taskDefinition' --output text 2>$null
if(-not $curr -or $curr -eq 'None'){ Fail 'Could not fetch current task definition ARN' }
Info "Current TD: $curr"
$td = aws ecs describe-task-definition --task-definition $curr --region $Region --query 'taskDefinition' --output json | ConvertFrom-Json

if($ContainerName){ foreach($c in $td.containerDefinitions){ if($c.name -eq $ContainerName){ $c.image = $image } } }
else { foreach($c in $td.containerDefinitions){ $c.image = $image } }

$payload = [ordered]@{
  family = $td.family
  networkMode = $td.networkMode
  requiresCompatibilities = $td.requiresCompatibilities
  cpu = $td.cpu
  memory = $td.memory
  executionRoleArn = $td.executionRoleArn
  taskRoleArn = $td.taskRoleArn
  containerDefinitions = $td.containerDefinitions
  volumes = $td.volumes
  placementConstraints = $td.placementConstraints
}
$payloadJson = ($payload | ConvertTo-Json -Depth 20)
Sec 'Register new task definition'
$newArn = aws ecs register-task-definition --cli-input-json $payloadJson --region $Region --query 'taskDefinition.taskDefinitionArn' --output text 2>$null
if(-not $newArn){ Fail 'Registration failed (null ARN)' }
Info "New TD: $newArn"

Sec 'Update service'
aws ecs update-service --cluster $Cluster --service $Service --task-definition $newArn --region $Region --deployment-configuration 'minimumHealthyPercent=100,maximumPercent=200' | Out-Null
Info 'Service update initiated'

Sec 'Wait for stabilization'
$deadline = (Get-Date).AddMinutes(5)
while((Get-Date) -lt $deadline){
  Start-Sleep 6
  $dep = aws ecs describe-services --cluster $Cluster --services $Service --region $Region --query 'services[0].deployments | length(@)' --output text 2>$null
  if($dep -eq '1'){ Info 'Stabilized'; break }
}
if($dep -ne '1'){ Fail 'Timeout waiting for stabilization' }

Sec 'Summary'
aws ecs describe-services --cluster $Cluster --services $Service --region $Region --query 'services[0].{running:runningCount,desired:desiredCount,taskDef:taskDefinition}'
Write-Host "Deployment complete -> $image" -ForegroundColor Green
