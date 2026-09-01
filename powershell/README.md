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

**Step 4.5 (recommended): verify against Main-Live and Nuxeo**

Before copying anything, it's worth checking whether a document has already
made it across by some other route - both into Patricia Main's own
`PAT_DOC_LOG` and into the Nuxeo document store at the corresponding path.

Before your first verification run, confirm Nuxeo connectivity works at all
with [`Test-NuxeoConnection.ps1`](Test-NuxeoConnection.ps1) - a standalone
script with no dependency on the rest of the tool:

```powershell
# create powershell\nuxeo.credentials.txt first - copy
# nuxeo.credentials.example.txt and fill in real values (plain text, only
# for this one-off test - never commit it, delete it once you're done)
.\Test-NuxeoConnection.ps1
.\Test-NuxeoConnection.ps1 -TestPath '/Workspaces/Patricia/Documents/2/666777/DE/EP/somefile.pdf'
```

It reports plainly whether login works, and - importantly - whether
building a `PSCredential` object is even possible in your environment (this
has not been confirmed either way under Constrained Language Mode; if it's
blocked there, report that back so a different auth approach can be worked
out). Use `-TestPath` with a document you already know exists (or doesn't)
to confirm `Get-RenToMainNuxeoPath`'s path convention is actually correct.

1. Run [`sql/03_main_live_existing_documents.sql`](sql/03_main_live_existing_documents.sql)
   against `SQLSRV01\MAIN01` / `Patricia_Main_Live` (self-contained, no
   `:setvar` values needed). Export as `main_live_documents.csv`. Unlike
   `case_mapping.csv`, re-export this shortly before each run - documents
   get added continuously, so a stale copy could cause the tool to treat an
   already-migrated document as new.
2. Pass it to `Run-RenToMain.ps1` along with the Nuxeo settings:

```powershell
.\Run-RenToMain.ps1 -SourceDocumentsCsvPath .\source_documents.csv -CaseMappingCsvPath .\case_mapping.csv `
    -MainLiveDocumentsCsvPath .\main_live_documents.csv -GenerateCopyScript
```

`NuxeoBaseUrl` (default `https://ndc-edms-01.corp.withersrogers.com/nuxeo`)
and `NuxeoRootPath` (default `\Workspaces\Patricia\Documents\`) already have
the right defaults for this environment - override with `-NuxeoBaseUrl` /
`-NuxeoRootPath` if that ever changes. On first run it asks once for the
Nuxeo service account credentials (`Get-Credential`) and caches them
encrypted (DPAPI via `Export-Clixml` - only readable by the same Windows
user on the same machine) at `RenToMain.nuxeo.credential.xml` next to the
script, so you won't be asked again.

For each candidate, this checks live against Nuxeo (`GET
{NuxeoBaseUrl}/api/v1/path/{path}`) and against the Main-Live CSV
(matched on the mapped `CASE_ID` + `DOC_FILE_NAME`), then decides:

| In Main-Live? | In Nuxeo? | Action |
|---|---|---|
| yes | yes | nothing to do |
| yes | no | copy the file |
| no | no | copy the file **and** create a new `PAT_DOC_LOG` row |
| no | yes | create a new `PAT_DOC_LOG` row only |

A Nuxeo check that can't be answered cleanly (network error, auth failure,
anything other than a clean 200/404) **never** triggers an automatic
action - it's marked `VerificationFailed` and excluded from both generated
scripts, with the reason in `SKIP_REASON`, so it doesn't risk creating a
duplicate.

> The exact path convention this assumes for Nuxeo (mirroring the
> filesystem's `<CaseType>/<FamilyNumber>/<Country>/<Extension>/<filename>`
> structure under `NuxeoRootPath`) has **not been verified against the real
> server** - before trusting the results, test it against a handful of
> documents you know for certain are (or aren't) in Nuxeo already, and
> check the console output/candidate CSV agrees.

Without `-MainLiveDocumentsCsvPath`, this step is skipped entirely and every
candidate is treated as a plain copy (pre-verification behaviour).

**Step 5: generate the copy/insert scripts (still nothing is copied or inserted)**

```powershell
.\Run-RenToMain.ps1 -SourceDocumentsCsvPath .\source_documents.csv -CaseMappingCsvPath .\case_mapping.csv `
    -MainLiveDocumentsCsvPath .\main_live_documents.csv -GenerateCopyScript
```

Writes `logs\copy_script_<timestamp>.ps1`, and - if verification found any
documents needing a new `PAT_DOC_LOG` row - also
`logs\insert_script_<timestamp>.sql`.

The **copy script**:

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

The **insert script** (only generated when needed) is a plain `.sql` file
with `INSERT` statements for `dbo.PAT_DOC_LOG` on Main-Live - review it,
then run it yourself in SSMS. It is **never executed by anything
automatically**. It only populates a minimal, best-effort set of columns
(`CASE_ID`, `LOGIN_ID`, `LOG_DATE`, `DOC_TYPE`, `DOC_NAME`, `DOC_FILE_NAME`,
`CATEGORY_ID`) - `PAT_DOC_LOG` has further columns not set here; check with
your DBA whether any of those need real values before running it against
production.

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
  RenToMain.psm1                    CSV join, path-building helpers, Main-Live/Nuxeo verification,
                                     copy script + insert script generators
                                     (no direct database writes, Constrained-Language-Mode safe)
  RenToMain.config.example.psd1     Configuration template (just Logging.LogDir)
  Run-RenToMain.ps1                 Steps 4-5 (join, optional verification, optional script generation)
  Build-RenToMainReport.ps1         Step 6: report from the copy script's JSONL log
  Test-NuxeoConnection.ps1          Standalone Nuxeo login/path connectivity test, no other dependency
  nuxeo.credentials.example.txt     Template for Test-NuxeoConnection.ps1's plain-text credential file
  RenToMain.nuxeo.credential.xml    Created on first verification run (gitignored) - encrypted Nuxeo credential
  sql/
    01_source_documents.sql         Steps 1-4, part 1: source documents (REN01), SOURCE_PATH pre-computed
    02_case_mapping_and_target_paths.sql
                                     Steps 1-4, part 2: case-ID mapping + TARGET_FOLDER (MAIN01), unfiltered
    03_main_live_existing_documents.sql
                                     Step 4.5: existing PAT_DOC_LOG rows on Main-Live, for verification
    04_full_candidate_list_linked_server_optional.sql
                                     Optional: everything in one query, if a linked server exists
  tests/
    RenToMain.Tests.ps1             Pester tests for the database-independent logic
```

### Testing the SQL separately

The scripts in `sql/` can be tested independently of the PowerShell tool,
directly in SSMS or via `sqlcmd` (if available) - pure `SELECT` queries,
nothing gets changed. Each script that takes parameters uses `:setvar`
variables (SSMS: enable "SQLCMD Mode" in the Query menu), so
login/category/period/paths can be tried out without changing the code.

If a linked server from MAIN01 to REN01 exists,
`04_full_candidate_list_linked_server_optional.sql` returns the complete
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
  SQL scripts (`sql/01...`, `sql/02...`) and, for the Nuxeo path, into
  `Get-RenToMainNuxeoPath` in `RenToMain.psm1` - padding, upper/lower casing
  - keep all three in sync if the real structure differs.
- Assumes exactly one file per `PAT_DOC_LOG` entry (`DOC_FILE_NAME` inside
  the case folder).
- The **Nuxeo path convention** used for the live existence check has not
  been verified against the real server yet - see the warning in the
  workflow section above.
- The generated `PAT_DOC_LOG` insert only populates a minimal column set;
  confirm with your DBA whether Main-Live requires values for any of the
  other (mostly nullable) columns before relying on it.
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
