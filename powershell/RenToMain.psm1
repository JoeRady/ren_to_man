#Requires -Version 5.1
Set-StrictMode -Version Latest

<#
    RenToMain.psm1

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
    generates a standalone copy script (step 5) - see New-RenToMainPlanFromCsv
    and New-RenToMainCopyScript, driven by Run-RenToMain.ps1.

    Filenames are handled as .NET strings (UTF-16) throughout, so umlauts and
    other non-ASCII characters in DOC_FILE_NAME are copied correctly without
    any manual encoding work.
#>

function Import-RenToMainConfig {
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

function Get-RenToMainCsvDelimiter {
    <#
        Auto-detects whether a CSV/TSV export uses ',' , ';' or a tab as the
        field separator, by counting each in the header line. SSMS's "Save
        Results As... CSV" follows the Windows regional "list separator"
        setting (';' on many non-English, e.g. German, locales rather than
        the US-default ','), while "Results to Text" / copying straight out
        of the grid produces tab-separated values instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $header = Get-Content -LiteralPath $Path -TotalCount 1
    $tabs = ($header -split "`t").Count - 1
    $semicolons = ($header -split ';').Count - 1
    $commas = ($header -split ',').Count - 1
    if ($tabs -ge $semicolons -and $tabs -ge $commas -and $tabs -gt 0) { return "`t" }
    if ($semicolons -gt $commas) { return ';' }
    return ','
}

function New-RenToMainPlanFromCsv {
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

    $sourceDocs = @(Import-Csv -LiteralPath $SourceDocumentsCsvPath -Delimiter (Get-RenToMainCsvDelimiter $SourceDocumentsCsvPath))
    $mappingRows = @(Import-Csv -LiteralPath $CaseMappingCsvPath -Delimiter (Get-RenToMainCsvDelimiter $CaseMappingCsvPath))

    $mappingByCaseId = @{}
    foreach ($m in $mappingRows) {
        # Rows where the Main-side case has no Renewals counterpart export as
        # a literal "NULL" (or blank) RENEWALS_CASE_ID - skip them, they can
        # never match a source document's CASE_ID.
        if ($m.RENEWALS_CASE_ID -and $m.RENEWALS_CASE_ID -ne 'NULL') {
            $mappingByCaseId[[string]$m.RENEWALS_CASE_ID] = $m
        }
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
            DocLogId          = $e.DOC_LOG_ID
            CaseId            = $e.CASE_ID
            MainCaseId        = $mainCaseId
            LoginId           = $e.LOGIN_ID
            LogDate           = $e.LOG_DATE
            DocType           = $e.DOC_TYPE
            DocName           = $e.DOC_NAME
            DocFileName       = $e.DOC_FILE_NAME
            CategoryId        = $e.CATEGORY_ID
            SourcePath        = $e.SOURCE_PATH
            TargetPath        = $targetPath
            SkipReason        = $skipReason
            # Carried through for Add-RenToMainVerification's Nuxeo path build
            # (kept separate from TARGET_FOLDER since that already has the
            # filesystem root baked in, which Nuxeo's root differs from).
            MainCaseTypeId    = if ($mapRow) { $mapRow.CASE_TYPE_ID } else { $null }
            MainCaseNumber    = if ($mapRow) { $mapRow.CASE_NUMBER } else { $null }
            MainCountry       = if ($mapRow) { $mapRow.COUNTRY } else { $null }
            MainExtension     = if ($mapRow) { $mapRow.CASE_NUMBER_EXTENSION } else { $null }
            ExistsInMainLive  = $null
            ExistsInNuxeo     = $null
            Action            = $null
        }
    }

    # -NoEnumerate is required here: without it, PowerShell streams the
    # array's elements individually through the pipeline, and if there is
    # exactly one element, the caller's variable ends up holding that single
    # object instead of a 1-element array (breaking .Count / [0] access).
    Write-Output -NoEnumerate @($plan)
}

function Get-RenToMainCredential {
    <#
        Loads a cached PSCredential from an encrypted file (Export-Clixml
        uses Windows DPAPI - the file is only decryptable by the same
        Windows user on the same machine), or prompts once via Get-Credential
        and caches it there for next time. Never stores a plaintext
        password.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Message = 'Enter Nuxeo service account credentials'
    )

    if (Test-Path -LiteralPath $Path) {
        return Import-Clixml -LiteralPath $Path
    }

    $cred = Get-Credential -Message $Message
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $cred | Export-Clixml -LiteralPath $Path
    return $cred
}

