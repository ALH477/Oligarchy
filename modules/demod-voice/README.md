# DeMoD LLC Voice Clone

Production-grade local voice cloning and text-to-speech system built with Nix. Privacy-first, reproducible, and hardware-accelerated.

## Features

- **Zero-shot voice cloning** via Coqui XTTS-v2 (6-10 second reference audio)
- **Fast Piper TTS inference** for production deployment
- **Dataset preprocessing** for fine-tuning custom voices
- **GPU acceleration** (CUDA, ROCm, Vulkan via tinygrad)
- **Reproducible builds** with Nix flakes
- **Container-ready** Docker images
- **Multi-language support** with full phonemization for:
  - English (with DE/ES/FR variants)
  - Chinese (Simplified)
  - Japanese
  - Korean
  - Bengali
  - Additional languages via num2words integration
- **MIT licensed** and fully open source

## Quick Start

### Nix Flakes (Recommended)

```bash
# Run directly from GitHub
nix run github:DeMoDLLC/voice-clone-flake -- --help

# Or install to profile
nix profile install github:DeMoDLLC/voice-clone-flake

# Clone locally
git clone https://github.com/DeMoDLLC/voice-clone-flake.git
cd voice-clone-flake
nix develop  # Enter development shell
```

**Simple Example:**
```bash
# Create a test reference audio (6-10 seconds of speech)
# Then clone the voice:
demod-voice xtts-zero-shot reference.wav "Hello, this is a test of voice cloning." --output test.wav

# Or use Docker:
docker run -v $(pwd):/workspace \
  alh477/demod-voice:cpu \
  /bin/demod-voice xtts-zero-shot /workspace/reference.wav "Hello, this is a test of voice cloning." \
  --output /workspace/test.wav

# Listen to the result:
play test.wav  # or use any audio player
```

### Docker (Multi-Architecture)

Pre-built images available for **x86_64 (AMD64)** and **ARM64** architectures with **CUDA**, **ROCm**, and **CPU-only** variants.

#### Quick Start (Auto-Detect Architecture)

```bash
# Pull the best image for your architecture
# - AMD64: Gets CUDA variant (NVIDIA GPU support)
# - ARM64: Gets CPU variant (Apple Silicon, AWS Graviton)
docker pull alh477/demod-voice:latest

# Or use GitHub Container Registry
docker pull ghcr.io/alh477/demod-voice:latest
```

#### GPU-Accelerated (NVIDIA CUDA)

```bash
# Pull CUDA variant
docker pull alh477/demod-voice:cuda

# Run with NVIDIA GPU
docker run --gpus all -v $(pwd):/workspace \
  alh477/demod-voice:cuda \
  /bin/demod-voice xtts-zero-shot /workspace/reference.wav "Hello world" \
  --output /workspace/output.wav --gpu
```

#### GPU-Accelerated (AMD ROCm)

```bash
# Pull ROCm variant (AMD64 only)
docker pull alh477/demod-voice:rocm

# Run with AMD GPU
docker run --device /dev/kfd --device /dev/dri -v $(pwd):/workspace \
  alh477/demod-voice:rocm \
  /bin/demod-voice xtts-zero-shot /workspace/reference.wav "Hello world" \
  --output /workspace/output.wav --gpu
```

#### CPU-Only (Smallest Image)

```bash
# Pull CPU variant (70% smaller!)
docker pull alh477/demod-voice:cpu

# Run without GPU
docker run -v $(pwd):/workspace \
  alh477/demod-voice:cpu \
  /bin/demod-voice xtts-zero-shot /workspace/reference.wav "Hello world" \
  --output /workspace/output.wav
```

#### Available Image Tags

