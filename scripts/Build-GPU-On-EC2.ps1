# Build GPU Docker Image on EC2 for Fast ECR Push
# This script launches an EC2 instance in us-east-1, builds the image, and pushes to ECR

param(
    [string]$Region = "us-east-1",
    [string]$InstanceType = "t3.xlarge",  # 4 vCPU, 16 GB - good for Docker builds
    [string]$ImageTag = "gpu-optimized",
    [string]$KeyName = "",  # SSH key name (optional)
    [switch]$TerminateAfter  # Terminate instance after successful push
)

$ErrorActionPreference = "Stop"
$AccountId = "401753844565"
$RepositoryName = "photosynth-full"
$ImageUri = "$AccountId.dkr.ecr.$Region.amazonaws.com/${RepositoryName}:$ImageTag"

Write-Host "==> EC2 GPU Build Script" -ForegroundColor Cyan
Write-Host "    Region: $Region" -ForegroundColor Gray
Write-Host "    Instance Type: $InstanceType" -ForegroundColor Gray
Write-Host "    Target: $ImageUri" -ForegroundColor Gray

# Get default VPC
Write-Host "`n[1/6] Finding VPC and subnet..." -ForegroundColor Yellow
$vpc = aws ec2 describe-vpcs --region $Region --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text
$subnet = aws ec2 describe-subnets --region $Region --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[0].SubnetId' --output text
Write-Host "    VPC: $vpc" -ForegroundColor Gray
Write-Host "    Subnet: $subnet" -ForegroundColor Gray

# Create security group if needed
Write-Host "`n[2/6] Setting up security group..." -ForegroundColor Yellow
$sgName = "docker-builder-sg"
$sgId = aws ec2 describe-security-groups --region $Region --filters "Name=group-name,Values=$sgName" --query 'SecurityGroups[0].GroupId' --output text 2>$null

if ($sgId -eq "None" -or [string]::IsNullOrEmpty($sgId)) {
    $sgId = aws ec2 create-security-group --region $Region --group-name $sgName --description "Docker builder security group" --vpc-id $vpc --query 'GroupId' --output text
    aws ec2 authorize-security-group-ingress --region $Region --group-id $sgId --protocol tcp --port 22 --cidr 0.0.0.0/0 | Out-Null
    Write-Host "    Created: $sgId" -ForegroundColor Green
} else {
    Write-Host "    Using existing: $sgId" -ForegroundColor Gray
}

# Create IAM role for ECR access if needed
Write-Host "`n[3/6] Setting up IAM role..." -ForegroundColor Yellow
$roleName = "EC2-Docker-Builder-Role"
$roleArn = aws iam get-role --role-name $roleName --query 'Role.Arn' --output text 2>$null

if ([string]::IsNullOrEmpty($roleArn) -or $roleArn -eq "None") {
    Write-Host "    Creating IAM role..." -ForegroundColor Gray
    
    $trustPolicy = @'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
'@
    
    $trustPolicy | Out-File -FilePath "trust-policy.json" -Encoding UTF8
    aws iam create-role --role-name $roleName --assume-role-policy-document "file://trust-policy.json" | Out-Null
    aws iam attach-role-policy --role-name $roleName --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser" | Out-Null
    aws iam create-instance-profile --instance-profile-name $roleName | Out-Null
    aws iam add-role-to-instance-profile --instance-profile-name $roleName --role-name $roleName | Out-Null
    Remove-Item "trust-policy.json" -Force
    Start-Sleep -Seconds 10  # Wait for IAM propagation
    Write-Host "    Created: $roleName" -ForegroundColor Green
} else {
    Write-Host "    Using existing: $roleName" -ForegroundColor Gray
}

# Get latest Amazon Linux 2023 AMI
Write-Host "`n[4/6] Finding latest Amazon Linux AMI..." -ForegroundColor Yellow
$amiId = aws ec2 describe-images --region $Region --owners amazon --filters "Name=name,Values=al2023-ami-*-x86_64" "Name=state,Values=available" --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text
Write-Host "    AMI: $amiId" -ForegroundColor Gray

# Create user data script
$userData = @"
#!/bin/bash
set -e

# Install Docker
yum update -y
yum install -y docker git
systemctl start docker
systemctl enable docker

