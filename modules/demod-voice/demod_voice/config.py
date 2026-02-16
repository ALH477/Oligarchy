"""
Configuration management for DeMoD Voice Clone
Handles loading and validation of config files
"""

import os
import sys
from pathlib import Path
from typing import Any, Dict, Optional


def get_config_dir() -> Path:
    """Get the configuration directory path."""
    if os.name == 'nt':  # Windows
        config_dir = Path(os.environ.get('APPDATA', '')) / 'demod-voice'
    else:
        config_dir = Path.home() / '.config' / 'demod-voice'
    return config_dir


def get_default_config() -> Dict[str, Any]:
    """Return default configuration values."""
    return {
        'default_language': 'en',
        'gpu': {
            'enabled': True,
            'device_id': 0,
            'mixed_precision': True,
        },
        'xtts': {
            'cache_dir': None,
            'temperature': 0.65,
            'length_penalty': 1.0,
            'repetition_penalty': 2.0,
        },
        'piper': {
            'default_speaker': None,
            'speed': 1.0,
            'noise_scale': 0.667,
            'noise_scale_w': 0.8,
        },
        'output': {
            'sample_rate': 22050,
            'format': 'wav',
            'quality': 'high',
        },
        'preprocessing': {
            'target_sample_rate': 22050,
            'normalize_db': -20,
            'trim_silence': True,
            'min_duration': 1.0,
            'max_duration': 15.0,
        },
        'advanced': {
            'num_threads': None,
            'verbose': False,
            'temp_dir': '/tmp/demod-voice',
        },
    }


def load_config(config_path: Optional[Path] = None) -> Dict[str, Any]:
    """
    Load configuration from file or return defaults.
    
    Args:
        config_path: Optional path to config file. If None, uses default location.
    
    Returns:
        Dict containing merged configuration (defaults + user config)
    """
    config = get_default_config()
    
    if config_path is None:
        config_path = get_config_dir() / 'config.yaml'
    
    if config_path.exists():
        try:
            import yaml
            with open(config_path, 'r') as f:
                user_config = yaml.safe_load(f)
            
            if user_config:
                # Merge user config with defaults
                _deep_merge(config, user_config)
        except ImportError:
            print("WARNING: PyYAML not installed, using default config", file=sys.stderr)
        except Exception as e:
            print(f"WARNING: Failed to load config from {config_path}: {e}", file=sys.stderr)
    
    return config


def _deep_merge(base: Dict[str, Any], override: Dict[str, Any]) -> None:
    """Deep merge override dict into base dict."""
    for key, value in override.items():
        if key in base and isinstance(base[key], dict) and isinstance(value, dict):
            _deep_merge(base[key], value)
        else:
            base[key] = value


def validate_config(config: Dict[str, Any]) -> list:
    """
    Validate configuration values.
    
    Returns:
        List of validation error messages (empty if valid)
    """
    errors = []
    
    # Validate GPU settings
    if not isinstance(config.get('gpu', {}).get('enabled'), bool):
        errors.append("gpu.enabled must be a boolean")
    
    device_id = config.get('gpu', {}).get('device_id')
    if device_id is not None and not isinstance(device_id, int):
        errors.append("gpu.device_id must be an integer")
    
    # Validate XTTS settings
    temp = config.get('xtts', {}).get('temperature')
    if temp is not None and not (0.0 <= temp <= 1.0):
        errors.append("xtts.temperature must be between 0.0 and 1.0")
    
    # Validate output settings
    fmt = config.get('output', {}).get('format')
    if fmt and fmt not in ['wav', 'mp3', 'flac', 'ogg']:
        errors.append("output.format must be one of: wav, mp3, flac, ogg")
    
    return errors


def save_config(config: Dict[str, Any], config_path: Optional[Path] = None) -> None:
    """
    Save configuration to file.
    
    Args:
        config: Configuration dict to save
        config_path: Optional path to save to. If None, uses default location.
    """
    if config_path is None:
        config_path = get_config_dir() / 'config.yaml'
    
    config_path.parent.mkdir(parents=True, exist_ok=True)
    
    try:
        import yaml
        with open(config_path, 'w') as f:
            yaml.dump(config, f, default_flow_style=False, sort_keys=False)
    except ImportError:
        raise RuntimeError("PyYAML required to save config")
