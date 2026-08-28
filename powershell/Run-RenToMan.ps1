<#
.SYNOPSIS
    Copies Patricia documents from the Renewals instance to the Main instance.

.DESCRIPTION
    Implements steps 1-6:
      1. Filter by -LoginId and/or -CategoryId (at least one required)
      2. Date range -FromDate / -ToDate
      3. -TargetRoot for the destination document store
      4. Lists the found documents (source path, DOC_LOG_ID, LOG_DATE, DOC_NAME,
         DOC_FILE_NAME, target path) to a CSV - this always happens (dry run
         by default)
      5. With -Execute: copies the files, creating target folders as needed,
         handling non-ASCII (umlaut) filenames correctly
      6. With -Execute: writes a JSONL run log and a text report

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

.PARAMETER Execute
    Actually copy files. Without this switch, only lists candidates (dry run).

.PARAMETER OutDir
    Directory to write the candidate CSV / log / report into (default:
    Logging.LogDir from the config file).

.EXAMPLE
    # Steps 1-4 only (dry run / listing)
    .\Run-RenToMan.ps1 -LoginId jsmith -FromDate 2026-01-01 -ToDate 2026-06-30 `
        -TargetRoot '\\brimain\Main\Patricia\documents'

.EXAMPLE
    # Steps 1-6, actually copying files
    .\Run-RenToMan.ps1 -LoginId jsmith -FromDate 2026-01-01 -ToDate 2026-06-30 `
        -TargetRoot '\\brimain\Main\Patricia\documents' -Execute
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
    [switch] $Execute,
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

Write-Host 'Connecting to source instance (Renewals) and querying PAT_DOC_LOG...'
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

Write-Host 'Connecting to target instance (Main): case-id mapping + target case data...'
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

if (-not $Execute) {
    Write-Host ''
    Write-Host 'Dry run only - no files were copied. Re-run with -Execute to copy.'
    return
}

Write-Host ''
Write-Host "Copying $($copyable.Count) file(s)..."
$results = $plan | ForEach-Object { Copy-RenToManDocument -Planned $_ }

$runLog = Join-Path $logDir "run_$runStamp.jsonl"
$report = Join-Path $logDir "report_$runStamp.txt"
Write-RenToManRunLog -Results $results -Path $runLog
Write-RenToManReport -Results $results -Path $report

Write-Host "Log written to: $runLog"
Write-Host "Report written to: $report"
