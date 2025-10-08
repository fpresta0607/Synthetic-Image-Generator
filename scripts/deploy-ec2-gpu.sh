#!/bin/bash
# Deploy on EC2 GPU instance (much simpler than Fargate GPU)

# Instance: g4dn.xlarge (NVIDIA T4 GPU, 4 vCPU, 16GB RAM)
# Cost: ~$0.30/hour spot, $0.526/hour on-demand

echo "==> Launching EC2 GPU instance..."

# Launch spot instance
INSTANCE_ID=$(aws ec2 run-instances \
    --region us-east-1 \
    --image-id ami-0c7217cdde317cfec \
    --instance-type g4dn.xlarge \
    --key-name your-key-name \
    --security-group-ids sg-07fdfd5af2ecf7d17 \
    --subnet-id subnet-08eef7a2733d3f14c \
    --iam-instance-profile Name=EC2-Docker-Builder-Role \
    --instance-market-options 'MarketType=spot,SpotOptions={MaxPrice=0.40,SpotInstanceType=one-time}' \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=100,VolumeType=gp3}' \
    --user-data file://ec2-gpu-userdata.sh \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=photosynth-gpu}]' \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance ID: $INSTANCE_ID"
echo "Waiting for instance to start..."

aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region us-east-1

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region us-east-1 \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo ""
echo "==> Instance running!"
echo "    Public IP: $PUBLIC_IP"
echo "    SSH: ssh -i your-key.pem ec2-user@$PUBLIC_IP"
echo "    App URL (in ~5 min): http://$PUBLIC_IP:3000"
echo ""
echo "Monitor startup: ssh -i your-key.pem ec2-user@$PUBLIC_IP 'tail -f /var/log/cloud-init-output.log'"