function Get-RenToMainNuxeoPath {
    <#
        Builds the Nuxeo document path for a planned item, mirroring the
        same <CaseType>/<FamilyNumber (6, zero-padded)>/<Country>/<Extension>
        convention used for the filesystem target path in
        sql/01_source_documents.sql / sql/02_case_mapping_and_target_paths.sql
        - keep this in sync if that convention ever changes.

        NOT yet verified against the real Nuxeo server - confirm this
        produces correct paths for a handful of known documents before
        relying on Test-RenToMainNuxeoDocumentExists's results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RootPath,
        [Parameter(Mandatory)] $Planned
    )

    $familyNumber = ([int]$Planned.MainCaseNumber).ToString().PadLeft(6, '0')
    $segments = @(
        ([int]$Planned.MainCaseTypeId).ToString()
        $familyNumber
        ([string]$Planned.MainCountry).Trim().ToUpperInvariant()
        ([string]$Planned.MainExtension).Trim()
        $Planned.DocFileName
    )
    $root = ($RootPath -replace '\\', '/').Trim('/')
    return $root + '/' + ($segments -join '/')
}

function Test-RenToMainNuxeoDocumentExists {
    <#
        Checks whether a document exists at a given path in Nuxeo, via the
        REST path-resolution endpoint: GET {BaseUrl}/api/v1/path/{path}.

        Returns $true / $false only on an unambiguous result (200 -> exists,
        404 -> does not exist). Any other outcome (auth failure, timeout,
        unexpected status, TLS error, ...) returns $null ("unknown") rather
        than guessing - a wrong "does not exist" here could cause a
        duplicate copy or a duplicate PAT_DOC_LOG entry in production, so
        callers must treat $null as "needs manual review", never as $false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $BaseUrl,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Credential,
        [switch] $SkipCertificateCheck
    )

    $segments = $Path.Trim('/') -split '/'
    $encodedSegments = foreach ($s in $segments) { [System.Uri]::EscapeDataString($s) }
    $url = $BaseUrl.TrimEnd('/') + '/api/v1/path/' + ($encodedSegments -join '/')

    $params = @{
        Uri         = $url
        Method      = 'Get'
        Credential  = $Credential
        ErrorAction = 'Stop'
    }
    if ($SkipCertificateCheck) { $params.SkipCertificateCheck = $true }

    try {
        $null = Invoke-RestMethod @params
        return $true
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -eq 404) { return $false }
        Write-Warning "Nuxeo check failed for '$Path' (treating as unknown, not as 'missing'): $($_.Exception.Message)"
        return $null
    }
}

