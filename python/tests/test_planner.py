import datetime as dt

from ren_to_man.config import Config, DbConfig, FolderFormatConfig
from ren_to_man.models import CaseInfo, DocLogEntry
from ren_to_man.planner import build_plan


def make_cfg():
    return Config(
        renewals_db=DbConfig(driver="x", server="x", database="x"),
        main_db=DbConfig(driver="x", server="x", database="x"),
        source_root="\\\\brifile\\Renewals\\Patricia\\documents",
        folder_format=FolderFormatConfig(),
    )


def test_build_plan_happy_path():
    entries = [
        DocLogEntry(
            doc_log_id=1,
            case_id=100,
            login_id="jsmith",
            log_date=dt.datetime(2026, 1, 1),
            doc_type="Letter",
            doc_name="Renewal Reminder",
            doc_file_name="reminder_ümlaut.pdf",
            category_id=5,
        )
    ]
    source_cases = {100: CaseInfo(100, 2, 666777, "DE", "EP")}
    case_id_map = {100: 200}
    target_cases = {200: CaseInfo(200, 2, 666777, "DE", "EP")}
    cfg = make_cfg()

    plans = build_plan(entries, source_cases, case_id_map, target_cases, cfg, "\\\\brimain\\Main\\Patricia\\documents")

    assert len(plans) == 1
    p = plans[0]
    assert p.is_copyable
    assert str(p.source_path) == "\\\\brifile\\Renewals\\Patricia\\documents\\2\\666777\\DE\\EP\\reminder_ümlaut.pdf"
    assert str(p.target_path) == "\\\\brimain\\Main\\Patricia\\documents\\2\\666777\\DE\\EP\\reminder_ümlaut.pdf"


def test_build_plan_missing_mapping_is_skipped():
    entries = [
        DocLogEntry(1, 100, "jsmith", dt.datetime(2026, 1, 1), "Letter", "Doc", "f.pdf", 5)
    ]
    source_cases = {100: CaseInfo(100, 2, 666777, "DE", "EP")}
    cfg = make_cfg()

    plans = build_plan(entries, source_cases, {}, {}, cfg, "\\\\brimain\\Main\\Patricia\\documents")

    assert len(plans) == 1
    assert not plans[0].is_copyable
    assert "mapping" in plans[0].skip_reason


def test_build_plan_missing_source_case_is_skipped():
    entries = [
        DocLogEntry(1, 999, "jsmith", dt.datetime(2026, 1, 1), "Letter", "Doc", "f.pdf", 5)
    ]
    cfg = make_cfg()

    plans = build_plan(entries, {}, {}, {}, cfg, "\\\\brimain\\Main\\Patricia\\documents")

    assert len(plans) == 1
    assert not plans[0].is_copyable
    assert "source case" in plans[0].skip_reason
