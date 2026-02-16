"""
Tests for DeMoD Voice Clone configuration module
"""

import pytest
from pathlib import Path
import tempfile
import yaml
import sys

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from demod_voice.config import (
    get_default_config,
    load_config,
    validate_config,
    save_config,
    _deep_merge
)


def test_default_config_structure():
    """Test that default config has expected structure"""
    config = get_default_config()
    
    assert 'default_language' in config
    assert 'gpu' in config
    assert 'xtts' in config
    assert 'piper' in config
    assert 'output' in config
    assert 'preprocessing' in config
    assert 'advanced' in config


def test_default_config_values():
    """Test that default config values are reasonable"""
    config = get_default_config()
    
    assert config['default_language'] == 'en'
    assert config['gpu']['enabled'] is True
    assert config['gpu']['device_id'] == 0
    assert config['output']['format'] == 'wav'
    assert config['output']['sample_rate'] == 22050


def test_load_config_nonexistent():
    """Test loading config from non-existent file returns defaults"""
    config = load_config(Path("/nonexistent/config.yaml"))
    default = get_default_config()
    assert config == default


def test_load_config_with_yaml():
    """Test loading config from valid YAML file"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
        yaml.dump({'default_language': 'fr', 'gpu': {'enabled': False}}, f)
        temp_path = Path(f.name)
    
    try:
        config = load_config(temp_path)
        assert config['default_language'] == 'fr'
        assert config['gpu']['enabled'] is False
        # Other values should still be defaults
        assert config['output']['format'] == 'wav'
    finally:
        temp_path.unlink()


def test_deep_merge():
    """Test deep merging of nested dictionaries"""
    base = {'a': 1, 'b': {'c': 2, 'd': 3}}
    override = {'b': {'c': 99}}
    
    _deep_merge(base, override)
    
    assert base['a'] == 1
    assert base['b']['c'] == 99
    assert base['b']['d'] == 3


def test_validate_config_valid():
    """Test validation of valid config"""
    config = get_default_config()
    errors = validate_config(config)
    assert len(errors) == 0


def test_validate_config_invalid_gpu():
    """Test validation catches invalid GPU settings"""
    config = get_default_config()
    config['gpu']['enabled'] = "not_a_boolean"
    
    errors = validate_config(config)
    assert len(errors) > 0
    assert any('gpu.enabled' in e for e in errors)


def test_validate_config_invalid_temperature():
    """Test validation catches invalid temperature"""
    config = get_default_config()
    config['xtts']['temperature'] = 2.0
    
    errors = validate_config(config)
    assert len(errors) > 0
    assert any('temperature' in e for e in errors)


def test_validate_config_invalid_format():
    """Test validation catches invalid output format"""
    config = get_default_config()
    config['output']['format'] = 'invalid'
    
    errors = validate_config(config)
    assert len(errors) > 0
    assert any('format' in e for e in errors)


def test_save_and_load_config():
    """Test saving and loading config preserves values"""
    with tempfile.TemporaryDirectory() as tmpdir:
        config_path = Path(tmpdir) / "test_config.yaml"
        
        original = get_default_config()
        original['default_language'] = 'de'
        original['gpu']['enabled'] = False
        
        save_config(original, config_path)
        loaded = load_config(config_path)
        
        assert loaded['default_language'] == 'de'
        assert loaded['gpu']['enabled'] is False
