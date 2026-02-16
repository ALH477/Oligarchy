# Deployment Guide

This guide covers deploying DeMoD Voice Clone in production environments.

## Deployment Options

### 1. Nix Profile Installation

**Best for:** Individual developer machines, reproducible environments

```bash
# Install to user profile
nix profile install github:DeMoDLLC/voice-clone-flake

# Use the CLI
demod-voice --help

# Update to latest
nix profile upgrade demod-voice

# Remove
nix profile remove demod-voice
```

### 2. Docker Deployment

**Best for:** Cloud deployments, containerized workflows, CI/CD

#### Pull and Run

```bash
# Pull latest image
docker pull ghcr.io/demodllc/demod-voice:latest

# Run with GPU support (NVIDIA)
docker run --gpus all \
  -v $(pwd)/workspace:/workspace \
  ghcr.io/demodllc/demod-voice:latest \
  xtts-zero-shot /workspace/ref.wav "Text to synthesize" \
  --output /workspace/output.wav --gpu

# Run CPU-only
docker run \
  -v $(pwd)/workspace:/workspace \
  ghcr.io/demodllc/demod-voice:latest \
  piper-infer /workspace/model.onnx "Hello world" \
  --output /workspace/hello.wav
```

#### Docker Compose

Create `docker-compose.yml`:

```yaml
version: '3.8'

services:
  demod-voice:
    image: ghcr.io/demodllc/demod-voice:latest
    volumes:
      - ./data:/workspace
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
```

Run batch jobs:

```bash
docker-compose run demod-voice \
  xtts-zero-shot /workspace/ref.wav "Batch synthesis" \
  --output /workspace/batch-001.wav --gpu
```

### 3. Kubernetes Deployment

**Best for:** Large-scale production, auto-scaling, high availability

#### Deployment Manifest

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demod-voice
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demod-voice
  template:
    metadata:
      labels:
        app: demod-voice
    spec:
      containers:
      - name: demod-voice
        image: ghcr.io/demodllc/demod-voice:latest
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: "16Gi"
          requests:
            memory: "8Gi"
        volumeMounts:
        - name: workspace
          mountPath: /workspace
      volumes:
      - name: workspace
        persistentVolumeClaim:
          claimName: demod-voice-pvc
```

#### Service Exposure

```yaml
apiVersion: v1
kind: Service
metadata:
  name: demod-voice
spec:
  selector:
    app: demod-voice
  ports:
  - port: 8080
    targetPort: 8080
  type: LoadBalancer
```

### 4. NixOS System Configuration

**Best for:** NixOS servers, declarative infrastructure

Add to `/etc/nixos/configuration.nix`:

```nix
{ config, pkgs, ... }:

{
  # Enable Nix flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  
  # Install DeMoD Voice Clone system-wide
  environment.systemPackages = [
    (pkgs.callPackage (builtins.getFlake "github:DeMoDLLC/voice-clone-flake") {}).packages.${pkgs.system}.demod-voice
  ];
  
  # Create service user
  users.users.demod-voice = {
    isSystemUser = true;
    group = "demod-voice";
    home = "/var/lib/demod-voice";
    createHome = true;
  };
  
  users.groups.demod-voice = {};
  
  # Systemd service for batch processing
  systemd.services.demod-voice-worker = {
    description = "DeMoD Voice Clone Worker";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    
    serviceConfig = {
      Type = "simple";
      User = "demod-voice";
      Group = "demod-voice";
      WorkingDirectory = "/var/lib/demod-voice";
      ExecStart = "${pkgs.bash}/bin/bash -c 'your-worker-script.sh'";
      Restart = "on-failure";
    };
  };
}
```

Apply configuration:

```bash
sudo nixos-rebuild switch
```

## Production Best Practices

### Resource Planning

#### XTTS-v2 Requirements
- **VRAM:** 6-8 GB per concurrent inference
- **CPU:** 4+ cores recommended
- **RAM:** 16 GB minimum
- **Storage:** 5 GB for model cache

#### Piper Requirements
- **CPU:** 2+ cores (CPU-only)
- **RAM:** 2 GB minimum
- **Storage:** 500 MB per model

### Performance Tuning

#### CUDA Optimization

```bash
# Enable CUDA graphs (faster inference)
export CUDA_LAUNCH_BLOCKING=0

