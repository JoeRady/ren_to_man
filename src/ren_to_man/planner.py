"""Turn raw DB rows into PlannedCopy entries (step 4: 'Auflistung der gefundenen Dokumente')."""

from __future__ import annotations

from pathlib import PureWindowsPath
from typing import Optional

from .config import Config
from .models import CaseInfo, DocLogEntry, PlannedCopy
from .pathing import case_folder_path


def build_plan(
    entries: list[DocLogEntry],
    source_cases: dict[int, CaseInfo],
    case_id_map: dict[int, int],
    target_cases: dict[int, CaseInfo],
    cfg: Config,
    target_root: str,
) -> list[PlannedCopy]:
    plan: list[PlannedCopy] = []

    for e in entries:
        src_case = source_cases.get(e.case_id)
        if src_case is None:
            plan.append(
                PlannedCopy(
                    doc_log_id=e.doc_log_id,
                    case_id=e.case_id,
                    main_case_id=None,
                    log_date=e.log_date,
                    doc_name=e.doc_name,
                    doc_file_name=e.doc_file_name,
                    source_path=None,
                    target_path=None,
                    skip_reason="source case not found in PAT_CASE",
                )
            )
            continue

        source_dir = case_folder_path(cfg.source_root, src_case, cfg.folder_format)
        source_path = source_dir / (e.doc_file_name or "") if e.doc_file_name else None

        main_case_id = case_id_map.get(e.case_id)
        if main_case_id is None:
            plan.append(
                PlannedCopy(
                    doc_log_id=e.doc_log_id,
                    case_id=e.case_id,
                    main_case_id=None,
                    log_date=e.log_date,
                    doc_name=e.doc_name,
                    doc_file_name=e.doc_file_name,
                    source_path=source_path,
                    target_path=None,
                    skip_reason="no mapping in wr_Renewals_vs_Main_Live",
                )
            )
            continue

        tgt_case = target_cases.get(main_case_id)
        if tgt_case is None:
            plan.append(
                PlannedCopy(
                    doc_log_id=e.doc_log_id,
                    case_id=e.case_id,
                    main_case_id=main_case_id,
                    log_date=e.log_date,
                    doc_name=e.doc_name,
                    doc_file_name=e.doc_file_name,
                    source_path=source_path,
                    target_path=None,
                    skip_reason="target case not found in Main PAT_CASE",
                )
            )
            continue

        target_dir = case_folder_path(target_root, tgt_case, cfg.folder_format)
        target_path = target_dir / (e.doc_file_name or "") if e.doc_file_name else None

        skip_reason: Optional[str] = None
        if not e.doc_file_name:
            skip_reason = "DOC_FILE_NAME is empty"

        plan.append(
            PlannedCopy(
                doc_log_id=e.doc_log_id,
                case_id=e.case_id,
                main_case_id=main_case_id,
                log_date=e.log_date,
                doc_name=e.doc_name,
                doc_file_name=e.doc_file_name,
                source_path=source_path,
                target_path=target_path,
                skip_reason=skip_reason,
            )
        )

    return plan
