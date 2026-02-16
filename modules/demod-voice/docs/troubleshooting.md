# Troubleshooting Guide

This guide covers common issues and solutions for DeMoD Voice Clone.

## Installation Issues

### Nix Installation Problems

**Problem:** Nix installation fails or flakes not enabled
```bash
# Solution: Install Nix with flakes
sh <(curl -L https://nixos.org/nix/install) --daemon
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

**Problem:** `nix develop` fails with permission errors
```bash
# Solution: Check Nix installation and permissions
sudo chown -R $(whoami) ~/.nix-profile
nix profile list
```

### Build Failures

**Problem:** Build fails with dependency conflicts
```bash
# Solution: Update nixpkgs and check overrides
nix flake update
nix build .#demod-voice
```

**Problem:** Hash mismatch errors
```bash
# Solution: Use fix-hashes.sh script
./fix-hashes.sh
nix build .#demod-voice
```

**Problem:** Coqui TTS build fails
```bash
# Solution: Check Python version and dependencies
python --version  # Should be 3.11
nix develop
python -c "import torch; print(torch.__version__)"
```

## Runtime Issues

### GPU Problems

**Problem:** CUDA not detected
```bash
# Check CUDA availability
python -c "import torch; print(torch.cuda.is_available())"

# Check NVIDIA drivers
nvidia-smi

# Inside Nix shell, check LD_LIBRARY_PATH
echo $LD_LIBRARY_PATH
```

**Problem:** Out of memory errors
```bash
# Check GPU memory usage
nvidia-smi

# Use CPU mode as fallback
demod-voice --cpu xtts-zero-shot ref.wav "text" --output out.wav

# Reduce batch size or use smaller models
```

**Problem:** GPU device not found
```bash
# List available devices
python -c "import torch; print(torch.cuda.device_count())"

# Set specific device
export CUDA_VISIBLE_DEVICES=0
```

### Model Issues

**Problem:** Model download fails
```bash
# Check internet connection
ping google.com

# Pre-download models manually
python -c "from TTS.api import TTS; TTS('tts_models/multilingual/multi-dataset/xtts_v2')"

# Check TTS_HOME location
echo $TTS_HOME
ls ~/.local/share/tts/
```

**Problem:** Model loading fails
```bash
# Check model cache
ls ~/.local/share/tts/

# Clear cache and retry
rm -rf ~/.local/share/tts/
```

**Problem:** Language support missing
```bash
# Check installed language packages
python -c "import gruut; print('gruut available')"
python -c "import jieba; print('jieba available')"

# Rebuild with language support
nix build .#demod-voice
```

### Audio Issues

**Problem:** Reference audio format not supported
```bash
# Check audio file format
file reference.wav
soxi reference.wav

# Convert to supported format
ffmpeg -i input.mp3 -ar 22050 -ac 1 output.wav
```

**Problem:** Audio quality poor
```bash
# Check reference audio quality
# Ensure clean speech, no background noise
# Use 6-10 seconds of speech
# Check sample rate (should be 22050 Hz)
```

**Problem:** Output audio silent or distorted
```bash
# Check output file
file output.wav
play output.wav  # or use any audio player

# Verify input text
echo "Your text here" | demod-voice xtts-zero-shot ref.wav - --output test.wav
```

## Configuration Issues

### Config File Problems

**Problem:** Config file not found
```bash
# Check config file location
ls ~/.config/demod-voice/config.yaml

# Create config file if missing
mkdir -p ~/.config/demod-voice
cat > ~/.config/demod-voice/config.yaml << EOF
default_language: en
gpu:
  enabled: true
  device_id: 0
output:
  sample_rate: 22050
  format: wav
EOF
```

**Problem:** Config validation errors
```bash
# Check config syntax
demod-voice health --json

# Validate YAML syntax
python -c "import yaml; yaml.safe_load(open('~/.config/demod-voice/config.yaml'))"
```

### Environment Variables

**Problem:** Environment variables not set
```bash
# Check required environment variables
echo $CUDA_VISIBLE_DEVICES
echo $NVIDIA_VISIBLE_DEVICES
echo $PYTHONPATH
echo $TTS_HOME

# Set missing variables
export TTS_HOME=~/.local/share/tts
export PYTHONPATH=$PYTHONPATH:/path/to/demod-voice
```

## Docker Issues

### Container Problems

**Problem:** Docker image not found
```bash
# Check available images
docker images

# Pull latest image
docker pull alh477/demod-voice:latest

