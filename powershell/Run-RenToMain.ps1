<#
.SYNOPSIS
    Joins the two (or three) CSV exports from powershell/sql/ into a
    candidate document list, verifies each against Main-Live and Nuxeo, and
    (optionally) generates reviewable copy/insert scripts for them.

.DESCRIPTION
    This tool does NOT connect to SQL Server itself. Many corporate Windows
    machines run PowerShell under Constrained Language Mode (enforced by
    AppLocker/WDAC), which blocks the .NET types needed for direct SQL
    Server access (System.Data.SqlClient etc.) - so instead:

      1+2+3. Run powershell/sql/01_source_documents.sql (with your
             LoginId/CategoryId/FromDate/ToDate/SourceRoot :setvar values)
             against SQLSRV01\REN01 in SSMS (or another SQL client) and
             export the result grid as CSV.
             Run powershell/sql/02_case_mapping_and_target_paths.sql (with
             your TargetRoot :setvar value) against SQLSRV01\MAIN01 and
             export that result grid as CSV too (this one does not depend on
             the search filters and can be reused across runs).
      4.     This script joins those two CSVs, lists the resulting
             candidates (source path, DOC_LOG_ID, LOG_DATE, DOC_NAME,
             DOC_FILE_NAME, target path) to a new CSV.
      4.5    Optional but recommended: pass -MainLiveDocumentsCsvPath (export
             of powershell/sql/03_main_live_existing_documents.sql) to check
             each candidate against Main-Live's PAT_DOC_LOG and, live, against
             Nuxeo (see NuxeoBaseUrl/NuxeoRootPath), and decide per document:
                already in Main-Live + already in Nuxeo  -> nothing to do
                already in Main-Live, not in Nuxeo       -> copy the file
                in neither                               -> copy + new PAT_DOC_LOG row
                only in Nuxeo                            -> new PAT_DOC_LOG row only
             A Nuxeo check that can't be answered cleanly (network/auth
             error) never triggers an automatic action - it's flagged for
             manual review instead. Without -MainLiveDocumentsCsvPath, this
             step is skipped entirely and every candidate is treated as a
             plain copy, as before.
      5.     With -GenerateCopyScript: generates a standalone .ps1 file that
             does the actual copying (no database dependency, prompts for
             confirmation), and - if verification found documents that need
             a new PAT_DOC_LOG row - a standalone .sql file with the INSERT
             statements to review and run yourself in SSMS. Neither script
             is executed automatically.
      6.     After the copy script has run, use .\Build-RenToMainReport.ps1
             to build the report from its log.

    This script itself never touches the filesystem beyond writing its own
    CSV/script output, and never connects to any database (the live Nuxeo
    check, when enabled, is the only network call it makes itself).

.PARAMETER SourceDocumentsCsvPath
    CSV exported from powershell/sql/01_source_documents.sql.

.PARAMETER CaseMappingCsvPath
    CSV exported from powershell/sql/02_case_mapping_and_target_paths.sql.

.PARAMETER MainLiveDocumentsCsvPath
    CSV exported from powershell/sql/03_main_live_existing_documents.sql.
    Optional - when given, enables step 4.5 (Main-Live + Nuxeo verification).
    When omitted, every candidate is treated as a plain copy (pre-verification
    behaviour).

.PARAMETER NuxeoBaseUrl
    Base URL of the Nuxeo server, e.g. https://ndc-edms-01.corp.withersrogers.com/nuxeo.
    Only used when -MainLiveDocumentsCsvPath is given.

.PARAMETER NuxeoRootPath
    Root path in Nuxeo that mirrors the Patricia document root, e.g.
    \Workspaces\Patricia\Documents\. Only used when -MainLiveDocumentsCsvPath
    is given.

.PARAMETER NuxeoCredentialPath
    Where to cache the Nuxeo service account credential (encrypted via
    Export-Clixml/DPAPI - only readable by the same Windows user on the same
    machine). Prompts once via Get-Credential if the file doesn't exist yet.
    Default: .\RenToMain.nuxeo.credential.xml next to this script.

.PARAMETER NuxeoSkipCertificateCheck
    Skip TLS certificate validation for the Nuxeo REST call. Only use this
    if you understand the risk (e.g. a known internal cert issue) - default
    is to validate normally.

.PARAMETER ConfigPath
    Path to the config data file (default: .\RenToMain.config.psd1 next to
    this script).

.PARAMETER GenerateCopyScript
    Generate the standalone copy script (and, if applicable, the insert
    script) for step 5, alongside the candidate CSV. Without this switch,
    the run only lists candidates (steps 4/4.5).

.PARAMETER OutDir
    Directory to write the candidate CSV / generated scripts into (default:
    Logging.LogDir from the config file).

.EXAMPLE
    # Steps 1-4 only (no verification)
    .\Run-RenToMain.ps1 -SourceDocumentsCsvPath .\source_documents.csv `
        -CaseMappingCsvPath .\case_mapping.csv

.EXAMPLE
    # Steps 1-5 with Main-Live + Nuxeo verification
    .\Run-RenToMain.ps1 -SourceDocumentsCsvPath .\source_documents.csv `
        -CaseMappingCsvPath .\case_mapping.csv `
        -MainLiveDocumentsCsvPath .\main_live_documents.csv `
        -GenerateCopyScript
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceDocumentsCsvPath,
    [Parameter(Mandatory)][string] $CaseMappingCsvPath,

    [string] $MainLiveDocumentsCsvPath,
    [string] $NuxeoBaseUrl = 'https://ndc-edms-01.corp.withersrogers.com/nuxeo',
    [string] $NuxeoRootPath = '\Workspaces\Patricia\Documents\',
    [string] $NuxeoCredentialPath = (Join-Path $PSScriptRoot 'RenToMain.nuxeo.credential.xml'),
    [switch] $NuxeoSkipCertificateCheck,

    [string] $ConfigPath = (Join-Path $PSScriptRoot 'RenToMain.config.psd1'),
    [switch] $GenerateCopyScript,
    [string] $OutDir
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RenToMain.psd1') -Force