function Add-RenToMainVerification {
    <#
        Step 4.5: for every planned copy, checks whether the document
        already exists (a) in Main-Live's PAT_DOC_LOG (via
        main_live_documents.csv, matched on MainCaseId + DocFileName) and
        (b) at the corresponding path in Nuxeo (live REST check), then
        decides the required Action:

            in Main-Live + in Nuxeo      -> NoAction        (nothing to do)
            in Main-Live + not in Nuxeo  -> CopyOnly         (copy the file)
            not in either                -> CopyAndInsert    (copy + new PAT_DOC_LOG row)
            only in Nuxeo                -> InsertOnly       (new PAT_DOC_LOG row only)

        A Nuxeo check that comes back "unknown" (network/auth error, not a
        clean 404) never leads to an automatic action - it becomes
        Action = 'VerificationFailed' and is excluded from both the copy
        script and the insert script, with SkipReason explaining why.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Plan,
        [Parameter(Mandatory)][string] $MainLiveDocumentsCsvPath,
        [Parameter(Mandatory)][string] $NuxeoBaseUrl,
        [Parameter(Mandatory)][string] $NuxeoRootPath,
        [Parameter(Mandatory)] $NuxeoCredential,
        [switch] $NuxeoSkipCertificateCheck
    )

    if (-not (Test-Path -LiteralPath $MainLiveDocumentsCsvPath)) {
        throw "Main-Live documents CSV not found: $MainLiveDocumentsCsvPath"
    }
    $existingRows = @(Import-Csv -LiteralPath $MainLiveDocumentsCsvPath -Delimiter (Get-RenToMainCsvDelimiter $MainLiveDocumentsCsvPath))
    $existingSet = @{}
    foreach ($r in $existingRows) {
        $existingSet["$($r.CASE_ID)|$($r.DOC_FILE_NAME)"] = $true
    }

    $result = foreach ($p in $Plan) {
        if ($p.SkipReason) {
            # Already unresolvable at the join stage (no mapping, empty
            # filename, ...) - nothing more to check.
            $p.Action = 'NoAction'
            $p
            continue
        }

        $existsInMainLive = $existingSet.ContainsKey("$($p.MainCaseId)|$($p.DocFileName)")
        $nuxeoPath = Get-RenToMainNuxeoPath -RootPath $NuxeoRootPath -Planned $p
        $existsInNuxeo = Test-RenToMainNuxeoDocumentExists -BaseUrl $NuxeoBaseUrl -Path $nuxeoPath `
            -Credential $NuxeoCredential -SkipCertificateCheck:$NuxeoSkipCertificateCheck

        $p.ExistsInMainLive = $existsInMainLive
        $p.ExistsInNuxeo = $existsInNuxeo

        if ($null -eq $existsInNuxeo) {
            $p.Action = 'VerificationFailed'
            $p.SkipReason = 'Nuxeo check inconclusive (network/auth error) - review manually'
        }
        elseif ($existsInMainLive -and $existsInNuxeo) {
            $p.Action = 'NoAction'
        }
        elseif ($existsInMainLive -and -not $existsInNuxeo) {
            $p.Action = 'CopyOnly'
        }
        elseif ((-not $existsInMainLive) -and (-not $existsInNuxeo)) {
            $p.Action = 'CopyAndInsert'
        }
        else {
            $p.Action = 'InsertOnly'
        }

        $p
    }

    Write-Output -NoEnumerate @($result)
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

function Test-RenToMainCopyable {
    <#
        With verification (Add-RenToMainVerification) applied, an item is
        copyable only if Action says so. Without verification (Action still
        $null - e.g. plain unit tests, or Run-RenToMain.ps1 called without
        the verification parameters), falls back to the pre-verification
        rule based on SkipReason/SourcePath/TargetPath.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Planned)
    if (Get-Member -InputObject $Planned -Name 'Action' -ErrorAction SilentlyContinue) {
        if ($Planned.Action) {
            return $Planned.Action -in @('CopyOnly', 'CopyAndInsert')
        }
    }
    return (-not $Planned.SkipReason) -and $Planned.SourcePath -and $Planned.TargetPath
}

function Test-RenToMainInsertNeeded {
    <# True if this item needs a new PAT_DOC_LOG row created on Main-Live. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Planned)
    if (Get-Member -InputObject $Planned -Name 'Action' -ErrorAction SilentlyContinue) {
        return $Planned.Action -in @('CopyAndInsert', 'InsertOnly')
    }
    return $false
}

function ConvertTo-RenToMainPsStringLiteral {
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

function New-RenToMainCopyScript {
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

    $copyable = @($Plan | Where-Object { Test-RenToMainCopyable $_ })
    $skippedAtPlanning = @($Plan | Where-Object { -not (Test-RenToMainCopyable $_) })

    $itemLines = foreach ($p in $copyable) {
        $srcLit = ConvertTo-RenToMainPsStringLiteral $p.SourcePath
        $dstLit = ConvertTo-RenToMainPsStringLiteral $p.TargetPath
        "    [pscustomobject]@{ DocLogId = $($p.DocLogId); CaseId = $($p.CaseId); Source = $srcLit; Target = $dstLit }"
    }

    $lines = @(
        '<#'
        "    Generated by ren_to_main on $((Get-Date).ToString('o'))"
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
        'Write-Host "This script would copy $($Items.Count) file(s)."'
        'if (-not $Force) {'
        '    $answer = Read-Host "Type YES to continue (anything else aborts)"'
        '    if ($answer -ne "YES") { Write-Host "Aborted."; return }'
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
        'Write-Host "For a text report: .\Build-RenToMainReport.ps1 -LogPath `"$logPath`""'
    )

    Set-Content -Path $Path -Value ($lines -join "`r`n") -Encoding UTF8
    return [pscustomobject]@{ Path = $Path; ItemCount = $copyable.Count; SkippedAtPlanning = $skippedAtPlanning.Count }
}