# Check registry access
docker login
```

**Problem:** GPU not accessible in container
```bash
# Check NVIDIA Docker support
docker run --rm nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi

# Run with GPU support
docker run --gpus all alh477/demod-voice:latest health
```

**Problem:** Permission denied in container
```bash
# Run as non-root user
docker run --user $(id -u):$(id -g) alh477/demod-voice:latest

# Check volume permissions
ls -la /workspace
```

### Network Issues

**Problem:** Model download fails in container
```bash
# Check network connectivity
docker run alh477/demod-voice:latest ping google.com

# Use proxy if needed
docker run -e http_proxy=$http_proxy alh477/demod-voice:latest
```

## Performance Issues

### Slow Performance

**Problem:** XTTS inference very slow
```bash
# Check if using CPU instead of GPU
demod-voice health

# Force GPU mode
demod-voice --gpu xtts-zero-shot ref.wav "text" --output out.wav

# Check GPU memory
nvidia-smi
```

**Problem:** Piper inference slow
```bash
# Check CPU usage
htop

# Set thread count
export OMP_NUM_THREADS=4
export MKL_NUM_THREADS=4
```

**Problem:** High memory usage
```bash
# Monitor memory usage
free -h
nvidia-smi

# Clear caches
sudo sync && sudo sysctl -w vm.drop_caches=3
```

## Batch Processing Issues

### CSV Problems

**Problem:** CSV file format errors
```bash
# Check CSV format
head batch.csv

# Validate CSV structure
demod-voice batch batch.csv --verbose
```

**Problem:** File paths not found
```bash
# Check file paths in CSV
cat batch.csv | while IFS=, read ref text out lang; do
  echo "Checking: $ref"
  ls -la "$ref"
done
```

### Job Failures

**Problem:** Jobs failing silently
```bash
# Enable verbose logging
demod-voice batch batch.csv --verbose

# Use fail-fast mode
demod-voice batch batch.csv --fail-fast
```

**Problem:** Partial job completion
```bash
# Check output files
ls -la output_*.wav

# Review error logs
demod-voice batch batch.csv --verbose 2>&1 | grep ERROR
```

## Development Issues

### Testing Problems

**Problem:** Tests failing
```bash
# Run specific test
pytest tests/test_config.py -v

# Check test dependencies
python -m pytest --version

# Run with verbose output
pytest tests/ -v -s
```

**Problem:** Code formatting issues
```bash
# Format code
black bin/ demod_voice/

# Check linting
ruff check bin/ demod_voice/ --fix

# Type checking
mypy bin/ demod_voice/
```

### Import Errors

**Problem:** Module not found errors
```bash
# Check Python path
echo $PYTHONPATH

# Verify installation
python -c "import demod_voice.config; print('Config module loaded')"

# Rebuild package
nix build .#demod-voice
```

## System-Specific Issues

### macOS Issues

**Problem:** Apple Silicon compatibility
```bash
# Use CPU variant
docker pull alh477/demod-voice:cpu

# Check Rosetta compatibility
arch -x86_64 /bin/bash
```

### Windows Issues

**Problem:** Windows Subsystem for Linux (WSL)
```bash
# Check WSL version
wsl --list --verbose

# Enable GPU support in WSL
# Follow NVIDIA WSL2 setup guide
```

### Linux Distribution Issues

**Problem:** Distribution-specific package conflicts
```bash
# Check distribution
cat /etc/os-release

# Use Nix environment isolation
nix develop
```

## Getting Help

### Debug Information

**Collect system information:**
```bash
# System info
uname -a
nix --version
python --version

# Health check
demod-voice health --json

# Detailed logs
demod-voice --verbose health
```

**Report issues with:**
- Nix version
- System information
- Error messages
- Steps to reproduce
- Debug output from health check

### Community Support

- **GitHub Issues:** https://github.com/ALH477/demod-voice/issues
- **Discussions:** https://github.com/ALH477/demod-voice/discussions
- **Email:** alh477@proton.me

### Common Solutions Summary

1. **Always start with health check:**
   ```bash
   demod-voice health --json
   ```

2. **Update to latest version:**
   ```bash
   nix flake update
   nix build .#demod-voice
   ```

3. **Check environment variables:**
   ```bash
   echo $CUDA_VISIBLE_DEVICES
   echo $TTS_HOME
   ```

4. **Enable verbose logging:**
   ```bash
   demod-voice --verbose command
   ```

5. **Use CPU mode for debugging:**
   ```bash
   demod-voice --cpu command