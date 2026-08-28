"""Command-line entry point.

Typical usage:

    # 1-4: search + list only (dry run), writes a CSV you can review
    python -m ren_to_man run \\
        --login-id jsmith \\
        --from-date 2026-01-01 --to-date 2026-06-30 \\
        --target-root "\\\\brimain\\Main\\Patricia\\documents"

    # 5-6: actually copy the files and write log + report
    python -m ren_to_man run \\
        --login-id jsmith \\
        --from-date 2026-01-01 --to-date 2026-06-30 \\
        --target-root "\\\\brimain\\Main\\Patricia\\documents" \\
        --execute
"""

from __future__ import annotations

import datetime as dt
from pathlib import Path

import click

from .config import Config, default_config_path
from .copier import copy_all
from .db import connect, fetch_case_id_mapping, fetch_case_info, fetch_doc_log_entries
from .planner import build_plan
from .reporting import write_plan_csv, write_report, write_run_log


@click.group()
def main() -> None:
    """ren_to_man: copy Patricia documents from Renewals to Main."""


@main.command()
@click.option("--login-id", default=None, help="Filter by PAT_DOC_LOG.LOGIN_ID.")
@click.option("--category-id", default=None, type=int, help="Filter by PAT_DOC_LOG.CATEGORY_ID.")
@click.option("--from-date", required=True, type=click.DateTime(formats=["%Y-%m-%d"]), help="Start date (inclusive), YYYY-MM-DD.")
@click.option("--to-date", required=True, type=click.DateTime(formats=["%Y-%m-%d"]), help="End date (inclusive), YYYY-MM-DD.")
@click.option("--target-root", required=True, help="Root folder of the target (Main) document store, e.g. a UNC path.")
@click.option("--source-root", default=None, help="Override the source root from config.yaml for this run.")
@click.option("--config", "config_path", default=None, help="Path to config.yaml (default: config.yaml or $REN_TO_MAN_CONFIG).")
@click.option("--execute", is_flag=True, default=False, help="Actually copy files. Without this flag, only lists candidates (dry run).")
@click.option("--out-dir", default=None, help="Directory to write the candidate list CSV / log / report into (default: config logging.log_dir).")
def run(
    login_id: str | None,
    category_id: int | None,
    from_date: dt.datetime,
    to_date: dt.datetime,
    target_root: str,
    source_root: str | None,
    config_path: str | None,
    execute: bool,
    out_dir: str | None,
) -> None:
    """Steps 1-6: find documents, list them, and (with --execute) copy + log + report."""

    if not login_id and category_id is None:
        raise click.UsageError("Provide at least one of --login-id / --category-id.")

    cfg = Config.load(config_path or default_config_path())
    if source_root:
        cfg.source_root = source_root

    log_dir = Path(out_dir) if out_dir else cfg.ensure_log_dir()
    log_dir.mkdir(parents=True, exist_ok=True)
    run_stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")

    click.echo("Querying source documents (PAT_DOC_LOG) ...")
    with connect(cfg.renewals_db) as ren_conn:
        entries = fetch_doc_log_entries(
            ren_conn, login_id, category_id, from_date.date(), to_date.date()
        )
        click.echo(f"  found {len(entries)} document(s)")

        source_case_ids = {e.case_id for e in entries}
        click.echo("Querying source case data (PAT_CASE) ...")
        source_cases = fetch_case_info(ren_conn, source_case_ids)

    click.echo("Looking up case-id mapping (wr_Renewals_vs_Main_Live) and target case data ...")
    with connect(cfg.main_db) as main_conn:
        case_id_map = fetch_case_id_mapping(main_conn, source_case_ids)
        target_cases = fetch_case_info(main_conn, set(case_id_map.values()))

    plans = build_plan(entries, source_cases, case_id_map, target_cases, cfg, target_root)

    plan_csv = log_dir / f"candidates_{run_stamp}.csv"
    write_plan_csv(plans, plan_csv)

    copyable = [p for p in plans if p.is_copyable]
    skipped = [p for p in plans if not p.is_copyable]

    click.echo("")
    click.echo(f"Candidate list written to: {plan_csv}")
    click.echo(f"  copyable: {len(copyable)}")
    click.echo(f"  skipped (see SKIP_REASON in CSV): {len(skipped)}")
    click.echo("")
    for p in plans[:20]:
        click.echo(
            f"  [{p.doc_log_id}] {p.log_date} {p.doc_name!r} "
            f"src={p.source_path} -> dst={p.target_path} "
            f"{'SKIP: ' + p.skip_reason if p.skip_reason else ''}"
        )
    if len(plans) > 20:
        click.echo(f"  ... and {len(plans) - 20} more, see {plan_csv}")

    if not execute:
        click.echo("")
        click.echo("Dry run only - no files were copied. Re-run with --execute to copy.")
        return

    click.echo("")
    click.echo(f"Copying {len(copyable)} file(s) ...")
    results = copy_all(plans)

    run_log = log_dir / f"run_{run_stamp}.jsonl"
    report = log_dir / f"report_{run_stamp}.txt"
    write_run_log(results, run_log)
    write_report(results, report)

    click.echo(f"Log written to: {run_log}")
    click.echo(f"Report written to: {report}")


if __name__ == "__main__":
    main()