| Tag | Description | Size | Best For |
|-----|-------------|------|----------|
| `latest` | Auto-detects architecture | ~4GB AMD64<br>~1GB ARM64 | Most users |
| `cuda` | All CUDA variants | ~4GB | NVIDIA GPUs |
| `rocm` | All ROCm variants | ~3.5GB | AMD GPUs |
| `cpu` | All CPU variants | ~1.2GB | No GPU / Storage constrained |
| `latest-amd64` | CUDA on AMD64 | ~4GB | Intel/AMD + NVIDIA |
| `latest-arm64` | CPU on ARM64 | ~1GB | Apple Silicon, ARM servers |
| `1.0.0-cuda-amd64` | CUDA on AMD64 | ~4GB | NVIDIA on Intel/AMD |
| `1.0.0-cuda-arm64` | CUDA on ARM64 | ~3.5GB | NVIDIA on ARM (Jetson) |
| `1.0.0-rocm-amd64` | ROCm on AMD64 | ~3.5GB | AMD on Intel/AMD |
| `1.0.0-cpu-amd64` | CPU on AMD64 | ~1.2GB | No GPU on Intel/AMD |
| `1.0.0-cpu-arm64` | CPU on ARM64 | ~1GB | No GPU on ARM (Apple Silicon) |

**Specific Versions:**
- `1.0.0-cuda-amd64` - NVIDIA on Intel/AMD CPUs
- `1.0.0-cuda-arm64` - NVIDIA on ARM (Jetson)
- `1.0.0-rocm-amd64` - AMD on Intel/AMD CPUs
- `1.0.0-cpu-amd64` - No GPU on Intel/AMD
- `1.0.0-cpu-arm64` - No GPU on ARM (Apple Silicon, Graviton)

**Registries:**
- **DockerHub**: `alh477/demod-voice`
- **GitHub Container Registry**: `ghcr.io/alh477/demod-voice`

#### Which Image Should I Use?

**Decision Tree:**

1. **What CPU do you have?**
   - Intel or AMD → Use `-amd64` images
   - Apple Silicon (M1/M2/M3) → Use `-arm64` images
   - AWS/Azure ARM instances → Use `-arm64` images

2. **What GPU do you have?**
   - NVIDIA (RTX, Tesla, A100) → Use `cuda` tag
   - AMD (RX 6000/7000, MI series) → Use `rocm` tag
   - No GPU / Cloud VM → Use `cpu` tag
   - Not sure → Use `latest` (auto-detects best option)

3. **Storage constrained?**
   - Use `cpu` variant (70% smaller than CUDA)
   - Or use `latest` which is optimized per-architecture

**Examples:**

```bash
# Desktop with NVIDIA RTX
docker pull alh477/demod-voice:cuda

# MacBook Pro M3 (no GPU in Docker)
docker pull alh477/demod-voice:cpu

# AWS Graviton server
docker pull alh477/demod-voice:cpu

# Not sure - let Docker decide
docker pull alh477/demod-voice:latest  # Works on any platform
```

## Requirements

- **OS**: Linux (x86_64 or aarch64)
- **Nix**: 2.18+ with flakes enabled
- **GPU** (optional but recommended):
  - NVIDIA GPU with CUDA 11.8+
  - AMD GPU with ROCm 5.7+
  - 8GB+ VRAM for XTTS inference

## Usage

### Zero-Shot Voice Cloning

Clone any voice from a short reference sample:

```bash
demod-voice xtts-zero-shot \
  reference_audio.wav \
  "This is the text I want to synthesize in the cloned voice." \
  --output cloned_output.wav \
  --language en \
  --gpu
```

**Reference audio requirements:**
- Format: WAV, 22050 Hz mono (auto-converted if different)
- Duration: 6-10 seconds of clean speech
- Quality: No background noise, single speaker
- Content: Natural conversational speech works best

### Piper Inference

Fast synthesis with pre-trained or custom Piper models:

```bash
# Single-speaker model
demod-voice piper-infer \
  en_US-lessac-medium.onnx \
  "Fast and efficient text to speech." \
  --output piper_output.wav

# Multi-speaker model
demod-voice piper-infer \
  en_US-libritts-high.onnx \
  "Speaker-specific synthesis." \
  --output speaker_output.wav \
  --speaker 5
```