Write-Host 'Loading config...'
$cfg = Import-RenToMainConfig -Path $ConfigPath

$logDir = if ($OutDir) { $OutDir } else { $cfg.Logging.LogDir }
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

Write-Host "Joining $SourceDocumentsCsvPath and $CaseMappingCsvPath ..."
$plan = @(New-RenToMainPlanFromCsv -SourceDocumentsCsvPath $SourceDocumentsCsvPath -CaseMappingCsvPath $CaseMappingCsvPath)
Write-Host "  $($plan.Count) document(s) in the source CSV"

if ($MainLiveDocumentsCsvPath) {
    Write-Host ''
    Write-Host "Verifying against Main-Live ($MainLiveDocumentsCsvPath) and Nuxeo ($NuxeoBaseUrl) ..."
    $nuxeoCred = Get-RenToMainCredential -Path $NuxeoCredentialPath -Message 'Enter Nuxeo service account credentials'
    $plan = @(Add-RenToMainVerification -Plan $plan -MainLiveDocumentsCsvPath $MainLiveDocumentsCsvPath `
        -NuxeoBaseUrl $NuxeoBaseUrl -NuxeoRootPath $NuxeoRootPath -NuxeoCredential $nuxeoCred `
        -NuxeoSkipCertificateCheck:$NuxeoSkipCertificateCheck)

    $byAction = $plan | Group-Object -Property Action
    Write-Host '  Action breakdown:'
    foreach ($g in $byAction) {
        Write-Host "    $($g.Name): $($g.Count)"
    }
    $failedCount = @($plan | Where-Object { $_.Action -eq 'VerificationFailed' }).Count
    if ($failedCount -gt 0) {
        Write-Host ''
        Write-Host "  WARNING: $failedCount document(s) could not be verified against Nuxeo (network/auth error)." -ForegroundColor Yellow
        Write-Host '  These are excluded from both scripts - see SKIP_REASON in the candidate CSV and check them manually.' -ForegroundColor Yellow
    }
}
else {
    Write-Host ''
    Write-Host 'No -MainLiveDocumentsCsvPath given: skipping Main-Live/Nuxeo verification, treating every candidate as a plain copy.'
}

$planCsv = Join-Path $logDir "candidates_$runStamp.csv"
Write-RenToMainCandidateCsv -Plan $plan -Path $planCsv

$copyable = @($plan | Where-Object { Test-RenToMainCopyable $_ })
$needInsert = @($plan | Where-Object { Test-RenToMainInsertNeeded $_ })
$skipped = @($plan | Where-Object { (-not (Test-RenToMainCopyable $_)) -and (-not (Test-RenToMainInsertNeeded $_)) })

Write-Host ''
Write-Host "Candidate list written to: $planCsv"
Write-Host "  to copy: $($copyable.Count)"
Write-Host "  needing a new PAT_DOC_LOG row: $($needInsert.Count)"
Write-Host "  no action / skipped (see SKIP_REASON in CSV): $($skipped.Count)"
Write-Host ''
$plan | Select-Object -First 20 | ForEach-Object {
    $skipInfo = if ($_.SkipReason) { "SKIP: $($_.SkipReason)" } else { '' }
    $actionInfo = if ($_.Action) { "action=$($_.Action)" } else { '' }
    Write-Host "  [$($_.DocLogId)] $($_.LogDate) '$($_.DocName)' src=$($_.SourcePath) -> dst=$($_.TargetPath) $actionInfo $skipInfo"
}
if ($plan.Count -gt 20) {
    Write-Host "  ... and $($plan.Count - 20) more, see $planCsv"
}

if (-not $GenerateCopyScript) {
    Write-Host ''
    Write-Host 'Listing only (step 4/4.5) - no scripts were generated.'
    Write-Host 'Re-run with -GenerateCopyScript to generate the (database-independent) copy/insert scripts.'
    return
}

Write-Host ''
$copyScriptPath = Join-Path $logDir "copy_script_$runStamp.ps1"
$genResult = New-RenToMainCopyScript -Plan $plan -Path $copyScriptPath
Write-Host "Copy script generated: $($genResult.Path)"
Write-Host "  copy operations included: $($genResult.ItemCount)"

if ($needInsert.Count -gt 0) {
    $insertScriptPath = Join-Path $logDir "insert_script_$runStamp.sql"
    $insertResult = New-RenToMainInsertScript -Plan $plan -Path $insertScriptPath
    Write-Host "Insert script generated: $($insertResult.Path)"
    Write-Host "  PAT_DOC_LOG rows included: $($insertResult.RowCount)"
}

Write-Host ''
Write-Host 'Next steps:'
Write-Host "  1. Review the copy script's content: $copyScriptPath"
Write-Host "  2. Run it separately: $copyScriptPath"
if ($needInsert.Count -gt 0) {
    Write-Host "  3. Review the insert script's content: $insertScriptPath"
    Write-Host '  4. Run it yourself in SSMS against SQLSRV01\MAIN01 / Patricia_Main_Live'
    Write-Host '  5. Then build the report: .\Build-RenToMainReport.ps1 -LogPath <copy_log_....jsonl from step 2>'
}
else {
    Write-Host '  3. Then build the report: .\Build-RenToMainReport.ps1 -LogPath <copy_log_....jsonl from step 2>'
}
