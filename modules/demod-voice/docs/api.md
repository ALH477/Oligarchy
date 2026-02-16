# API Reference

This document provides detailed information about the Python modules and functions in DeMoD Voice Clone.

## Configuration Module (`demod_voice.config`)

The configuration module provides YAML-based configuration management with validation and defaults.

### Functions

#### `load_config(config_path: Optional[Path] = None) -> Dict[str, Any]`

Load configuration from file or return defaults.

**Parameters:**
- `config_path` (Optional[Path]): Path to custom config file. If None, loads from `~/.config/demod-voice/config.yaml`

**Returns:**
- `Dict[str, Any]`: Configuration dictionary

**Example:**
```python
from demod_voice.config import load_config

config = load_config()
print(config['default_language'])  # 'en'
```

#### `validate_config(config: Dict[str, Any]) -> List[str]`

Validate configuration structure and return list of errors.

**Parameters:**
- `config` (Dict[str, Any]): Configuration dictionary to validate

**Returns:**
- `List[str]`: List of validation error messages (empty if valid)

**Example:**
```python
from demod_voice.config import load_config, validate_config

config = load_config()
errors = validate_config(config)
if errors:
    for error in errors:
        print(f"Config error: {error}")
```

#### `get_default_config() -> Dict[str, Any]`

Get the default configuration dictionary.

**Returns:**
- `Dict[str, Any]`: Default configuration

**Example:**
```python
from demod_voice.config import get_default_config

defaults = get_default_config()
print(defaults['gpu']['enabled'])  # True
```

### Configuration Structure

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

# Piper settings
piper:
  default_speaker: 0

# Preprocessing settings
preprocessing:
  target_sample_rate: 22050
```

## Batch Processing Module (`demod_voice.batch`)

The batch processing module provides CSV-based job specification and validation for processing multiple voice cloning jobs.

### Classes

#### `BatchJob`

Data class representing a single batch job.

**Attributes:**
- `reference` (Path): Path to reference audio file
- `text` (str): Text to synthesize
- `output` (Path): Output file path
- `language` (Optional[str]): Language code (defaults to 'en')
- `speaker` (Optional[int]): Speaker ID for multi-speaker models

### Functions

#### `load_batch_csv(csv_path: Path) -> List[BatchJob]`

Load batch jobs from CSV file.

**Parameters:**
- `csv_path` (Path): Path to CSV file

**Returns:**
- `List[BatchJob]`: List of batch job specifications

**CSV Format:**
```csv
reference,text,output,language,speaker
/path/to/ref1.wav,"Hello world",/path/to/out1.wav,en,0
/path/to/ref2.wav,"Bonjour",/path/to/out2.wav,fr,1
```

**Example:**
```python
from demod_voice.batch import load_batch_csv

jobs = load_batch_csv(Path("batch.csv"))
for job in jobs:
    print(f"Processing: {job.text}")
```

#### `validate_batch_jobs(jobs: List[BatchJob]) -> Tuple[List[BatchJob], List[str]]`

Validate batch job specifications and return valid jobs and errors.

**Parameters:**
- `jobs` (List[BatchJob]): List of batch jobs to validate

**Returns:**
- `Tuple[List[BatchJob], List[str]]`: Valid jobs and error messages

**Example:**
```python
from demod_voice.batch import load_batch_csv, validate_batch_jobs

jobs = load_batch_csv(Path("batch.csv"))
valid_jobs, errors = validate_batch_jobs(jobs)

if errors:
    for error in errors:
        print(f"Validation error: {error}")

print(f"Valid jobs: {len(valid_jobs)}")
```

## CLI Module (`bin/demod-voice`)

The main CLI module provides the command-line interface and subcommand implementations.

### Subcommands

#### `xtts-zero-shot`

Zero-shot voice cloning using XTTS-v2.

**Usage:**
```bash
demod-voice xtts-zero-shot reference.wav "text to synthesize" --output output.wav
```

#### `piper-infer`

Piper model inference for text-to-speech.

**Usage:**
```bash
demod-voice piper-infer model.onnx "text to speak" --output output.wav
```

#### `piper-preprocess`

Preprocess dataset for Piper fine-tuning.

**Usage:**
```bash
demod-voice piper-preprocess --input-dir dataset/ --output-dir training_data/ --language en-us
```

#### `batch`

Process multiple jobs from CSV file.

**Usage:**
```bash
demod-voice batch batch.csv --fail-fast
```

#### `health`

System health check and dependency validation.

**Usage:**
```bash
demod-voice health --json
```

### Configuration Integration

All subcommands support configuration via:
- Default values (built-in)
- User config file (`~/.config/demod-voice/config.yaml`)
- CLI flags (highest priority)

### Error Handling

The CLI provides comprehensive error handling:
- Input validation before processing
- Graceful fallbacks (e.g., CPU when GPU unavailable)
- Detailed error messages
- Structured logging

### Logging

The CLI supports different logging levels:
- `--verbose` / `-v`: Debug-level logging
- `--quiet` / `-q`: Error-only output
- Default: Info-level logging

## Backend Modules

### XTTS-v2 Backend

**Location:** Integrated via Coqui TTS library

**Key Features:**
- Zero-shot voice cloning from 6-10s reference
- Multi-lingual synthesis (17+ languages)
- GPU acceleration support
- Streaming generation

**Dependencies:**
- PyTorch with CUDA support
- Coqui TTS library
- Language-specific packages (gruut, jieba, etc.)

### Piper Backend

**Location:** External binary with Python wrapper

**Key Features:**
- Fast CPU inference
- ONNX model support
- Multi-speaker models
- Deterministic output

**Dependencies:**
- Piper binary
- ONNX Runtime
- Model files (.onnx + .json)

## Error Codes

The CLI uses standard exit codes:
- `0`: Success
- `1`: General error
- `130`: Interrupted by user (Ctrl+C)
- Other codes: Specific error types

## Environment Variables

The system respects several environment variables:
- `CUDA_VISIBLE_DEVICES`: GPU device selection
- `NVIDIA_VISIBLE_DEVICES`: Docker GPU access
- `PYTHONPATH`: Python module search path
- `HOME`: Model cache location