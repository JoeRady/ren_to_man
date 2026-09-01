# RenToMain (PowerShell)

Finds Patricia documents that need to be copied from the **Renewals**
instance to the **Main** instance, and produces a reviewable copy script for
them.

## Important: PowerShell Constrained Language Mode

Many corporate Windows machines run PowerShell under **Constrained Language
Mode** (enforced by AppLocker/WDAC policies). In this mode, method calls on
"non-core" .NET types are blocked - this affects direct SQL Server access
via `System.Data.SqlClient` in particular (and any other ADO.NET-/COM-based
alternative just the same).

**That's why this tool no longer talks to the databases itself.** Instead:

1. You run the two SQL scripts from [`sql/`](sql/) yourself in your SQL
   client (e.g. **SSMS**) and export the results as CSV.
2. `Run-RenToMain.ps1` only reads those two CSV files (via `Import-Csv`),
   joins them, and builds the copy list from that. This uses exclusively
   "core types" (strings, arrays, hashtables, PSCustomObjects) and built-in
   cmdlets - so it works fine under Constrained Language Mode, regardless of
   admin rights or installed extra modules.

This also keeps the security model from the previous iteration intact: the
tool **never** has write access to the database (after this change it has no
database access at all), and the actual copying happens through a separate,
reviewable script with no database dependency whatsoever.

> Tested against: PowerShell 7.5.1 under Constrained Language Mode, without
> `sqlcmd.exe` and without the `SqlServer`/`SQLPS` module - i.e. the lowest
> common denominator. If `sqlcmd`/the `SqlServer` module happens to be
> available in your environment, or you're running in FullLanguage mode, you
> can of course still run the SQL scripts with those instead of SSMS.

## Workflow

**Steps 1-4: run the SQL queries in SSMS and export as CSV**

1. Run [`sql/01_source_documents.sql`](sql/01_source_documents.sql) against
   `SQLSRV01\REN01` / `Patricia`. In SSMS: Query menu -> enable "SQLCMD
   Mode", then set `LoginId`/`CategoryId`/`FromDate`/`ToDate`/`SourceRoot` at
   the top of the script. Export the result: right-click the result grid ->
   "Save Results As..." -> CSV, e.g. as `source_documents.csv`.
2. Run [`sql/02_case_mapping_and_target_paths.sql`](sql/02_case_mapping_and_target_paths.sql)
   against `SQLSRV01\MAIN01` / `Patricia_Main_Live` (set `TargetRoot`). This
   is a reference table with no relation to the search period - export it
   once as `case_mapping.csv` and reuse it across runs; only re-export when
   new case mappings have been added.

Both scripts are pure `SELECT` queries and already compute the source/target
folder path directly in SQL (columns `SOURCE_PATH` / `TARGET_FOLDER`) - the
assumed folder-naming convention (padding, upper/lower casing) is documented
as a comment in each script and should be verified against a few real rows
via Windows Explorer before generating a copy script.

**Step 4 (continued): join the CSVs and list candidates**

```powershell
cd powershell
.\Run-RenToMain.ps1 -SourceDocumentsCsvPath .\source_documents.csv -CaseMappingCsvPath .\case_mapping.csv
```

Writes `logs\candidates_<timestamp>.csv` with all found documents
(`DOC_LOG_ID`, `LOG_DATE`, `DOC_NAME`, `DOC_FILE_NAME`, source path, target
path, skip reason if any) and prints the first 20 rows to the console.

**Step 5: generate the copy script (still nothing is copied)**

```powershell
.\Run-RenToMain.ps1 -SourceDocumentsCsvPath .\source_documents.csv -CaseMappingCsvPath .\case_mapping.csv -GenerateCopyScript
```

Additionally writes `logs\copy_script_<timestamp>.ps1`. That script:

- needs **no database connection**,
- lists all planned copy operations readably at the top,
- creates missing target folders, skips a file if the target already exists
  (never overwrites),
- handles filenames with umlauts and other non-ASCII characters correctly,
- prompts for confirmation before starting (type `YES`, or pass `-Force` to
  skip the prompt),
