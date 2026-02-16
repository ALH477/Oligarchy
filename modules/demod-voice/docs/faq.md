# Frequently Asked Questions

This document answers common questions about DeMoD Voice Clone.

## General Questions

### What is DeMoD Voice Clone?

DeMoD Voice Clone is a production-grade local voice cloning and text-to-speech system built with Nix for reproducibility. It provides zero-shot voice cloning via Coqui XTTS-v2 and fast Piper TTS inference with multi-language support.

### Is DeMoD Voice Clone free?

Yes, DeMoD Voice Clone is completely free and open source under the MIT License. All dependencies are also MIT-compatible.

### What languages are supported?

DeMoD Voice Clone supports 17+ languages including:
- English (with DE/ES/FR variants)
- Chinese (Simplified)
- Japanese
- Korean
- Bengali
- And many more via num2words integration

### Do I need a GPU?

A GPU is recommended for XTTS-v2 voice cloning but not required. Piper TTS runs entirely on CPU. The system automatically falls back to CPU mode when GPU is unavailable.

### How much does it cost to run?

The software itself is free. Hardware costs depend on your setup:
- **CPU-only**: Any modern computer (~$0 additional cost)
- **GPU-accelerated**: NVIDIA GPU with 6GB+ VRAM (~$200+ for capable GPU)

## Technical Questions

### What are the system requirements?

**Minimum:**
- Linux (x86_64 or aarch64)
- 8GB RAM
- 2+ CPU cores
- 5GB storage

**Recommended:**
- NVIDIA GPU with 8GB+ VRAM
- 16GB+ RAM
- 4+ CPU cores
- SSD storage

### How much storage do I need?

- **Base installation**: ~2GB
- **XTTS models**: ~1.8GB download (cached)
- **Piper models**: ~200MB each
- **Total**: 5-10GB depending on models used

### Can I run this on Windows or macOS?

- **Linux**: Fully supported
- **macOS**: Supported via CPU mode (Apple Silicon)
- **Windows**: Supported via WSL2 (Windows Subsystem for Linux)

### How do I install Nix?

```bash
# Install Nix
sh <(curl -L https://nixos.org/nix/install) --daemon

# Enable flakes
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# Restart your shell or source the profile
source ~/.nix-profile/etc/profile.d/nix.sh
```

### Can I use this without Nix?

While possible, Nix is strongly recommended for:
- Reproducible builds
- Dependency management
- Isolated environments
- Easy updates

## Usage Questions

### How do I create a reference audio file?

**Requirements:**
- Format: WAV, 22050 Hz, mono
- Duration: 6-10 seconds
- Quality: Clean speech, no background noise
- Content: Natural conversational speech

**Tips:**
- Record in a quiet environment
- Use a good quality microphone
- Speak naturally, not too fast or slow
- Avoid music, echo, or background sounds

### How long does voice cloning take?

- **First time**: 30-60 seconds (model download + compilation)
- **Subsequent**: 2-5 seconds for 10-20 words
- **Piper**: <100ms for short phrases

### Can I clone voices from music or videos?

Yes, but you'll need to:
1. Extract the audio
2. Remove background music/noise
3. Isolate clean speech segments
4. Convert to WAV format

Tools like Audacity or ffmpeg can help with audio extraction and cleaning.

### How accurate is the voice cloning?

Accuracy depends on:
- **Reference audio quality**: Clean, clear speech works best
- **Audio duration**: 6-10 seconds of speech recommended
- **Content match**: Similar speaking style improves results
- **Language**: Some languages have better support than others

### Can I use multiple speakers?

- **XTTS-v2**: Single speaker per reference audio
- **Piper**: Multi-speaker models supported (use `--speaker` parameter)

### How do I batch process multiple files?

Create a CSV file:
```csv
reference,text,output,language,speaker
/path/to/ref1.wav,"Hello world",/path/to/out1.wav,en,0
/path/to/ref2.wav,"Bonjour",/path/to/out2.wav,fr,1
```

Then run:
```bash
demod-voice batch batch.csv
```

## Performance Questions

### Why is it so slow?

Common causes:
1. **Using CPU instead of GPU**: Check with `demod-voice health`
2. **First-time model download**: Subsequent runs are faster
3. **Insufficient memory**: Check system resources
4. **Poor internet**: Model downloads may be slow

### How can I speed it up?

1. **Use GPU acceleration**: `demod-voice --gpu command`
2. **Pre-download models**: `python -c "from TTS.api import TTS; TTS('tts_models/multilingual/multi-dataset/xtts_v2')"`
3. **Use Piper for production**: CPU-friendly, faster inference
4. **Optimize hardware**: More RAM, faster storage, better GPU

### Can I run multiple instances?

Yes, but consider:
- **GPU memory**: Each instance needs VRAM
- **CPU cores**: Each instance uses CPU resources
- **Storage I/O**: Multiple instances may compete for disk access

### How much VRAM do I need?

- **Minimum**: 6GB for basic XTTS inference
- **Recommended**: 8GB+ for better performance
- **High-end**: 12GB+ for large models and batch processing

