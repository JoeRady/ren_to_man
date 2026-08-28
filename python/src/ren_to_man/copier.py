"""Filesystem copy step (step 5).

Python 3 strings are unicode throughout, so umlauts and other non-ASCII
filenames are handled correctly as long as we never encode/decode through a
narrower codec by hand - we just pass str/Path objects straight to the OS
filesystem calls, which on Windows use the wide (UTF-16) API under the hood.
"""

from __future__ import annotations

import shutil
from datetime import datetime, timezone
from pathlib import Path

from .models import CopyResult, PlannedCopy
from .pathing import to_long_path


def copy_one(planned: PlannedCopy) -> CopyResult:
    now = datetime.now(timezone.utc)

    if not planned.is_copyable:
        return CopyResult(
            planned=planned,
            status="skipped",
            message=planned.skip_reason or "not copyable",
            timestamp=now,
        )

    src = Path(to_long_path(planned.source_path))
    dst = Path(to_long_path(planned.target_path))

    if not src.exists():
        return CopyResult(
            planned=planned,
            status="missing_source",
            message=f"source file not found: {planned.source_path}",
            timestamp=now,
        )

    try:
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists():
            return CopyResult(
                planned=planned,
                status="skipped",
                message=f"target already exists: {planned.target_path}",
                timestamp=now,
            )
        shutil.copy2(src, dst)
        return CopyResult(planned=planned, status="copied", message="", timestamp=now)
    except OSError as exc:
        return CopyResult(
            planned=planned,
            status="error",
            message=str(exc),
            timestamp=now,
        )


def copy_all(plans: list[PlannedCopy]) -> list[CopyResult]:
    return [copy_one(p) for p in plans]
