#Requires -Version 5.1
Set-StrictMode -Version Latest

<#
    RenToMan.psm1

    Finds Patricia documents to copy from the Renewals instance to the Main
    instance and prepares (but does not itself perform) the actual copy.

    IMPORTANT - PowerShell Constrained Language Mode:
    Many corporate Windows machines run PowerShell under Constrained Language
    Mode (enforced by AppLocker/WDAC), which blocks method calls on
    non-"core" .NET types (this includes System.Data.SqlClient,
    System.Text.StringBuilder, and generic collections). Because of that,
    this module does NOT talk to SQL Server directly at all - it only uses
    core types (strings, arrays, hashtables, PSCustomObjects) and built-in
    cmdlets (Import-Csv, Export-Csv, ConvertTo-Json, Test-Path, Copy-Item,
    ...), all of which work fine under Constrained Language Mode.

    Instead, the SQL queries (see ../sql/*.sql) are run separately, e.g. in
    SQL Server Management Studio, and their results exported as CSV. This
    module reads those CSVs, joins them, builds source/target paths, and
    generates a standalone copy script (step 5) - see New-RenToManPlanFromCsv
    and New-RenToManCopyScript, driven by Run-RenToMan.ps1.

    Filenames are handled as .NET strings (UTF-16) throughout, so umlauts and
    other non-ASCII characters in DOC_FILE_NAME are copied correctly without
    any manual encoding work.
#>

function Import-RenToManConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }
    $cfg = Import-PowerShellDataFile -Path $Path
    if (-not $cfg.ContainsKey('Logging')) {
        throw "Config file '$Path' is missing required section 'Logging'."
    }
    return $cfg
}

function New-RenToManPlanFromCsv {
    <#
        Step 4: join the two CSV exports (source documents with SOURCE_PATH
        already computed by sql/01_source_documents.sql, and case mapping
        with TARGET_FOLDER already computed by
        sql/02_case_mapping_and_target_paths.sql) into a flat list of planned
        copies, each with SourcePath / TargetPath / SkipReason.

        Both CSVs are read with Import-Csv - no database connection, no
        method calls on non-core types, so this works under Constrained
        Language Mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SourceDocumentsCsvPath,
        [Parameter(Mandatory)][string] $CaseMappingCsvPath
    )

    if (-not (Test-Path -LiteralPath $SourceDocumentsCsvPath)) {
        throw "Source documents CSV not found: $SourceDocumentsCsvPath"
    }
    if (-not (Test-Path -LiteralPath $CaseMappingCsvPath)) {
        throw "Case mapping CSV not found: $CaseMappingCsvPath"
    }

    $sourceDocs = @(Import-Csv -LiteralPath $SourceDocumentsCsvPath)
    $mappingRows = @(Import-Csv -LiteralPath $CaseMappingCsvPath)

    $mappingByCaseId = @{}
    foreach ($m in $mappingRows) {
        $mappingByCaseId[[string]$m.RENEWALS_CASE_ID] = $m
    }

    $plan = foreach ($e in $sourceDocs) {
        $caseId = [string]$e.CASE_ID
        $mapRow = $mappingByCaseId[$caseId]

        if (-not $mapRow) {
            $mainCaseId = $null
            $targetPath = $null
            $skipReason = 'no mapping in wr_Renewals_vs_Main_Live (case_mapping.csv)'
        }
        elseif (-not $e.DOC_FILE_NAME) {
            $mainCaseId = $mapRow.MAIN_LIVE_CASE_ID
            $targetPath = $null
            $skipReason = 'DOC_FILE_NAME is empty'
        }
        else {
            $mainCaseId = $mapRow.MAIN_LIVE_CASE_ID
            $targetPath = Join-Path $mapRow.TARGET_FOLDER $e.DOC_FILE_NAME
            $skipReason = $null
        }

        [pscustomobject]@{
            DocLogId    = $e.DOC_LOG_ID
            CaseId      = $e.CASE_ID
            MainCaseId  = $mainCaseId
            LogDate     = $e.LOG_DATE
            DocName     = $e.DOC_NAME
            DocFileName = $e.DOC_FILE_NAME
            SourcePath  = $e.SOURCE_PATH
            TargetPath  = $targetPath
            SkipReason  = $skipReason
        }
    }

    # -NoEnumerate is required here: without it, PowerShell streams the
    # array's elements individually through the pipeline, and if there is
    # exactly one element, the caller's variable ends up holding that single
    # object instead of a 1-element array (breaking .Count / [0] access).
    Write-Output -NoEnumerate @($plan)
}

function Get-LongPath {
    <# Prefix very long / UNC paths with \\?\ so filesystem calls don't hit MAX_PATH. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.TrimStart('\') }
    if ($Path.Length -lt 240) { return $Path }
    return '\\?\' + $Path
}

function Test-RenToManCopyable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Planned)
    return (-not $Planned.SkipReason) -and $Planned.SourcePath -and $Planned.TargetPath
}

function ConvertTo-RenToManPsStringLiteral {
    <# Safely embed an arbitrary string (umlauts, quotes, backslashes - all fine)
       as a single-quoted PowerShell literal in generated script text.
       Uses only the -replace operator and string concatenation (+), both
       fine under Constrained Language Mode. #>
    [CmdletBinding()]
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return '$null' }
    $text = [string]$Value
    return "'" + ($text -replace "'", "''") + "'"
}

function New-RenToManCopyScript {
    <#
        Step 5: instead of copying files directly, generate a standalone,
        human-reviewable .ps1 script that does the copying. This script has
        NO database dependency at all - only filesystem read/write access to
        the paths it lists is needed to run it, and it can be reviewed (or
        handed to someone else) before anything is touched.

        Builds the script text as a plain string array (+ -join), not
        System.Text.StringBuilder, so this works under Constrained Language
        Mode too (StringBuilder method calls are blocked there).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Plan,
        [Parameter(Mandatory)][string] $Path
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $copyable = @($Plan | Where-Object { Test-RenToManCopyable $_ })
    $skippedAtPlanning = @($Plan | Where-Object { -not (Test-RenToManCopyable $_) })

    $itemLines = foreach ($p in $copyable) {
        $srcLit = ConvertTo-RenToManPsStringLiteral $p.SourcePath
        $dstLit = ConvertTo-RenToManPsStringLiteral $p.TargetPath
        "    [pscustomobject]@{ DocLogId = $($p.DocLogId); CaseId = $($p.CaseId); Source = $srcLit; Target = $dstLit }"
    }

    $lines = @(
        '<#'
        "    Generated by ren_to_man on $((Get-Date).ToString('o'))"
        "    Items to copy: $($copyable.Count)   Skipped already at planning time (not included below): $($skippedAtPlanning.Count)"
        ''
        '    This script is self-contained: it needs NO database connection, only'
        '    filesystem read access to the sources and write access to the targets'
        '    listed below. Review the $Items list before running.'
        '    Creates missing target folders. Skips a file if the target already exists'
        '    (never overwrites). Writes its own JSONL log next to itself.'
        '#>'
        '[CmdletBinding()]'
        'param('
        '    [switch] $Force   # skip the confirmation prompt'
        ')'
        ''
        "`$ErrorActionPreference = 'Stop'"
        ''
        'function Get-LongPath {'
        '    param([string] $Path)'
        "    if (`$Path.StartsWith('\\?\')) { return `$Path }"
        "    if (`$Path.StartsWith('\\')) { return '\\?\UNC\' + `$Path.TrimStart('\') }"
        '    if ($Path.Length -lt 240) { return $Path }'
        "    return '\\?\' + `$Path"
        '}'
        ''
        '$Items = @('
    ) + $itemLines + @(
        ')'
        ''
        'Write-Host "Dieses Skript wuerde $($Items.Count) Datei(en) kopieren."'
        'if (-not $Force) {'
        '    $answer = Read-Host "Zum Fortfahren JA eingeben (sonst Abbruch)"'
        '    if ($answer -ne "JA") { Write-Host "Abgebrochen."; return }'
        '}'
        ''
        '$logPath = Join-Path $PSScriptRoot ("copy_log_" + (Get-Date -Format ' + "'yyyyMMdd_HHmmss'" + ') + ".jsonl")'
        '$copied = 0; $skipped = 0; $missing = 0; $errors = 0'
        ''
        'foreach ($item in $Items) {'
        '    $status = $null; $message = ""'
        '    $srcLong = Get-LongPath $item.Source'
        '    $dstLong = Get-LongPath $item.Target'
        '    try {'
        '        if (-not (Test-Path -LiteralPath $srcLong)) {'
        '            $status = "missing_source"; $message = "source file not found: $($item.Source)"; $missing++'
        '        } elseif (Test-Path -LiteralPath $dstLong) {'
        '            $status = "skipped"; $message = "target already exists: $($item.Target)"; $skipped++'
        '        } else {'
        '            $dstDir = Split-Path -Path $dstLong -Parent'
        '            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }'
        '            Copy-Item -LiteralPath $srcLong -Destination $dstLong -Force'
        '            $status = "copied"; $copied++'
        '        }'
        '    } catch {'
        '        $status = "error"; $message = $_.Exception.Message; $errors++'
        '    }'
        '    Write-Host "[$($item.DocLogId)] $status $message"'
        '    $record = [ordered]@{'
        '        timestamp   = (Get-Date).ToString("o")'
        '        doc_log_id  = $item.DocLogId'
        '        case_id     = $item.CaseId'
        '        source_path = $item.Source'
        '        target_path = $item.Target'
        '        status      = $status'
        '        message     = $message'
        '    }'
        '    ($record | ConvertTo-Json -Compress) | Add-Content -Path $logPath -Encoding UTF8'
        '}'
        ''
        'Write-Host ""'
        'Write-Host "copied=$copied skipped=$skipped missing_source=$missing error=$errors"'
        'Write-Host "Log: $logPath"'
        'Write-Host "Fuer einen Textreport: .\Build-RenToManReport.ps1 -LogPath `"$logPath`""'
    )

    Set-Content -Path $Path -Value ($lines -join "`r`n") -Encoding UTF8
    return [pscustomobject]@{ Path = $Path; ItemCount = $copyable.Count; SkippedAtPlanning = $skippedAtPlanning.Count }
}

function Write-RenToManCandidateCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Plan,
        [Parameter(Mandatory)][string] $Path
    )
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $Plan | Select-Object `
        @{N = 'DOC_LOG_ID'; E = { $_.DocLogId } },
        @{N = 'CASE_ID'; E = { $_.CaseId } },
        @{N = 'MAIN_CASE_ID'; E = { $_.MainCaseId } },
        @{N = 'LOG_DATE'; E = { $_.LogDate } },
        @{N = 'DOC_NAME'; E = { $_.DocName } },
        @{N = 'DOC_FILE_NAME'; E = { $_.DocFileName } },
        @{N = 'SOURCE_PATH'; E = { $_.SourcePath } },
        @{N = 'TARGET_PATH'; E = { $_.TargetPath } },
        @{N = 'SKIP_REASON'; E = { $_.SkipReason } } |
        Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

Export-ModuleMember -Function *
