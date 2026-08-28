"""MSSQL access for source (Renewals), target (Main) and the case-id lookup table."""

from __future__ import annotations

from contextlib import contextmanager
from datetime import date
from typing import Iterable, Iterator, Optional

import pyodbc

from .config import DbConfig
from .models import CaseInfo, DocLogEntry


@contextmanager
def connect(cfg: DbConfig) -> Iterator[pyodbc.Connection]:
    conn = pyodbc.connect(cfg.connection_string())
    try:
        yield conn
    finally:
        conn.close()


def fetch_doc_log_entries(
    conn: pyodbc.Connection,
    login_id: Optional[str],
    category_id: Optional[int],
    date_from: date,
    date_to: date,
) -> list[DocLogEntry]:
    """Query PAT_DOC_LOG on the source (Renewals) instance.

    At least one of login_id / category_id must be provided (enforced by the
    caller / CLI). LOG_DATE is filtered inclusive on both ends.
    """
    conditions = ["LOG_DATE >= ?", "LOG_DATE < DATEADD(day, 1, ?)"]
    params: list = [date_from, date_to]

    if login_id:
        conditions.append("LOGIN_ID = ?")
        params.append(login_id)
    if category_id is not None:
        conditions.append("CATEGORY_ID = ?")
        params.append(category_id)

    sql = f"""
        SELECT DOC_LOG_ID, CASE_ID, LOGIN_ID, LOG_DATE, DOC_TYPE, DOC_NAME,
               DOC_FILE_NAME, CATEGORY_ID
        FROM PAT_DOC_LOG
        WHERE {' AND '.join(conditions)}
        ORDER BY CASE_ID, LOG_DATE
    """
    cur = conn.cursor()
    cur.execute(sql, params)
    rows = cur.fetchall()
    return [
        DocLogEntry(
            doc_log_id=r.DOC_LOG_ID,
            case_id=r.CASE_ID,
            login_id=r.LOGIN_ID,
            log_date=r.LOG_DATE,
            doc_type=r.DOC_TYPE,
            doc_name=r.DOC_NAME,
            doc_file_name=r.DOC_FILE_NAME,
            category_id=r.CATEGORY_ID,
        )
        for r in rows
    ]


def fetch_case_info(conn: pyodbc.Connection, case_ids: Iterable[int]) -> dict[int, CaseInfo]:
    """Query PAT_CASE for a batch of case ids. Works against either instance."""
    ids = list({c for c in case_ids if c is not None})
    if not ids:
        return {}

    result: dict[int, CaseInfo] = {}
    cur = conn.cursor()
    # Chunk to stay well under SQL Server's parameter/IN-list limits.
    chunk_size = 1000
    for i in range(0, len(ids), chunk_size):
        chunk = ids[i : i + chunk_size]
        placeholders = ",".join("?" for _ in chunk)
        sql = f"""
            SELECT CASE_ID, CASE_TYPE_ID, CASE_NUMBER, STATE_ID, CASE_NUMBER_EXTENSION
            FROM PAT_CASE
            WHERE CASE_ID IN ({placeholders})
        """
        cur.execute(sql, chunk)
        for r in cur.fetchall():
            result[r.CASE_ID] = CaseInfo(
                case_id=r.CASE_ID,
                case_type_id=r.CASE_TYPE_ID,
                case_number=r.CASE_NUMBER,
                state_id=r.STATE_ID,
                case_number_extension=r.CASE_NUMBER_EXTENSION,
            )
    return result


def fetch_case_id_mapping(conn: pyodbc.Connection, renewals_case_ids: Iterable[int]) -> dict[int, int]:
    """Query wr_Renewals_vs_Main_Live on the Main instance.

    Returns {RENEWALS_CASE_ID: MAIN_LIVE_CASE_ID}.
    """
    ids = list({c for c in renewals_case_ids if c is not None})
    if not ids:
        return {}

    result: dict[int, int] = {}
    cur = conn.cursor()
    chunk_size = 1000
    for i in range(0, len(ids), chunk_size):
        chunk = ids[i : i + chunk_size]
        placeholders = ",".join("?" for _ in chunk)
        sql = f"""
            SELECT MAIN_LIVE_CASE_ID, RENEWALS_CASE_ID
            FROM wr_Renewals_vs_Main_Live
            WHERE RENEWALS_CASE_ID IN ({placeholders})
        """
        cur.execute(sql, chunk)
        for r in cur.fetchall():
            result[r.RENEWALS_CASE_ID] = r.MAIN_LIVE_CASE_ID
    return result


def insert_target_doc_log(conn: pyodbc.Connection, source_row: dict, new_case_id: int) -> None:
    """Placeholder for a future iteration: inserting a PAT_DOC_LOG row on the
    Main instance once the file has been copied, so the document also shows
    up inside Patricia Main itself (not just on disk).

    Not wired up yet - deliberately left unimplemented until the exact set of
    columns to carry over / regenerate (DOC_LOG_ID, ACTOR_ID, CATEGORY_ID
    mapping, etc.) is confirmed.
    """
    raise NotImplementedError(
        "Writing PAT_DOC_LOG rows on the Main instance is not implemented yet."
    )
