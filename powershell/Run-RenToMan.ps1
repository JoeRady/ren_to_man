<#
.SYNOPSIS
    Finds Patricia documents to copy from the Renewals instance to the Main
    instance and generates a reviewable copy script for them.

.DESCRIPTION
    Implements steps 1-4 and prepares step 5-6:
      1. Filter by -LoginId and/or -CategoryId (at least one required)
      2. Date range -FromDate / -ToDate
      3. -TargetRoot for the destination document store
      4. Lists the found documents (source path, DOC_LOG_ID, LOG_DATE, DOC_NAME,
         DOC_FILE_NAME, target path) to a CSV - this always happens and is a
         pure read-only query (only SELECT statements against the database)

    This script never touches the filesystem beyond writing its own CSV/log
    output, and never issues anything but SELECT statements against SQL
    Server. It does NOT copy any documents itself.

    Instead, with -GenerateCopyScript it produces a second, standalone .ps1
    file that does the actual copying (step 5). That generated script has NO
    database dependency at all - it only needs filesystem read/write access
    to the paths it lists - so you (or whoever runs it) can open and review
    it first, and run it separately, possibly at a different time or under a
    different account. It prompts for confirmation before copying anything
    unless run with -Force, and writes its own JSONL log.

    For step 6 (report), run .\Build-RenToManReport.ps1 -LogPath <that log>
    after the copy script has run.

.PARAMETER LoginId
    Filter PAT_DOC_LOG.LOGIN_ID. Combine with -CategoryId or use alone.

.PARAMETER CategoryId
    Filter PAT_DOC_LOG.CATEGORY_ID. Combine with -LoginId or use alone.

.PARAMETER FromDate
    Start of the date range (inclusive), e.g. '2026-01-01'.

.PARAMETER ToDate
    End of the date range (inclusive), e.g. '2026-06-30'.

.PARAMETER TargetRoot
    Root folder of the target (Main) document store, e.g. a UNC path.
    Must be given on every run.

.PARAMETER SourceRoot
    Overrides Paths.SourceRoot from the config file for this run.

.PARAMETER ConfigPath
    Path to the config data file (default: .\RenToMan.config.psd1 next to
    this script).

.PARAMETER GenerateCopyScript
    Generate the standalone copy script (step 5) alongside the candidate CSV.
    Without this switch, the run only lists candidates (step 4) - nothing is
    prepared for copying yet.

.PARAMETER OutDir
    Directory to write the candidate CSV / generated copy script into
    (default: Logging.LogDir from the config file).

.EXAMPLE
    # Steps 1-4 only: list candidates, review the CSV
    .\Run-RenToMan.ps1 -LoginId jsmith -FromDate 2026-01-01 -ToDate 2026-06-30 `
        -TargetRoot '\\brimain\Main\Patricia\documents'

.EXAMPLE
    # Steps 1-4 + generate the copy script for step 5
    .\Run-RenToMan.ps1 -LoginId jsmith -FromDate 2026-01-01 -ToDate 2026-06-30 `
        -TargetRoot '\\brimain\Main\Patricia\documents' -GenerateCopyScript
    # ... review logs\copy_script_<timestamp>.ps1, then run it separately:
    .\logs\copy_script_<timestamp>.ps1
    # ... then build the report (step 6):
    .\Build-RenToManReport.ps1 -LogPath .\logs\copy_log_<timestamp>.jsonl
#>
[CmdletBinding()]
param(
    [string] $LoginId,
    [Nullable[int]] $CategoryId,

    [Parameter(Mandatory)][datetime] $FromDate,
    [Parameter(Mandatory)][datetime] $ToDate,
    [Parameter(Mandatory)][string] $TargetRoot,

    [string] $SourceRoot,
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'RenToMan.config.psd1'),
    [switch] $GenerateCopyScript,
    [string] $OutDir
)

$ErrorActionPreference = 'Stop'

if (-not $LoginId -and -not $PSBoundParameters.ContainsKey('CategoryId')) {
    throw 'Provide at least one of -LoginId / -CategoryId.'
}

Import-Module (Join-Path $PSScriptRoot 'RenToMan.psd1') -Force

Write-Host 'Loading config...'
$cfg = Import-RenToManConfig -Path $ConfigPath

$effectiveSourceRoot = if ($SourceRoot) { $SourceRoot } else { $cfg.Paths.SourceRoot }
$logDir = if ($OutDir) { $OutDir } else { $cfg.Logging.LogDir }
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

Write-Host 'Connecting to source instance (Renewals) and querying PAT_DOC_LOG (read-only: SELECT only)...'
$renConn = New-RenToManSqlConnection -DbConfig $cfg.Databases.Renewals
try {
    $entries = Get-SourceDocLogEntries -Connection $renConn -LoginId $LoginId -CategoryId $CategoryId -FromDate $FromDate -ToDate $ToDate
    Write-Host "  found $($entries.Count) document(s)"

    $sourceCaseIds = @($entries | ForEach-Object { [int]$_.CASE_ID } | Sort-Object -Unique)
    Write-Host 'Querying source case data (PAT_CASE)...'
    $sourceCases = Get-CaseInfo -Connection $renConn -CaseIds $sourceCaseIds
}
finally {
    $renConn.Close()
}

Write-Host 'Connecting to target instance (Main): case-id mapping + target case data (read-only: SELECT only)...'
$mainConn = New-RenToManSqlConnection -DbConfig $cfg.Databases.Main
try {
    $caseIdMap = Get-CaseIdMapping -Connection $mainConn -RenewalsCaseIds $sourceCaseIds
    $mainCaseIds = @($caseIdMap.Values | Sort-Object -Unique)
    $targetCases = Get-CaseInfo -Connection $mainConn -CaseIds $mainCaseIds
}
finally {
    $mainConn.Close()
}

$plan = New-RenToManPlan -Entries $entries -SourceCases $sourceCases -CaseIdMap $caseIdMap `
    -TargetCases $targetCases -SourceRoot $effectiveSourceRoot -TargetRoot $TargetRoot `
    -FolderFormat $cfg.FolderFormat

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
    Write-Host 'Nur Auflistung (Schritt 1-4) - es wurde nichts kopiert und kein Kopierskript erzeugt.'
    Write-Host 'Erneut mit -GenerateCopyScript aufrufen, um das (DB-unabhaengige) Kopierskript zu erzeugen.'
    return
}

$copyScriptPath = Join-Path $logDir "copy_script_$runStamp.ps1"
$genResult = New-RenToManCopyScript -Plan $plan -Path $copyScriptPath

Write-Host ''
Write-Host "Kopierskript erzeugt: $($genResult.Path)"
Write-Host "  enthaltene Kopiervorgaenge: $($genResult.ItemCount)"
Write-Host ''
Write-Host 'Dieses Werkzeug hat NICHTS kopiert und benoetigt ab hier keine Datenbankverbindung mehr.'
Write-Host 'Naechste Schritte:'
Write-Host "  1. Skript inhaltlich pruefen: $copyScriptPath"
Write-Host "  2. Separat ausfuehren: $copyScriptPath"
Write-Host '  3. Danach Report erzeugen: .\Build-RenToManReport.ps1 -LogPath <copy_log_....jsonl aus Schritt 2>'
