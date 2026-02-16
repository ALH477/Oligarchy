"""
Tests for DeMoD Voice Clone CLI
"""

import pytest
from pathlib import Path
import subprocess
import sys


def test_cli_help():
    """Test that CLI help runs without error"""
    result = subprocess.run(
        ["python", "bin/demod-voice", "--help"],
        capture_output=True,
        text=True
    )
    assert result.returncode == 0
    assert "DeMoD LLC Voice Clone CLI" in result.stdout


def test_cli_requires_subcommand():
    """Test that CLI requires a subcommand"""
    result = subprocess.run(
        ["python", "bin/demod-voice"],
        capture_output=True,
        text=True
    )
    assert result.returncode != 0


def test_xtts_subcommand_exists():
    """Test that xtts-zero-shot subcommand is available"""
    result = subprocess.run(
        ["python", "bin/demod-voice", "xtts-zero-shot", "--help"],
        capture_output=True,
        text=True
    )
    assert result.returncode == 0
    assert "reference" in result.stdout


def test_piper_subcommand_exists():
    """Test that piper-infer subcommand is available"""
    result = subprocess.run(
        ["python", "bin/demod-voice", "piper-infer", "--help"],
        capture_output=True,
        text=True
    )
    assert result.returncode == 0
    assert "model" in result.stdout


def test_piper_preprocess_subcommand_exists():
    """Test that piper-preprocess subcommand is available"""
    result = subprocess.run(
        ["python", "bin/demod-voice", "piper-preprocess", "--help"],
        capture_output=True,
        text=True
    )
    assert result.returncode == 0
    assert "input-dir" in result.stdout


# Integration tests (require actual dependencies)
@pytest.mark.integration
def test_xtts_missing_reference_file():
    """Test XTTS fails gracefully with missing reference"""
    result = subprocess.run(
        [
            "python", "bin/demod-voice", "xtts-zero-shot",
            "nonexistent.wav", "test text"
        ],
        capture_output=True,
        text=True
    )
    assert result.returncode != 0
    assert "not found" in result.stderr.lower()


@pytest.mark.integration
def test_piper_missing_model_file():
    """Test Piper fails gracefully with missing model"""
    result = subprocess.run(
        [
            "python", "bin/demod-voice", "piper-infer",
            "nonexistent.onnx", "test text"
        ],
        capture_output=True,
        text=True
    )
    assert result.returncode != 0
    assert "not found" in result.stderr.lower()


def test_batch_subcommand_exists():
    """Test that batch subcommand is available"""
    result = subprocess.run(
        ["python", "bin/demod-voice", "batch", "--help"],
        capture_output=True,
        text=True
    )
    assert result.returncode == 0
    assert "batch_file" in result.stdout


def test_health_subcommand_exists():
    """Test that health subcommand is available"""
    result = subprocess.run(
        ["python", "bin/demod-voice", "health", "--help"],
        capture_output=True,
        text=True
    )
    assert result.returncode == 0
    assert "json" in result.stdout


@pytest.mark.integration
def test_health_check_runs():
    """Test health check runs without error"""
    result = subprocess.run(
        ["python", "bin/demod-voice", "health"],
        capture_output=True,
        text=True
    )
    # Should complete without crashing
    assert "Health Check:" in result.stdout or result.returncode in [0, 1]


@pytest.mark.integration
def test_health_check_json_output():
    """Test health check JSON output"""
    result = subprocess.run(
        ["python", "bin/demod-voice", "health", "--json"],
        capture_output=True,
        text=True
    )
    import json
    try:
        data = json.loads(result.stdout)
        assert "status" in data
        assert "checks" in data
    except json.JSONDecodeError:
        pytest.fail("Health check did not produce valid JSON")
