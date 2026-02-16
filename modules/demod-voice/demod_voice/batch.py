"""
Batch processing utilities for DeMoD Voice Clone
"""

import csv
import logging
from pathlib import Path
from typing import List, Dict, Any, Optional
from dataclasses import dataclass


@dataclass
class BatchJob:
    """Represents a single batch processing job."""
    reference: Path
    text: str
    output: Path
    language: Optional[str] = None
    speaker: Optional[int] = None


def load_batch_csv(csv_path: Path) -> List[BatchJob]:
    """
    Load batch jobs from a CSV file.
    
    Expected CSV format:
    reference,text,output[,language,speaker]
    
    Args:
        csv_path: Path to CSV file
        
    Returns:
        List of BatchJob objects
    """
    jobs = []
    logger = logging.getLogger(__name__)
    
    with open(csv_path, 'r', newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        
        for i, row in enumerate(reader, 1):
            try:
                job = BatchJob(
                    reference=Path(row['reference']),
                    text=row['text'],
                    output=Path(row['output']),
                    language=row.get('language'),
                    speaker=int(row['speaker']) if row.get('speaker') else None
                )
                jobs.append(job)
            except (KeyError, ValueError) as e:
                logger.warning(f"Skipping row {i}: {e}")
    
    return jobs


def validate_batch_jobs(jobs: List[BatchJob]) -> tuple[List[BatchJob], List[str]]:
    """
    Validate batch jobs and return valid jobs + error messages.
    
    Returns:
        Tuple of (valid_jobs, error_messages)
    """
    valid = []
    errors = []
    
    for i, job in enumerate(jobs, 1):
        error_prefix = f"Job {i}"
        
        if not job.reference.exists():
            errors.append(f"{error_prefix}: Reference file not found: {job.reference}")
            continue
        
        if not job.text.strip():
            errors.append(f"{error_prefix}: Empty text")
            continue
        
        # Ensure output directory exists
        job.output.parent.mkdir(parents=True, exist_ok=True)
        
        valid.append(job)
    
    return valid, errors
