"""Data models used throughout the pipeline."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional


@dataclass
class CaseInfo:
    case_id: int
    case_type_id: int
    case_number: int
    state_id: str
    case_number_extension: str


@dataclass
class DocLogEntry:
    doc_log_id: int
    case_id: int
    login_id: Optional[str]
    log_date: Optional[datetime]
    doc_type: Optional[str]
    doc_name: Optional[str]
    doc_file_name: Optional[str]
    category_id: Optional[int]


@dataclass
class PlannedCopy:
    doc_log_id: int
    case_id: int
    main_case_id: Optional[int]
    log_date: Optional[datetime]
    doc_name: Optional[str]
    doc_file_name: Optional[str]
    source_path: Optional[Path]
    target_path: Optional[Path]
    skip_reason: Optional[str] = None

    @property
    def is_copyable(self) -> bool:
        return self.skip_reason is None and self.source_path is not None and self.target_path is not None


@dataclass
class CopyResult:
    planned: PlannedCopy
    status: str  # "copied", "skipped", "missing_source", "error"
    message: str = ""
    timestamp: Optional[datetime] = None
