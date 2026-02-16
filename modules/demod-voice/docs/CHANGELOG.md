# Changelog

All notable changes to DeMoD Voice Clone will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Configuration system with YAML support (`~/.config/demod-voice/config.yaml`)
- Structured logging with `--verbose` and `--quiet` flags
- GPU validation with automatic fallback to CPU
- Batch processing mode for CSV-based job queues
- Health check subcommand for system diagnostics
- Progress indicators for batch operations (tqdm)
- New `--cpu` flag to force CPU mode
- New `--config` flag for custom config paths
- Comprehensive test suite for config and batch modules

### Fixed
- Coqui TTS 0.22.0 dependency resolution:
  - Override pandas to version 1.5.3 (was 2.3.3, incompatible)
  - Pin gruut to version 2.2.3 (was 2.4.0, incompatible)
  - Build hangul-romanize from PyPI (not in nixpkgs)
  - Correct package names: `trainer` → `coqui-tts-trainer`, `coqpit` → `coqpit-config`
- Added missing dependencies for full language support:
  - Korean: g2pkk, hangul-romanize
  - Bengali: bnnumerizer, bnunicodenormalizer
  - General: num2words, scikit-learn, encodec

### Improved
- Better error handling with descriptive messages
- GPU availability checking before attempting CUDA operations
- Configurable device selection for multi-GPU systems
- Validation of configuration values on startup
- Modular architecture with separate config and batch modules

### Planned
- Streaming synthesis API
- Voice conversion (speaker transfer)
- Gradio web interface
- Model quantization support

## [1.0.1] - 2026-02-02

### Added
- Configuration system with YAML support (`~/.config/demod-voice/config.yaml`)
- Structured logging with `--verbose` and `--quiet` flags
- GPU validation with automatic fallback to CPU
- Batch processing mode for CSV-based job queues
- Health check subcommand for system diagnostics
- Progress indicators for batch operations (tqdm)
- New `--cpu` flag to force CPU mode
- New `--config` flag for custom config paths
- Comprehensive test suite for config and batch modules

### Fixed
- Coqui TTS 0.22.0 dependency resolution:
  - Override pandas to version 1.5.3 (was 2.3.3, incompatible)
  - Pin gruut to version 2.2.3 (was 2.4.0, incompatible)
  - Build hangul-romanize from PyPI (not in nixpkgs)
  - Correct package names: `trainer` → `coqui-tts-trainer`, `coqpit` → `coqpit-config`
- Added missing dependencies for full language support:
  - Korean: g2pkk, hangul-romanize
  - Bengali: bnnumerizer, bnunicodenormalizer
  - General: num2words, scikit-learn, encodec

### Improved
- Better error handling with descriptive messages
- GPU availability checking before attempting CUDA operations
- Configurable device selection for multi-GPU systems
- Validation of configuration values on startup
- Modular architecture with separate config and batch modules

### Planned
- Streaming synthesis API
- Voice conversion (speaker transfer)
- Gradio web interface
- Model quantization support

## [1.0.0] - 2026-01-31

### Added
- Initial release of DeMoD Voice Clone
- XTTS-v2 zero-shot voice cloning support
- Piper TTS inference support
- Dataset preprocessing for Piper fine-tuning
- Unified CLI interface with subcommands
- Nix flake for reproducible builds
- Docker containerization support
- GPU acceleration (CUDA/ROCm)
- Comprehensive documentation (README, ARCHITECTURE, CONTRIBUTING)
- GitHub Actions CI/CD pipeline
- MIT License

### Features
- `demod-voice xtts-zero-shot` - Zero-shot cloning from reference audio
- `demod-voice piper-infer` - Fast Piper model inference
- `demod-voice piper-preprocess` - Dataset preparation helper
- GPU/CPU automatic fallback
- Multi-language support (XTTS)
- Multi-speaker model support (Piper)

### Technical
- Python 3.11+ runtime
- PyTorch 2.1+ with CUDA support
- ONNX Runtime for Piper
- Reproducible Nix packaging
- Comprehensive test suite
- Type hints and linting

[Unreleased]: https://github.com/DeMoDLLC/voice-clone-flake/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/DeMoDLLC/voice-clone-flake/releases/tag/v1.0.0
