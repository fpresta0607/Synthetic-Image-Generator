#!/bin/bash
set -ex

# Install Docker and Git
yum update -y
yum install -y docker git
systemctl start docker

# Clone repository
cd /home/ec2-user
git clone https://github.com/fpresta0607/Synthetic-Image-Generator.git
cd Synthetic-Image-Generator
git checkout ecs

# Login to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 401753844565.dkr.ecr.us-east-1.amazonaws.com

# Build GPU image
docker build -f Dockerfile.gpu -t photosynth-full:gpu-optimized --target full .

# Tag and push to ECR
docker tag photosynth-full:gpu-optimized 401753844565.dkr.ecr.us-east-1.amazonaws.com/photosynth-full:gpu-optimized
docker push 401753844565.dkr.ecr.us-east-1.amazonaws.com/photosynth-full:gpu-optimized

# Signal completion
echo "BUILD_COMPLETE" > /home/ec2-user/build-status.txt
