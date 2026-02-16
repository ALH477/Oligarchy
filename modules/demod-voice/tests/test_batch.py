"""
Tests for DeMoD Voice Clone batch processing module
"""

import pytest
from pathlib import Path
import tempfile
import csv
import sys

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from demod_voice.batch import BatchJob, load_batch_csv, validate_batch_jobs


def test_batch_job_creation():
    """Test creating a BatchJob"""
    job = BatchJob(
        reference=Path("/tmp/ref.wav"),
        text="Hello world",
        output=Path("/tmp/out.wav"),
        language="en",
        speaker=1
    )
    
    assert job.reference == Path("/tmp/ref.wav")
    assert job.text == "Hello world"
    assert job.output == Path("/tmp/out.wav")
    assert job.language == "en"
    assert job.speaker == 1


def test_load_batch_csv():
    """Test loading batch jobs from CSV"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.csv', delete=False, newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['reference', 'text', 'output', 'language', 'speaker'])
        writer.writerow(['/tmp/ref1.wav', 'Hello', '/tmp/out1.wav', 'en', '1'])
        writer.writerow(['/tmp/ref2.wav', 'World', '/tmp/out2.wav', 'fr', '2'])
        temp_path = Path(f.name)
    
    try:
        jobs = load_batch_csv(temp_path)
        assert len(jobs) == 2
        
        assert jobs[0].reference == Path('/tmp/ref1.wav')
        assert jobs[0].text == 'Hello'
        assert jobs[0].language == 'en'
        assert jobs[0].speaker == 1
        
        assert jobs[1].text == 'World'
        assert jobs[1].language == 'fr'
    finally:
        temp_path.unlink()


def test_load_batch_csv_optional_fields():
    """Test loading batch jobs with optional fields omitted"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.csv', delete=False, newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['reference', 'text', 'output'])
        writer.writerow(['/tmp/ref.wav', 'Test', '/tmp/out.wav'])
        temp_path = Path(f.name)
    
    try:
        jobs = load_batch_csv(temp_path)
        assert len(jobs) == 1
        assert jobs[0].language is None
        assert jobs[0].speaker is None
    finally:
        temp_path.unlink()


def test_load_batch_csv_empty_file():
    """Test loading from empty CSV"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.csv', delete=False) as f:
        f.write('reference,text,output\n')
        temp_path = Path(f.name)
    
    try:
        jobs = load_batch_csv(temp_path)
        assert len(jobs) == 0
    finally:
        temp_path.unlink()


def test_validate_batch_jobs():
    """Test validation of batch jobs"""
    with tempfile.TemporaryDirectory() as tmpdir:
        # Create a reference file
        ref_file = Path(tmpdir) / "ref.wav"
        ref_file.touch()
        
        jobs = [
            BatchJob(reference=ref_file, text="Valid", output=Path(tmpdir) / "out1.wav"),
            BatchJob(reference=Path("/nonexistent.wav"), text="Invalid", output=Path(tmpdir) / "out2.wav"),
            BatchJob(reference=ref_file, text="", output=Path(tmpdir) / "out3.wav"),
        ]
        
        valid, errors = validate_batch_jobs(jobs)
        
        assert len(valid) == 1
        assert len(errors) == 2
        assert valid[0].text == "Valid"
