"""Step 6: write a JSONL run log and generate a human-readable report from it."""

from __future__ import annotations

import csv
import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from .models import CopyResult, PlannedCopy


def write_plan_csv(plans: list[PlannedCopy], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "DOC_LOG_ID",
                "CASE_ID",
                "MAIN_CASE_ID",
                "LOG_DATE",
                "DOC_NAME",
                "DOC_FILE_NAME",
                "SOURCE_PATH",
                "TARGET_PATH",
                "SKIP_REASON",
            ]
        )
        for p in plans:
            w.writerow(
                [
                    p.doc_log_id,
                    p.case_id,
                    p.main_case_id or "",
                    p.log_date.isoformat() if p.log_date else "",
                    p.doc_name or "",
                    p.doc_file_name or "",
                    str(p.source_path) if p.source_path else "",
                    str(p.target_path) if p.target_path else "",
                    p.skip_reason or "",
                ]
            )


def write_run_log(results: list[CopyResult], log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        for r in results:
            record = {
                "timestamp": (r.timestamp or datetime.now(timezone.utc)).isoformat(),
                "doc_log_id": r.planned.doc_log_id,
                "case_id": r.planned.case_id,
                "main_case_id": r.planned.main_case_id,
                "source_path": str(r.planned.source_path) if r.planned.source_path else None,
                "target_path": str(r.planned.target_path) if r.planned.target_path else None,
                "status": r.status,
                "message": r.message,
            }
            f.write(json.dumps(record, ensure_ascii=False) + "\n")


def write_report(results: list[CopyResult], report_path: Path) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    counts = Counter(r.status for r in results)

    lines = []
    lines.append("ren_to_man run report")
    lines.append(f"generated: {datetime.now(timezone.utc).isoformat()}")
    lines.append("")
    lines.append(f"total documents considered: {len(results)}")
    for status in ("copied", "skipped", "missing_source", "error"):
        lines.append(f"  {status}: {counts.get(status, 0)}")
    lines.append("")

    problems = [r for r in results if r.status in ("missing_source", "error")]
    if problems:
        lines.append("Details for missing/errored documents:")
        for r in problems:
            lines.append(
                f"  DOC_LOG_ID={r.planned.doc_log_id} CASE_ID={r.planned.case_id} "
                f"status={r.status} message={r.message}"
            )
    else:
        lines.append("No missing sources or errors.")

    report_path.write_text("\n".join(lines), encoding="utf-8")


def read_run_log(log_path: Path) -> list[dict]:
    if not log_path.exists():
        return []
    records = []
    with open(log_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records