Download Piper models from: https://github.com/rhasspy/piper/releases

### Configuration

Create a config file at `~/.config/demod-voice/config.yaml` to set defaults:

```yaml
# Default language for XTTS synthesis
default_language: en

# GPU settings
gpu:
  enabled: true
  device_id: 0
  mixed_precision: true

# Output settings
output:
  sample_rate: 22050
  format: wav
```

Or use a custom config file:

```bash
demod-voice --config /path/to/config.yaml xtts-zero-shot reference.wav "Hello"
```

### Batch Processing

Process multiple voice cloning jobs from a CSV file:

```bash
# Create a batch file (columns: reference,text,output[,language,speaker])
cat > batch.csv << EOF
reference,text,output,language
/path/to/ref1.wav,"Hello world",/path/to/out1.wav,en
/path/to/ref2.wav,"Bonjour",/path/to/out2.wav,fr
EOF

# Process all jobs
demod-voice batch batch.csv

# Stop on first error
demod-voice batch batch.csv --fail-fast
```

### Training Custom Piper Models

Train your own custom voice models using the Piper training pipeline:

**Step 1: Prepare your dataset**
```bash
# Create dataset structure
mkdir -p my-voice/wavs
# Add your WAV files (16-22kHz, mono, 1-10 seconds each)
# Create metadata.csv with format: filename|text
# Example metadata.csv:
# file001|This is the first audio file
# file002|This is the second audio file
```

**Step 2: Preprocess the dataset**
```bash
# Preprocess using Docker
docker run -v $(pwd):/workspace \
  alh477/demod-voice:1.0.0-rocm-amd64 \
  /bin/demod-voice piper-preprocess \
  --input-dir /workspace/my-voice \
  --output-dir /workspace/training-ready \
  --language en-us
```

**Step 3: Install piper-train and train**
```bash
# Install piper-train on your host machine
pip install piper-train

# Train the model
python -m piper_train \
  --dataset-dir ./training-ready \
  --output-dir ./my-model \
  --quality medium \
  --language en-us
```

**Step 4: Convert to ONNX for inference**
```bash
# Convert to ONNX format
python -m piper_train.convert \
  --checkpoint ./my-model/latest_model.pth \
  --output ./my-voice.onnx \
  --speaker-dict ./my-model/speaker_dict.json
```

**Step 5: Test your custom model**
```bash
# Test the trained model
docker run -v $(pwd):/workspace \
  alh477/demod-voice:1.0.0-rocm-amd64 \
  /bin/demod-voice piper-infer \
  /workspace/my-voice.onnx \
  "Hello, this is my custom trained voice!" \
  --output /workspace/test-output.wav
```

### XTTS License Acceptance

The XTTS model requires license confirmation. To avoid interactive prompts:

```bash
# Create config to pre-accept license
mkdir -p ~/.config/demod-voice
cat > ~/.config/demod-voice/config.yaml << EOF
default_language: en
gpu:
  enabled: true
  device_id: 0
  mixed_precision: true
xtts:
  cache_dir: null
  temperature: 0.65
  length_penalty: 1.0
  repetition_penalty: 2.0
output:
  sample_rate: 22050
  format: wav
  quality: high
EOF
```

### Health Check

Verify system health and dependencies:

```bash
# Human-readable output
demod-voice health

# JSON output for automation
demod-voice health --json
```

### Logging Options

Control output verbosity:

```bash
# Verbose logging (debug level)
demod-voice --verbose xtts-zero-shot reference.wav "Hello"

# Quiet mode (errors only)
demod-voice --quiet xtts-zero-shot reference.wav "Hello"

# Force CPU mode
demod-voice --cpu xtts-zero-shot reference.wav "Hello"
```

### Dataset Preprocessing

Prepare custom datasets for Piper fine-tuning:

