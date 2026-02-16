# Performance Optimization Guide

This guide provides recommendations for optimizing DeMoD Voice Clone performance across different hardware configurations and use cases.

## Hardware Recommendations

### XTTS-v2 Performance

**Minimum Requirements:**
- GPU: NVIDIA GTX 1060 (6GB VRAM) or equivalent
- CPU: 4+ cores
- RAM: 16GB
- Storage: SSD recommended

**Recommended Configuration:**
- GPU: NVIDIA RTX 3080+ (10GB+ VRAM)
- CPU: 8+ cores
- RAM: 32GB
- Storage: NVMe SSD

**High-Performance Setup:**
- GPU: NVIDIA RTX 4090 or A100 (24GB+ VRAM)
- CPU: 16+ cores
- RAM: 64GB+
- Storage: NVMe SSD with 1TB+

### Piper Performance

**Minimum Requirements:**
- CPU: 2+ cores
- RAM: 8GB
- Storage: Any (models ~200MB each)

**Recommended Configuration:**
- CPU: 4+ cores
- RAM: 16GB
- Storage: SSD for faster model loading

**Note:** Piper runs entirely on CPU and does not require a GPU.

## Performance Comparison

| Backend | Speed | Quality | Hardware | Use Case |
|---------|-------|---------|----------|----------|
| XTTS-v2 | 2-5s per sentence | High | GPU required | Voice cloning, high quality |
| Piper | <100ms per phrase | High | CPU only | Production TTS, real-time |
| XTTS (CPU) | 30-60s per sentence | High | CPU only | Development, testing |

## Optimization Strategies

### XTTS-v2 Optimization

#### GPU Configuration
```bash
# Enable mixed precision for faster inference
export CUDA_LAUNCH_BLOCKING=0
export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:128

# Use specific GPU if multiple available
export CUDA_VISIBLE_DEVICES=0
```

#### Memory Management
```python
# Clear CUDA cache between operations
import torch
torch.cuda.empty_cache()
```

#### Model Optimization
- Use FP16 precision when supported
- Pre-load models to avoid repeated loading
- Use smaller batch sizes for memory-constrained systems

### Piper Optimization

#### CPU Configuration
```bash
# Set thread count for optimal performance
export OMP_NUM_THREADS=4
export MKL_NUM_THREADS=4

# Use high-performance CPU governor
sudo cpufreq-set -g performance
```

#### Model Selection
- Choose appropriate model size for your use case
- Use single-speaker models when multi-speaker not needed
- Consider model compression for edge deployment

### General Optimization

#### Storage Optimization
```bash
# Use SSD for model storage
# Set TTS_HOME to SSD location
export TTS_HOME=/fast/ssd/.local/share/tts
```

#### Network Optimization
```bash
# Use local model cache
# Pre-download models to avoid network delays
python -c "from TTS.api import TTS; TTS('tts_models/multilingual/multi-dataset/xtts_v2')"
```

## Use Case Optimization

### Development Environment
```bash
# Use CPU mode for development
demod-voice --cpu xtts-zero-shot ref.wav "text" --output dev.wav

# Enable verbose logging for debugging
demod-voice --verbose xtts-zero-shot ref.wav "text" --output debug.wav
```

### Production Deployment
```bash
# Use GPU acceleration
demod-voice --gpu xtts-zero-shot ref.wav "text" --output prod.wav

# Use Piper for high-throughput scenarios
demod-voice piper-infer model.onnx "text" --output fast.wav
```

### Batch Processing
```bash
# Optimize for batch processing
demod-voice batch jobs.csv --fail-fast

# Use progress indicators for long jobs
demod-voice batch jobs.csv --verbose
```

## Memory Management

### XTTS Memory Usage
- **Model weights:** ~1.8GB
- **CUDA memory:** 6-8GB typical
- **Cache:** ~500MB for audio processing

