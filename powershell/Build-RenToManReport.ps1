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
    $ReportPath = ($LogPath -replace '\.[^.\\/]+$', '') + '.report.txt'
}

$records = @(Get-Content -LiteralPath $LogPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })

$counts = @{ copied = 0; skipped = 0; missing_source = 0; error = 0 }
foreach ($r in $records) {
    if ($counts.ContainsKey($r.status)) { $counts[$r.status]++ }
}

$detailLines = @($records | Where-Object { $_.status -in @('missing_source', 'error') } | ForEach-Object {
    "  DOC_LOG_ID=$($_.doc_log_id) CASE_ID=$($_.case_id) status=$($_.status) message=$($_.message)"
})
$countLines = @('copied', 'skipped', 'missing_source', 'error') | ForEach-Object { "  ${_}: $($counts[$_])" }

$lines = @(
    'ren_to_man copy report'
    "generated: $((Get-Date).ToString('o'))"
    "source log: $LogPath"
    ''
    "total entries: $($records.Count)"
) + $countLines + @('')

if ($detailLines.Count -gt 0) {
    $lines = $lines + @('Details for missing/errored documents:') + $detailLines
}
else {
    $lines = $lines + @('No missing sources or errors.')
}

Set-Content -Path $ReportPath -Value ($lines -join "`r`n") -Encoding UTF8
Write-Host "Report written to: $ReportPath"
