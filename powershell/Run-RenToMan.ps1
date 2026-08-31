<#
.SYNOPSIS
    Joins the two CSV exports from powershell/sql/ into a candidate document
    list and (optionally) generates a reviewable copy script for them.

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
      4.     This script (Run-RenToMan.ps1) joins those two CSVs, lists the
             resulting candidates (source path, DOC_LOG_ID, LOG_DATE,
             DOC_NAME, DOC_FILE_NAME, target path) to a new CSV.
      5.     With -GenerateCopyScript: generates a second, standalone .ps1
             file that does the actual copying. That script has NO database
             dependency and needs only filesystem access, so it can be
             reviewed before running, and prompts for confirmation.
      6.     After the copy script has run, use .\Build-RenToManReport.ps1
             to build the report from its log.

    This script itself never touches the filesystem beyond writing its own
    CSV/script output, and never connects to any database.

.PARAMETER SourceDocumentsCsvPath
    CSV exported from powershell/sql/01_source_documents.sql.

.PARAMETER CaseMappingCsvPath
    CSV exported from powershell/sql/02_case_mapping_and_target_paths.sql.

.PARAMETER ConfigPath
    Path to the config data file (default: .\RenToMan.config.psd1 next to
    this script).

.PARAMETER GenerateCopyScript
    Generate the standalone copy script (step 5) alongside the candidate CSV.
    Without this switch, the run only lists candidates (step 4).

.PARAMETER OutDir
    Directory to write the candidate CSV / generated copy script into
    (default: Logging.LogDir from the config file).

.EXAMPLE
    .\Run-RenToMan.ps1 -SourceDocumentsCsvPath .\source_documents.csv `
        -CaseMappingCsvPath .\case_mapping.csv -GenerateCopyScript
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceDocumentsCsvPath,
    [Parameter(Mandatory)][string] $CaseMappingCsvPath,

    [string] $ConfigPath = (Join-Path $PSScriptRoot 'RenToMan.config.psd1'),
    [switch] $GenerateCopyScript,
    [string] $OutDir
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RenToMan.psd1') -Force

Write-Host 'Loading config...'
$cfg = Import-RenToManConfig -Path $ConfigPath

$logDir = if ($OutDir) { $OutDir } else { $cfg.Logging.LogDir }
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

Write-Host "Joining $SourceDocumentsCsvPath and $CaseMappingCsvPath ..."
$plan = @(New-RenToManPlanFromCsv -SourceDocumentsCsvPath $SourceDocumentsCsvPath -CaseMappingCsvPath $CaseMappingCsvPath)
Write-Host "  $($plan.Count) document(s) in the source CSV"

$planCsv = Join-Path $logDir "candidates_$runStamp.csv"
Write-RenToManCandidateCsv -Plan $plan -Path $planCsv

$copyable = @($plan | Where-Object { Test-RenToManCopyable $_ })
$skipped = @($plan | Where-Object { -not (Test-RenToManCopyable $_) })

Write-Host ''
Write-Host "Candidate list written to: $planCsv"
Write-Host "  copyable: $($copyable.Count)"
Write-Host "  skipped (see SKIP_REASON in CSV): $($skipped.Count)"
Write-Host ''
$plan | Select-Object -First 20 | ForEach-Object {
    $skipInfo = if ($_.SkipReason) { "SKIP: $($_.SkipReason)" } else { '' }
    Write-Host "  [$($_.DocLogId)] $($_.LogDate) '$($_.DocName)' src=$($_.SourcePath) -> dst=$($_.TargetPath) $skipInfo"
}
if ($plan.Count -gt 20) {
    Write-Host "  ... and $($plan.Count - 20) more, see $planCsv"
}

if (-not $GenerateCopyScript) {
    Write-Host ''
    Write-Host 'Nur Auflistung (Schritt 4) - es wurde kein Kopierskript erzeugt.'
    Write-Host 'Erneut mit -GenerateCopyScript aufrufen, um das (DB-unabhaengige) Kopierskript zu erzeugen.'
    return
}

$copyScriptPath = Join-Path $logDir "copy_script_$runStamp.ps1"
$genResult = New-RenToManCopyScript -Plan $plan -Path $copyScriptPath

Write-Host ''
Write-Host "Kopierskript erzeugt: $($genResult.Path)"
Write-Host "  enthaltene Kopiervorgaenge: $($genResult.ItemCount)"
Write-Host ''
Write-Host 'Naechste Schritte:'
Write-Host "  1. Skript inhaltlich pruefen: $copyScriptPath"
Write-Host "  2. Separat ausfuehren: $copyScriptPath"
Write-Host '  3. Danach Report erzeugen: .\Build-RenToManReport.ps1 -LogPath <copy_log_....jsonl aus Schritt 2>'