### Memory Optimization
```python
# Monitor memory usage
import torch
print(f"GPU Memory: {torch.cuda.memory_allocated() / 1e9:.2f} GB")

# Clear memory between operations
torch.cuda.empty_cache()
```

### Batch Processing Memory
- Process jobs sequentially to manage memory
- Use `--fail-fast` to stop on errors
- Monitor system memory during long runs

## Network and Storage

### Model Downloads
```bash
# Pre-download models to avoid delays
python -c "from TTS.api import TTS; TTS('tts_models/multilingual/multi-dataset/xtts_v2')"

# Use local cache
export TTS_HOME=/path/to/local/cache
```

### Storage Optimization
- Use fast storage for model files
- Keep frequently used models on SSD
- Consider model compression for edge deployment

## Monitoring and Profiling

### Performance Monitoring
```bash
# Monitor GPU usage
nvidia-smi

# Monitor CPU usage
htop

# Monitor memory usage
free -h
```

### Timing Operations
```bash
# Time XTTS operations
time demod-voice xtts-zero-shot ref.wav "text" --output out.wav

# Time Piper operations
time demod-voice piper-infer model.onnx "text" --output out.wav
```

### Profiling
```python
import time

start = time.time()
# Your operation here
end = time.time()
print(f"Operation took {end - start:.2f} seconds")
```

## Troubleshooting Performance Issues

### Slow XTTS Performance
1. **Check GPU availability:**
   ```bash
   python -c "import torch; print(torch.cuda.is_available())"
   ```

2. **Verify CUDA installation:**
   ```bash
   nvidia-smi
   ```

3. **Check memory usage:**
   ```bash
   nvidia-smi --query-gpu=memory.used,memory.total --format=csv
   ```

### Slow Piper Performance
1. **Check CPU usage:**
   ```bash
   htop
   ```

2. **Verify model loading:**
   ```bash
   time demod-voice piper-infer model.onnx "test" --output test.wav
   ```

3. **Check thread configuration:**
   ```bash
   echo $OMP_NUM_THREADS
   ```

### Memory Issues
1. **Monitor memory usage:**
   ```bash
   free -h
   ```

2. **Clear caches:**
   ```bash
   sudo sync && sudo sysctl -w vm.drop_caches=3
   ```

3. **Reduce batch sizes:**
   ```bash
   demod-voice batch jobs.csv --fail-fast
   ```

## Best Practices

### Development
- Use CPU mode for development to avoid GPU conflicts
- Enable verbose logging for debugging
- Use small test files for rapid iteration

### Production
- Use GPU acceleration for XTTS
- Use Piper for high-throughput scenarios
- Monitor system resources
- Implement proper error handling

### Deployment
- Pre-download models to avoid network delays
- Use appropriate hardware for your use case
- Implement monitoring and alerting
- Plan for scaling based on usage patterns

## Performance Benchmarks

### XTTS-v2 Benchmarks
- **First inference:** 30-60s (model download + compilation)
- **Subsequent inference:** 2-5s for 10-20 words
- **Memory usage:** 6-8GB VRAM

### Piper Benchmarks
- **Inference time:** <100ms for short phrases
- **Memory usage:** ~200MB per model
- **CPU usage:** 100% of one core during inference

### Batch Processing Benchmarks
- **Sequential processing:** Linear scaling with job count
- **Memory usage:** Constant (jobs processed one at a time)
- **Error handling:** Configurable fail-fast vs continue-on-error

## Scaling Considerations

### Horizontal Scaling
- Run multiple instances for parallel processing
- Use load balancing for web services
- Implement job queues for batch processing

### Vertical Scaling
- Upgrade GPU for XTTS performance
- Add CPU cores for Piper performance
- Increase RAM for larger models
- Use faster storage for model loading

### Cloud Deployment
- Use GPU instances for XTTS workloads
- Use CPU-optimized instances for Piper
- Implement auto-scaling based on queue depth
- Use managed storage for model distribution