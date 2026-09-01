# ren_to_main

Finds Patricia documents that need to be copied from the **Renewals**
instance to the **Main** instance: reads `PAT_DOC_LOG` / `PAT_CASE` on the
source side, maps `CASE_ID` to the target `CASE_ID` via
`wr_Renewals_vs_Main_Live`, and builds the source/target path from the
four-level folder structure (`Case Type / Family Number / Country / Case
Number Extension`).

**Security model:** The SQL queries (see [`powershell/sql/`](powershell/sql/))
are pure `SELECT` statements - not a single one writes to the database. The
primary **PowerShell variant no longer talks to the database itself at all**
(see the Constrained Language Mode note below): you run the SQL scripts
yourself, e.g. in SSMS, and export the results as CSV; the tool only reads
those CSVs. The actual copying (step 5) doesn't happen directly, but through
a separately generated, standalone script with no database dependency at
all, which can be fully reviewed before it runs.

## Variants

| Variant | Folder | When to use |
|---|---|---|
| **PowerShell** (`RenToMain`) | [`powershell/`](powershell/README.md) | **Primary.** CSV/SSMS-based, also works under PowerShell **Constrained Language Mode** (commonly enforced on corporate Windows machines via AppLocker/WDAC) and independent of admin rights. |
| Python | [`python/`](python/README.md) | Alternative with direct DB access (`pyodbc`) and direct copying - only usable if Python can be run and no language-mode restriction applies. |

The Python variant hasn't kept pace with PowerShell since the latest major
iteration (no CSV workflow, direct DB access and direct copying) - see
[`python/README.md`](python/README.md). Its docs remain in German for now.

## Standalone-testable SQL queries for step 4

Under [`powershell/sql/`](powershell/sql/) are the SQL scripts used for step
4 ("list the found documents"), parameterized via `:setvar` variables so
they can be tested directly in SSMS or via `sqlcmd` against the real
instances - for the PowerShell variant this is now in fact the regular, only
way the database is ever queried (see
[`powershell/README.md`](powershell/README.md#important-powershell-constrained-language-mode)).

## Steps 1-6 (quick overview)

1. Enter `LOGIN_ID` and/or `CATEGORY_ID` (at least one of the two) - as
   `:setvar` in the SQL script
2. Date range from...to - also as `:setvar`
3. Target path (root of the Main folder structure) - also as `:setvar`
4. List the found documents (source path, `DOC_LOG_ID`, `LOG_DATE`,
   `DOC_NAME`, `DOC_FILE_NAME`, target path) as CSV - read-only; PowerShell
   only ever queries the CSVs you exported, never the database itself
5. Verify (recommended) each document against Main-Live's `PAT_DOC_LOG` and,
   live, against Nuxeo, then decide per document: nothing to do, copy only,
   copy + create a new `PAT_DOC_LOG` row, or create the row only - see
   [`powershell/README.md`](powershell/README.md#step-45-recommended-verify-against-main-live-and-nuxeo)
6. Copy/insert: `Run-RenToMain.ps1 -GenerateCopyScript` generates a
   standalone, database-independent copy script and (if needed) a reviewable
   SQL insert script - nothing is copied or written by the tool itself; it
   creates target folders and handles filenames with umlauts correctly
   (Unicode)
7. `Build-RenToMainReport.ps1` builds a human-readable report from the copy
   script's log

## Known assumptions / open points for future iterations

- The **folder-naming convention** (padding of Case Type/Family Number,
  upper/lower casing of Country/Extension) is a best guess baked directly
  into the SQL scripts and, for Nuxeo, into `Get-RenToMainNuxeoPath` - should
  be verified against real listing/verification runs before
  generating/running the copy or insert script.
- Assumes exactly one file per `PAT_DOC_LOG` entry (`DOC_FILE_NAME` inside
  the case folder). Multiple files/attachments per document aren't handled
  yet.
- The Nuxeo path convention used for the live existence check has not been
  verified against the real server yet.
- The generated `PAT_DOC_LOG` insert only populates a minimal column set -
  confirm with your DBA whether other columns need real values.
- Existing target files are skipped, never overwritten.
- Log/report are local files (JSONL/CSV/TXT), not a database table.
- If it turns out Constrained Language Mode doesn't actually apply to you
  (or IT provides the `sqlcmd`/`SqlServer` module), a direct database
  connection could be added back in - deliberately not built in right now.
