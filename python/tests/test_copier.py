from pathlib import Path

from ren_to_man.copier import copy_one
from ren_to_man.models import PlannedCopy


def test_copy_one_success(tmp_path: Path):
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    src_file = src_dir / "ümlaut file.pdf"
    src_file.write_text("hello", encoding="utf-8")

    dst_file = tmp_path / "dst" / "2" / "666777" / "DE" / "EP" / "ümlaut file.pdf"

    planned = PlannedCopy(
        doc_log_id=1,
        case_id=100,
        main_case_id=200,
        log_date=None,
        doc_name="Doc",
        doc_file_name="ümlaut file.pdf",
        source_path=src_file,
        target_path=dst_file,
    )

    result = copy_one(planned)

    assert result.status == "copied"
    assert dst_file.exists()
    assert dst_file.read_text(encoding="utf-8") == "hello"


def test_copy_one_missing_source(tmp_path: Path):
    planned = PlannedCopy(
        doc_log_id=1,
        case_id=100,
        main_case_id=200,
        log_date=None,
        doc_name="Doc",
        doc_file_name="nope.pdf",
        source_path=tmp_path / "does_not_exist.pdf",
        target_path=tmp_path / "dst" / "nope.pdf",
    )

    result = copy_one(planned)

    assert result.status == "missing_source"


def test_copy_one_skipped_when_not_copyable():
    planned = PlannedCopy(
        doc_log_id=1,
        case_id=100,
        main_case_id=None,
        log_date=None,
        doc_name="Doc",
        doc_file_name="f.pdf",
        source_path=None,
        target_path=None,
        skip_reason="no mapping",
    )

    result = copy_one(planned)

    assert result.status == "skipped"
    assert result.message == "no mapping"