## Development Questions

### How do I contribute?

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with `nix flake check`
5. Submit a pull request

See [CONTRIBUTING.md](../CONTRIBUTING.md) for details.

### How do I add a new language?

1. Add language packages to `flake.nix`
2. Test with Coqui TTS language support
3. Update documentation
4. Submit pull request

### Can I train custom models?

Yes, use the `piper-preprocess` command to prepare datasets, then train with:
```bash
python -m piper_train \
  --dataset-dir ./training_data \
  --output-dir ./checkpoints \
  --quality high
```

### How do I debug issues?

1. **Enable verbose logging**: `demod-voice --verbose command`
2. **Check health**: `demod-voice health --json`
3. **Use CPU mode**: `demod-voice --cpu command`
4. **Check logs**: Look for error messages in output

## Deployment Questions

### Can I deploy this in production?

Yes! DeMoD Voice Clone is designed for production use with:
- Docker containerization
- Multi-architecture support
- Reproducible builds
- Comprehensive testing

### How do I scale for high traffic?

1. **Horizontal scaling**: Run multiple instances
2. **Load balancing**: Distribute requests across instances
3. **Caching**: Cache frequently used voices/models
4. **Queue systems**: Use job queues for batch processing

### What about licensing for commercial use?

All components are MIT-licensed and free for commercial use. However:
- Check model licenses if using custom models
- Respect voice rights and privacy laws
- Consider ethical implications of voice cloning

### Can I use this with cloud services?

Yes, DeMoD Voice Clone works well with:
- **AWS**: EC2 GPU instances, S3 for storage
- **Google Cloud**: Compute Engine, Cloud Storage
- **Azure**: Virtual Machines, Blob Storage
- **Docker**: Container registries, orchestration

## Troubleshooting Questions

### I get "CUDA not available" error

Solutions:
1. **Check NVIDIA drivers**: `nvidia-smi`
2. **Verify CUDA installation**: `python -c "import torch; print(torch.cuda.is_available())"`
3. **Use CPU mode**: `demod-voice --cpu command`
4. **Check Nix environment**: `nix develop`

### Model download keeps failing

Solutions:
1. **Check internet connection**
2. **Use proxy if needed**: `export http_proxy=...`
3. **Pre-download manually**: `python -c "from TTS.api import TTS; TTS('tts_models/multilingual/multi-dataset/xtts_v2')"`
4. **Check TTS_HOME**: `echo $TTS_HOME`

### Audio quality is poor

Check:
1. **Reference audio quality**: Clean, clear speech needed
2. **Sample rate**: Should be 22050 Hz
3. **Audio format**: WAV, mono channel
4. **Background noise**: Remove noise from reference

### Docker container won't start

Solutions:
1. **Check Docker installation**: `docker --version`
2. **Verify image**: `docker images`
3. **Check permissions**: `docker run --user $(id -u):$(id -g) ...`
4. **GPU support**: `docker run --gpus all ...` (if needed)

## Security and Privacy

### Is my data secure?

Yes, DeMoD Voice Clone:
- Runs locally (no cloud dependencies)
- Doesn't send data to external services
- Uses local model storage
- Respects user privacy

### Can someone misuse this for deepfakes?

While technically possible, DeMoD Voice Clone:
- Is intended for legitimate use cases
- Encourages ethical usage
- Users are responsible for their applications
- Follows industry best practices

### How do I secure my deployment?

1. **Use authentication**: Protect API endpoints
2. **Limit access**: Restrict to authorized users
3. **Monitor usage**: Track API calls and resource usage
4. **Update regularly**: Keep dependencies up to date

## Getting Help

### Where can I get support?

- **GitHub Issues**: https://github.com/ALH477/demod-voice/issues
- **Discussions**: https://github.com/ALH477/demod-voice/discussions
- **Email**: alh477@proton.me

### What information should I include when reporting issues?

- Nix version: `nix --version`
- System info: `uname -a`
- Error messages (full output)
- Steps to reproduce
- Debug output: `demod-voice health --json`

### How do I stay updated?

- Watch the GitHub repository
- Follow release announcements
- Check the changelog
- Join discussions for updates

## Advanced Questions

### Can I integrate this with other applications?

Yes, DeMoD Voice Clone provides:
- CLI interface for scripting
- JSON output for automation
- Docker containers for deployment
- Python modules for integration

### How do I customize the voice output?

Options include:
- **Language selection**: `--language en`
- **Speaker selection**: `--speaker 5` (for multi-speaker models)
- **Output format**: WAV format supported
- **Sample rate**: Configurable via settings

### Can I fine-tune models for specific voices?

Yes, use the `piper-preprocess` command to prepare datasets, then train custom models with the Piper training pipeline.

### What's the difference between XTTS and Piper?

| Feature | XTTS-v2 | Piper |
|---------|---------|-------|
| Speed | 2-5s per sentence | <100ms per phrase |
| Quality | High | High |
| Hardware | GPU recommended | CPU only |
| Use Case | Voice cloning | Production TTS |
| Training | Zero-shot | Requires training |