- writes its own JSONL log (`copy_log_<timestamp>.jsonl`) next to itself,
- uses no constructs that would be blocked under Constrained Language Mode
  (no `StringBuilder`, no generic .NET collections).

```powershell
notepad .\logs\copy_script_20260101_120000.ps1   # review first!
.\logs\copy_script_20260101_120000.ps1           # asks for confirmation before copying
```

**Step 6: build the report**

```powershell
.\Build-RenToMainReport.ps1 -LogPath .\logs\copy_log_20260101_120000.jsonl
```

## Setup

1. Copy the `powershell/` folder to the corporate machine.
2. Copy `RenToMain.config.example.psd1` to `RenToMain.config.psd1` (this
   only controls where logs/CSVs/scripts get written to).
3. If script execution is blocked by default: ask IT about the correct way
   to allow it (signing, an exception, etc.) - `Set-ExecutionPolicy -Scope
   Process -ExecutionPolicy Bypass` only works if your policy allows it in
   the first place.

## Structure

```
powershell/
  RenToMain.psd1                    Module manifest
  RenToMain.psm1                    CSV join, path-building helpers, copy script generator
                                     (no database access, Constrained-Language-Mode safe)
  RenToMain.config.example.psd1     Configuration template (just Logging.LogDir)
  Run-RenToMain.ps1                 Step 4 (+ optional script generation for step 5)
  Build-RenToMainReport.ps1         Step 6: report from the copy script's JSONL log
  sql/
    01_source_documents.sql         Steps 1-4, part 1: source documents (REN01), SOURCE_PATH pre-computed
    02_case_mapping_and_target_paths.sql
                                     Steps 1-4, part 2: case-ID mapping + TARGET_FOLDER (MAIN01), unfiltered
    03_full_candidate_list_linked_server_optional.sql
                                     Optional: everything in one query, if a linked server exists
  tests/
    RenToMain.Tests.ps1             Pester tests for the database-independent logic
```

### Testing the SQL separately

The two scripts in `sql/` can be tested independently of the PowerShell
tool, directly in SSMS or via `sqlcmd` (if available) - pure `SELECT`
queries, nothing gets changed. Each script uses `:setvar` variables (SSMS:
enable "SQLCMD Mode" in the Query menu), so login/category/period/paths can
be tried out without changing the code.

If a linked server from MAIN01 to REN01 exists,
`03_full_candidate_list_linked_server_optional.sql` returns the complete
result (source and target path, skip reason) in a single query - entirely
optional, not needed for the normal workflow above.

### Tests

```powershell
Install-Module Pester -Scope CurrentUser   # if not already present
Invoke-Pester -Path .\tests\RenToMain.Tests.ps1
```

These tests were **not** executed in the Linux development environment this
tool was authored in, since no PowerShell is available there - please run
them on your Windows machine and report anything unexpected. They
deliberately only exercise logic that uses "core types", so they stay
meaningful under Constrained Language Mode too.

## Known assumptions / open points for future iterations

- The **folder-naming convention** is a best guess baked directly into the
  SQL scripts (`sql/01...`, `sql/02...`) - padding, upper/lower casing -
  keep both scripts in sync if the real structure differs.
- Assumes exactly one file per `PAT_DOC_LOG` entry (`DOC_FILE_NAME` inside
  the case folder).
- No `PAT_DOC_LOG` entry is created on the Main side yet - only the
  filesystem copy happens.
- Existing target files are skipped, never overwritten.
- `case_mapping.csv` (step 2) is a reference table unrelated to the search
  period - it doesn't need to be re-exported on every run, only when new
  case mappings are added.
- Real `DOC_FILE_NAME` values can contain a literal `;` - never export
  `source_documents.csv` as semicolon-delimited CSV, it would silently
  corrupt those rows. Tab-delimited and comma-delimited exports are both
  fine and auto-detected.
- If it turns out Constrained Language Mode doesn't actually apply to you
  (or IT changes that), or `sqlcmd`/the `SqlServer` module becomes
  available, a direct database connection could be added back in - it's
  deliberately not built in right now, so as not to depend on a possibly
  unintended policy gap (e.g. elevated sessions running in `FullLanguage`).