```bash
# Your dataset structure:
# dataset/
#   wavs/
#     file001.wav
#     file002.wav
#   metadata.csv  (format: filename|text)

demod-voice piper-preprocess \
  --input-dir ./dataset \
  --output-dir ./training_data \
  --language en-us
```

After preprocessing, train with:

```bash
python -m piper_train \
  --dataset-dir ./training_data \
  --output-dir ./checkpoints \
  --quality high
```

## Development

```bash
# Enter development environment
nix develop

# CLI is available directly
demod-voice --help

# Run tests
python -m pytest tests/

# Format code
black bin/
ruff check bin/

# Build package
nix build .#demod-voice
```

## Architecture

```
demod-voice
├── XTTS-v2 backend (Coqui TTS)
│   └── Zero-shot cloning, multi-lingual
├── Piper backend (rhasspy/piper)
│   └── Fast ONNX inference
├── tinygrad support (experimental)
│   └── Alternative compute backend
└── Nix packaging
    ├── Reproducible Python environment
    ├── CUDA/ROCm acceleration
    └── Docker containerization
```

## Performance Notes

**XTTS-v2 (GPU recommended):**
- First inference: ~30-60s (model download + compilation)
- Subsequent: ~2-5s for 10-20 words
- VRAM: 6-8 GB typical

**Piper (CPU-friendly):**
- Inference: Real-time or faster on modern CPUs
- VRAM: None required
- Quality: Excellent for production use

## Troubleshooting

### Build Issues: Dependency Conflicts

If you encounter dependency version conflicts during build:

1. **Ensure you're using the latest nixpkgs branch:**
   ```bash
   nix flake update
   ```

2. **Check the overrides in flake.nix:**
   - pandas is pinned to 1.5.3 (for Coqui TTS compatibility)
   - gruut is pinned to 2.2.3
   - Package names are corrected (e.g., `trainer` → `coqui-tts-trainer`)

3. **Verify language packages are included:**
   - All language support packages are in the `propagatedBuildInputs` list
   - Korean support includes `hangul-romanize`, `g2pkk`, `jamo`
   - Bengali support includes `bnnumerizer`, `bnunicodenormalizer`

### CUDA not detected

```bash
# Check CUDA availability
python -c "import torch; print(torch.cuda.is_available())"

# Inside Nix shell, ensure LD_LIBRARY_PATH is set
echo $LD_LIBRARY_PATH
```

### Model download issues

XTTS models auto-download on first run. If downloads fail:

```bash
# Pre-download models
python -c "from TTS.api import TTS; TTS('tts_models/multilingual/multi-dataset/xtts_v2')"
```

### Out of memory

Reduce batch size or use CPU mode:

```bash
# Remove --gpu flag to use CPU (slower but uses less VRAM)
demod-voice xtts-zero-shot reference.wav "text" --output out.wav
```

## Roadmap

- [ ] Multi-speaker fine-tuning workflows
- [ ] Real-time streaming synthesis
- [ ] Voice conversion (speaker A to speaker B)
- [ ] Web API server mode
- [ ] Gradio/Streamlit UI
- [ ] Model quantization for edge deployment

## Contributing

Contributions welcome. Please:

1. Fork the repository
2. Create a feature branch
3. Test with `nix flake check`
4. Submit a pull request

For major changes, open an issue first to discuss.

## License

MIT License - see [LICENSE](LICENSE) file.

Copyright (c) 2026 DeMoD LLC

## Acknowledgments

Built on the shoulders of giants:

- [Coqui TTS](https://github.com/coqui-ai/TTS) - XTTS-v2 implementation
- [Piper](https://github.com/rhasspy/piper) - Fast neural TTS
- [tinygrad](https://github.com/tinygrad/tinygrad) - Lightweight ML framework
- [Nix](https://nixos.org) - Reproducible package management

## Support

- Issues: https://github.com/ALH477/demod-voice/issues
- Discussions: https://github.com/ALH477/demod-voice/discussions
- Email: alh477@proton.me

---

**DeMoD LTD** - Digital Signal Processing and AI Infrastructure