function Write-RenToMainCandidateCsv {
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
        @{N = 'EXISTS_IN_MAIN_LIVE'; E = { $_.ExistsInMainLive } },
        @{N = 'EXISTS_IN_NUXEO'; E = { $_.ExistsInNuxeo } },
        @{N = 'ACTION'; E = { $_.Action } },
        @{N = 'SKIP_REASON'; E = { $_.SkipReason } } |
        Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function ConvertTo-RenToMainSqlStringLiteral {
    <# Safely embed a string as a SQL Server NVARCHAR literal (or the bare
       keyword NULL for $null/empty), for the generated INSERT script. #>
    [CmdletBinding()]
    param([AllowNull()] $Value)
    if ($null -eq $Value -or $Value -eq '') { return 'NULL' }
    $text = [string]$Value
    return "N'" + ($text -replace "'", "''") + "'"
}

function New-RenToMainInsertScript {
    <#
        Generates a standalone, reviewable .sql file with INSERT statements
        for every planned item whose Action is CopyAndInsert or InsertOnly
        (see Add-RenToMainVerification) - i.e. documents that need a new
        PAT_DOC_LOG row created on the Main-Live instance.

        This only WRITES the .sql file - nothing is executed against any
        database. Run the generated script yourself (e.g. in SSMS) after
        reviewing it, consistent with how New-RenToMainCopyScript never
        copies anything itself either.

        Only a minimal, best-effort set of columns is populated
        (CASE_ID, LOGIN_ID, LOG_DATE, DOC_TYPE, DOC_NAME, DOC_FILE_NAME,
        CATEGORY_ID) - DOC_LOG_ID is left out entirely so SQL Server assigns
        it (assumed IDENTITY column). PAT_DOC_LOG has many more (mostly
        nullable) columns not populated here (ACTOR_ID, CONTACT_ID,
        DOC_LOG_ORIGIN, ...) - review with your DBA whether any of those
        need real values for these rows to behave correctly in Patricia.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Plan,
        [Parameter(Mandatory)][string] $Path
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $needInsert = @($Plan | Where-Object { Test-RenToMainInsertNeeded $_ })

    $insertLines = foreach ($p in $needInsert) {
        $caseId = ConvertTo-RenToMainSqlStringLiteral $p.MainCaseId
        $loginId = ConvertTo-RenToMainSqlStringLiteral $p.LoginId
        $logDate = if ($p.LogDate) { "N'" + ($p.LogDate -replace "'", "''") + "'" } else { 'NULL' }
        $docType = ConvertTo-RenToMainSqlStringLiteral $p.DocType
        $docName = ConvertTo-RenToMainSqlStringLiteral $p.DocName
        $docFileName = ConvertTo-RenToMainSqlStringLiteral $p.DocFileName
        $categoryId = ConvertTo-RenToMainSqlStringLiteral $p.CategoryId
        "-- DOC_LOG_ID (Renewals source) = $($p.DocLogId), Action = $($p.Action)"
        "INSERT INTO dbo.PAT_DOC_LOG (CASE_ID, LOGIN_ID, LOG_DATE, DOC_TYPE, DOC_NAME, DOC_FILE_NAME, CATEGORY_ID)"
        "VALUES ($caseId, $loginId, $logDate, $docType, $docName, $docFileName, $categoryId);"
        ""
    }

    $lines = @(
        '/*'
        "    Generated by RenToMain on $((Get-Date).ToString('o'))"
        "    Rows to insert: $($needInsert.Count)"
        ''
        '    Review before running. Run against SQLSRV01\MAIN01, database Patricia_Main_Live'
        '    (same instance as sql/02_case_mapping_and_target_paths.sql).'
        ''
        '    Only a minimal column set is populated (see New-RenToMainInsertScript'
        '    doc comment in RenToMain.psm1) - PAT_DOC_LOG has further nullable'
        '    columns not set here. Confirm with your DBA whether any of those need'
        '    real values before running this against production.'
        '*/'
        ''
    ) + $insertLines

    Set-Content -Path $Path -Value ($lines -join "`r`n") -Encoding UTF8
    return [pscustomobject]@{ Path = $Path; RowCount = $needInsert.Count }
}

Export-ModuleMember -Function *
