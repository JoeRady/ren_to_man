<#
.SYNOPSIS
    Builds a human-readable text report from a ren_to_man copy-script JSONL log.

.DESCRIPTION
    Step 6, decoupled from the copy step: reads the JSONL log written by a
    script generated with New-RenToManCopyScript (or by Run-RenToMan.ps1
    -Execute) and writes a summary report. Needs no database connection.

.EXAMPLE
    .\Build-RenToManReport.ps1 -LogPath .\logs\copy_log_20260101_120000.jsonl
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $LogPath,
    [string] $ReportPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "Log file not found: $LogPath"
}
if (-not $ReportPath) {
    $ReportPath = [System.IO.Path]::ChangeExtension($LogPath, '.report.txt')
}

$records = Get-Content -LiteralPath $LogPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }

$counts = @{ copied = 0; skipped = 0; missing_source = 0; error = 0 }
foreach ($r in $records) {
    if ($counts.ContainsKey($r.status)) { $counts[$r.status]++ }
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('ren_to_man copy report')
$lines.Add("generated: $((Get-Date).ToString('o'))")
$lines.Add("source log: $LogPath")
$lines.Add('')
$lines.Add("total entries: $($records.Count)")
foreach ($status in 'copied', 'skipped', 'missing_source', 'error') {
    $lines.Add("  ${status}: $($counts[$status])")
}
$lines.Add('')

$problems = $records | Where-Object { $_.status -in @('missing_source', 'error') }
if ($problems) {
    $lines.Add('Details for missing/errored documents:')
    foreach ($r in $problems) {
        $lines.Add("  DOC_LOG_ID=$($r.doc_log_id) CASE_ID=$($r.case_id) status=$($r.status) message=$($r.message)")
    }
}
else {
    $lines.Add('No missing sources or errors.')
}

Set-Content -Path $ReportPath -Value ($lines -join "`r`n") -Encoding UTF8
Write-Host "Report written to: $ReportPath"