# Optimize CUDA memory allocation
export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:128
```

#### CPU Optimization

```bash
# Set thread count for ONNX Runtime
export OMP_NUM_THREADS=4
export MKL_NUM_THREADS=4
```

### Monitoring

#### Health Checks

```bash
# Docker health check
docker inspect --format='{{.State.Health.Status}}' demod-voice

# CLI health check
demod-voice --help && echo "OK" || echo "FAIL"
```

#### Logging

```bash
# Docker logs
docker logs -f demod-voice

# Kubernetes logs
kubectl logs -f deployment/demod-voice
```

### Scaling Strategies

#### Horizontal Scaling
- Run multiple Docker containers
- Use load balancer (nginx, HAProxy)
- Queue system for batch processing (Celery, RabbitMQ)

#### Vertical Scaling
- Larger GPU (T4 → A10 → A100)
- More VRAM for larger batches
- NVMe storage for faster model loading

### Security Hardening

#### Container Security

```dockerfile
# Run as non-root user
USER 1000:1000

# Read-only root filesystem
--read-only --tmpfs /tmp

# Drop capabilities
--cap-drop=ALL

# Limit resources
--memory=16g --cpus=4
```

#### Network Security

- Isolate in private network
- Use TLS for API endpoints
- Rate limiting on public endpoints
- API key authentication

### Backup and Recovery

#### Model Backups

```bash
# Backup model cache
tar -czf tts-models-backup.tar.gz ~/.local/share/tts/

# Restore
tar -xzf tts-models-backup.tar.gz -C ~/
```

#### Data Backups

```bash
# Backup workspace
rsync -av /workspace/ /backup/workspace/

# Restore
rsync -av /backup/workspace/ /workspace/
```

## Cloud Deployment Examples

### AWS EC2

```bash
# Launch instance (g4dn.xlarge for GPU)
aws ec2 run-instances \
  --image-id ami-xxxxxxxxx \
  --instance-type g4dn.xlarge \
  --key-name your-key \
  --security-group-ids sg-xxxxxxxx

# SSH and install
ssh -i your-key.pem ubuntu@ec2-instance
curl -L https://nixos.org/nix/install | sh
nix profile install github:DeMoDLLC/voice-clone-flake
```

### Google Cloud Platform

```bash
# Create instance with GPU
gcloud compute instances create demod-voice \
  --machine-type=n1-standard-4 \
  --accelerator=type=nvidia-tesla-t4,count=1 \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud

# Install CUDA drivers
gcloud compute ssh demod-voice
sudo apt-get install nvidia-driver-535
```

### Azure

```bash
# Create GPU VM
az vm create \
  --resource-group demod-rg \
  --name demod-voice \
  --image UbuntuLTS \
  --size Standard_NC6 \
  --generate-ssh-keys
```

## Troubleshooting

### GPU Not Detected

```bash
# Check NVIDIA driver
nvidia-smi

# Verify CUDA availability
python -c "import torch; print(torch.cuda.is_available())"

# Check Docker GPU access
docker run --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi
```

### Out of Memory

```bash
# Reduce batch size
# Use CPU mode
# Upgrade to larger GPU
# Enable gradient checkpointing
```

### Slow Inference

```bash
# Use GPU instead of CPU
# Enable CUDA graphs
# Use Piper instead of XTTS for speed
# Optimize ONNX model
```

## Cost Optimization

### Cloud GPU Pricing (Approximate)

- **AWS g4dn.xlarge:** $0.526/hr (T4 GPU)
- **GCP n1-standard-4 + T4:** $0.50/hr
- **Azure NC6:** $0.90/hr (K80 GPU)

### Recommendations

1. **Use spot/preemptible instances** for batch jobs (60-90% cheaper)
2. **Auto-scale** based on queue depth
3. **Use Piper** for production TTS (no GPU needed)
4. **Reserve instances** for steady workloads (40-60% savings)

## Support

- Documentation: https://github.com/DeMoDLLC/voice-clone-flake
- Issues: https://github.com/DeMoDLLC/voice-clone-flake/issues
- Email: support@demod.llc
