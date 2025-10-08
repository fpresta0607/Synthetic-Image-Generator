#!/bin/bash
# EC2 GPU user data - install Docker + NVIDIA drivers + run app

set -e

echo "==> Installing Docker and NVIDIA drivers..."

# Install Docker
yum update -y
yum install -y docker git
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user

# Install NVIDIA drivers for g4dn
yum install -y gcc kernel-devel-$(uname -r)
aws s3 cp --recursive s3://ec2-linux-nvidia-drivers/latest/ .
chmod +x NVIDIA-Linux-x86_64*.run
./NVIDIA-Linux-x86_64*.run --silent

# Install NVIDIA Container Toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.repo | \
    tee /etc/yum.repos.d/nvidia-container-toolkit.repo

yum install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# Test GPU
nvidia-smi

echo "==> Pulling and running Docker image..."

# Login to ECR
aws ecr get-login-password --region us-east-1 | \
    docker login --username AWS --password-stdin 401753844565.dkr.ecr.us-east-1.amazonaws.com

# Pull image (you'll need to push a working image first)
docker pull 401753844565.dkr.ecr.us-east-1.amazonaws.com/photosynth-full:gpu-optimized || {
    echo "GPU image not found, using CPU version as fallback"
    docker pull 401753844565.dkr.ecr.us-east-1.amazonaws.com/photosynth-full:fix-entrypoint
    docker run -d \
        --name photosynth \
        -p 3000:3000 -p 5001:5001 \
        -e WARM_MODEL=1 \
        -e GEN_MAX_WORKERS=2 \
        -e MODEL_CACHE_SIZE=2000 \
        401753844565.dkr.ecr.us-east-1.amazonaws.com/photosynth-full:fix-entrypoint
    exit 0
}

# Run with GPU
docker run -d \
    --name photosynth \
    --gpus all \
    -p 3000:3000 -p 5001:5001 \
    -e WARM_MODEL=1 \
    -e SAM_FP16=1 \
    -e CUDA_VISIBLE_DEVICES=0 \
    -e GEN_MAX_WORKERS=4 \
    401753844565.dkr.ecr.us-east-1.amazonaws.com/photosynth-full:gpu-optimized

echo "==> Done! Application starting..."
echo "Check logs: docker logs -f photosynth"