# Install AWS CLI (already included in AL2023)
# Add ec2-user to docker group
usermod -a -G docker ec2-user

# Clone repository
cd /home/ec2-user
git clone https://github.com/fpresta0607/Synthetic-Image-Generator.git
cd Synthetic-Image-Generator
git checkout ecs

# Login to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 401753844565.dkr.ecr.us-east-1.amazonaws.com

# Build image
docker build -f Dockerfile.gpu -t photosynth-full:gpu-optimized --target full .

# Tag and push
docker tag photosynth-full:gpu-optimized 401753844565.dkr.ecr.us-east-1.amazonaws.com/photosynth-full:gpu-optimized
docker push 401753844565.dkr.ecr.us-east-1.amazonaws.com/photosynth-full:gpu-optimized

# Signal completion
echo "BUILD_COMPLETE" > /home/ec2-user/build-status.txt
"@

$userDataEncoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($userData))

# Launch EC2 instance
Write-Host "`n[5/6] Launching EC2 instance..." -ForegroundColor Yellow
$keyParam = if ($KeyName) { "--key-name $KeyName" } else { "" }
$instanceId = aws ec2 run-instances --region $Region --image-id $amiId --instance-type $InstanceType --subnet-id $subnet --security-group-ids $sgId --iam-instance-profile "Name=$roleName" --user-data $userDataEncoded --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=docker-gpu-builder}]" $keyParam --query 'Instances[0].InstanceId' --output text

Write-Host "    Instance ID: $instanceId" -ForegroundColor Green
Write-Host "    Waiting for instance to start..." -ForegroundColor Gray
aws ec2 wait instance-running --region $Region --instance-ids $instanceId

$publicIp = aws ec2 describe-instances --region $Region --instance-ids $instanceId --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
Write-Host "    Public IP: $publicIp" -ForegroundColor Green

# Monitor build progress
Write-Host "`n[6/6] Building and pushing image on EC2..." -ForegroundColor Yellow
Write-Host "    This will take 10-15 minutes for build + 2-5 minutes for push" -ForegroundColor Gray
Write-Host "    Monitor logs with: aws ec2 get-console-output --instance-id $instanceId --region $Region --output text" -ForegroundColor Gray

# Wait for completion (check every 30 seconds)
$maxWaitMinutes = 30
$waited = 0
$complete = $false

while ($waited -lt $maxWaitMinutes -and -not $complete) {
    Start-Sleep -Seconds 30
    $waited += 0.5
    
    # Check if build is complete by looking at console output
    $output = aws ec2 get-console-output --instance-id $instanceId --region $Region --output text 2>$null
    if ($output -match "BUILD_COMPLETE") {
        $complete = $true
        Write-Host "    Build and push completed successfully!" -ForegroundColor Green
    } else {
        Write-Host "    Still building... ($waited minutes elapsed)" -ForegroundColor Gray
    }
}

if (-not $complete) {
    Write-Host "    WARNING: Build may still be in progress" -ForegroundColor Yellow
    Write-Host "    Check instance console: aws ec2 get-console-output --instance-id $instanceId --region $Region" -ForegroundColor Yellow
}

# Terminate instance if requested
if ($TerminateAfter -and $complete) {
    Write-Host "`nTerminating EC2 instance..." -ForegroundColor Yellow
    aws ec2 terminate-instances --region $Region --instance-ids $instanceId | Out-Null
    Write-Host "    Instance terminating" -ForegroundColor Green
} else {
    Write-Host "`n==> EC2 Instance Details" -ForegroundColor Cyan
    Write-Host "    Instance ID: $instanceId" -ForegroundColor Gray
    Write-Host "    Public IP: $publicIp" -ForegroundColor Gray
    Write-Host "    To terminate: aws ec2 terminate-instances --instance-ids $instanceId --region $Region" -ForegroundColor Gray
}

Write-Host "`n==> Next Steps" -ForegroundColor Cyan
Write-Host "    1. Verify image in ECR: aws ecr describe-images --repository-name $RepositoryName --region $Region" -ForegroundColor Gray
Write-Host "    2. Deploy to ECS: .\scripts\Deploy-GPU.ps1 -SkipBuild -WaitForSteady" -ForegroundColor Gray
