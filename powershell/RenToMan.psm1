#Requires -Version 5.1
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue

<#
    RenToMan.psm1

    Copies Patricia documents from the Renewals instance to the Main
    instance. Uses System.Data.SqlClient (part of the .NET Framework that
    ships with Windows PowerShell 5.1 - no extra module install needed).
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
    foreach ($key in 'Databases', 'Paths', 'FolderFormat', 'Logging') {
        if (-not $cfg.ContainsKey($key)) {
            throw "Config file '$Path' is missing required section '$key'."
        }
    }
    foreach ($dbKey in 'Renewals', 'Main') {
        if (-not $cfg.Databases.ContainsKey($dbKey)) {
            throw "Config file '$Path' is missing Databases.$dbKey."
        }
    }
    return $cfg
}

function New-RenToManSqlConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $DbConfig
    )
    Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Server']   = $DbConfig.Server
    $builder['Database'] = $DbConfig.Database

    if ($DbConfig.ContainsKey('IntegratedSecurity') -and -not $DbConfig.IntegratedSecurity) {
        $builder['User ID']  = $DbConfig.UserId
        $builder['Password'] = $DbConfig.Password
    }
    else {
        $builder['Integrated Security'] = $true
    }

    $conn = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    $conn.Open()
    return $conn
}

function Invoke-RenToManQuery {
    <#
        Runs $Sql against $Connection with the given $Parameters hashtable
        (@{ ParamName = value }) and returns an array of PSCustomObject, one
        per row.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)][string] $Sql,
        [hashtable] $Parameters = @{}
    )

    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = 120
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($null -eq $value) { $value = [DBNull]::Value }
        [void]$cmd.Parameters.AddWithValue("@$key", $value)
    }

    $reader = $cmd.ExecuteReader()
    try {
        $columns = 0..($reader.FieldCount - 1) | ForEach-Object { $reader.GetName($_) }
        $rows = New-Object System.Collections.Generic.List[object]
        while ($reader.Read()) {
            $row = [ordered]@{}
            foreach ($col in $columns) {
                $val = $reader[$col]
                if ($val -is [DBNull]) { $val = $null }
                $row[$col] = $val
            }
            $rows.Add([pscustomobject]$row)
        }
        return $rows.ToArray()
    }
    finally {
        $reader.Close()
    }
}

function Get-SourceDocLogEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [string] $LoginId,
        [Nullable[int]] $CategoryId,
        [Parameter(Mandatory)][datetime] $FromDate,
        [Parameter(Mandatory)][datetime] $ToDate
    )

    $conditions = New-Object System.Collections.Generic.List[string]
    $conditions.Add('LOG_DATE >= @FromDate')
    $conditions.Add('LOG_DATE < DATEADD(day, 1, @ToDate)')
    $params = @{ FromDate = $FromDate.Date; ToDate = $ToDate.Date }

    if ($LoginId) {
        $conditions.Add('LOGIN_ID = @LoginId')
        $params.LoginId = $LoginId
    }
    if ($null -ne $CategoryId) {
        $conditions.Add('CATEGORY_ID = @CategoryId')
        $params.CategoryId = $CategoryId
    }

    $sql = @"
SELECT DOC_LOG_ID, CASE_ID, LOGIN_ID, LOG_DATE, DOC_TYPE, DOC_NAME,
       DOC_FILE_NAME, CATEGORY_ID
FROM dbo.PAT_DOC_LOG
WHERE $($conditions -join ' AND ')
ORDER BY CASE_ID, LOG_DATE
"@
    return Invoke-RenToManQuery -Connection $Connection -Sql $sql -Parameters $params
}

function Get-CaseInfo {
    <# Returns a hashtable keyed by CASE_ID -> case row (PSCustomObject). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]] $CaseIds
    )

    $result = @{}
    $ids = $CaseIds | Sort-Object -Unique
    if (-not $ids -or $ids.Count -eq 0) { return $result }

    $chunkSize = 1000
    for ($i = 0; $i -lt $ids.Count; $i += $chunkSize) {
        $chunk = $ids[$i..([Math]::Min($i + $chunkSize, $ids.Count) - 1)]
        $paramNames = New-Object System.Collections.Generic.List[string]
        $params = @{}
        for ($j = 0; $j -lt $chunk.Count; $j++) {
            $name = "id$j"
            $paramNames.Add("@$name")
            $params[$name] = $chunk[$j]
        }
        $sql = @"
SELECT CASE_ID, CASE_TYPE_ID, CASE_NUMBER, STATE_ID, CASE_NUMBER_EXTENSION
FROM dbo.PAT_CASE
WHERE CASE_ID IN ($($paramNames -join ','))
"@
        foreach ($row in (Invoke-RenToManQuery -Connection $Connection -Sql $sql -Parameters $params)) {
            $result[[int]$row.CASE_ID] = $row
        }
    }
    return $result
}

function Get-CaseIdMapping {
    <# Returns a hashtable keyed by RENEWALS_CASE_ID -> MAIN_LIVE_CASE_ID (int). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]] $RenewalsCaseIds
    )

    $result = @{}
    $ids = $RenewalsCaseIds | Sort-Object -Unique
    if (-not $ids -or $ids.Count -eq 0) { return $result }

    $chunkSize = 1000
    for ($i = 0; $i -lt $ids.Count; $i += $chunkSize) {
        $chunk = $ids[$i..([Math]::Min($i + $chunkSize, $ids.Count) - 1)]
        $paramNames = New-Object System.Collections.Generic.List[string]
        $params = @{}
        for ($j = 0; $j -lt $chunk.Count; $j++) {
            $name = "id$j"
            $paramNames.Add("@$name")
            $params[$name] = $chunk[$j]
        }
        $sql = @"
SELECT MAIN_LIVE_CASE_ID, RENEWALS_CASE_ID
FROM dbo.wr_Renewals_vs_Main_Live
WHERE RENEWALS_CASE_ID IN ($($paramNames -join ','))
"@
        foreach ($row in (Invoke-RenToManQuery -Connection $Connection -Sql $sql -Parameters $params)) {
            $result[[int]$row.RENEWALS_CASE_ID] = [int]$row.MAIN_LIVE_CASE_ID
        }
    }
    return $result
}

function Get-CaseFolderPath {
    <#
        Builds the four-level case folder path:
          <root>\<CaseType>\<FamilyNumber>\<Country>\<Extension>
        from a PAT_CASE row and the FolderFormat config section.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)] $CaseInfo,
        [Parameter(Mandatory)][hashtable] $FolderFormat
    )

    if ($FolderFormat.CaseTypeZeroPad) {
        $caseType = ([int]$CaseInfo.CASE_TYPE_ID).ToString().PadLeft($FolderFormat.CaseTypeWidth, '0')
    }
    else {
        $caseType = ([int]$CaseInfo.CASE_TYPE_ID).ToString()
    }

    if ($FolderFormat.FamilyNumberZeroPad) {
        $familyNumber = ([int]$CaseInfo.CASE_NUMBER).ToString().PadLeft($FolderFormat.FamilyNumberWidth, '0')
    }
    else {
        $familyNumber = ([int]$CaseInfo.CASE_NUMBER).ToString()
    }

    $country = ([string]$CaseInfo.STATE_ID).Trim()
    if ($FolderFormat.CountryUppercase) { $country = $country.ToUpperInvariant() }

    $extension = ([string]$CaseInfo.CASE_NUMBER_EXTENSION).Trim()
    if ($FolderFormat.ExtensionUppercase) { $extension = $extension.ToUpperInvariant() }

    return Join-Path -Path (Join-Path -Path (Join-Path -Path (Join-Path -Path $Root -ChildPath $caseType) -ChildPath $familyNumber) -ChildPath $country) -ChildPath $extension
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

function New-RenToManPlan {
    <#
        Step 4: turn raw DB rows into a flat list of planned copies, each
        with SourcePath / TargetPath / SkipReason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Entries,
        [Parameter(Mandatory)][hashtable] $SourceCases,
        [Parameter(Mandatory)][hashtable] $CaseIdMap,
        [Parameter(Mandatory)][hashtable] $TargetCases,
        [Parameter(Mandatory)][string] $SourceRoot,
        [Parameter(Mandatory)][string] $TargetRoot,
        [Parameter(Mandatory)][hashtable] $FolderFormat
    )

    $plan = New-Object System.Collections.Generic.List[object]

    foreach ($e in $Entries) {
        $caseId = [int]$e.CASE_ID
        $srcCase = $SourceCases[$caseId]

        if (-not $srcCase) {
            $plan.Add([pscustomobject]@{
                DocLogId    = $e.DOC_LOG_ID
                CaseId      = $caseId
                MainCaseId  = $null
                LogDate     = $e.LOG_DATE
                DocName     = $e.DOC_NAME
                DocFileName = $e.DOC_FILE_NAME
                SourcePath  = $null
                TargetPath  = $null
                SkipReason  = 'source case not found in PAT_CASE'
            })
            continue
        }

        $sourceDir = Get-CaseFolderPath -Root $SourceRoot -CaseInfo $srcCase -FolderFormat $FolderFormat
        $sourcePath = if ($e.DOC_FILE_NAME) { Join-Path $sourceDir $e.DOC_FILE_NAME } else { $null }

        $mainCaseId = $CaseIdMap[$caseId]
        if (-not $mainCaseId) {
            $plan.Add([pscustomobject]@{
                DocLogId    = $e.DOC_LOG_ID
                CaseId      = $caseId
                MainCaseId  = $null
                LogDate     = $e.LOG_DATE
                DocName     = $e.DOC_NAME
                DocFileName = $e.DOC_FILE_NAME
                SourcePath  = $sourcePath
                TargetPath  = $null
                SkipReason  = 'no mapping in wr_Renewals_vs_Main_Live'
            })
            continue
        }

        $tgtCase = $TargetCases[$mainCaseId]
        if (-not $tgtCase) {
            $plan.Add([pscustomobject]@{
                DocLogId    = $e.DOC_LOG_ID
                CaseId      = $caseId
                MainCaseId  = $mainCaseId
                LogDate     = $e.LOG_DATE
                DocName     = $e.DOC_NAME
                DocFileName = $e.DOC_FILE_NAME
                SourcePath  = $sourcePath
                TargetPath  = $null
                SkipReason  = 'target case not found in Main PAT_CASE'
            })
            continue
        }

        $targetDir = Get-CaseFolderPath -Root $TargetRoot -CaseInfo $tgtCase -FolderFormat $FolderFormat
        $targetPath = if ($e.DOC_FILE_NAME) { Join-Path $targetDir $e.DOC_FILE_NAME } else { $null }

        $skipReason = $null
        if (-not $e.DOC_FILE_NAME) { $skipReason = 'DOC_FILE_NAME is empty' }

        $plan.Add([pscustomobject]@{
            DocLogId    = $e.DOC_LOG_ID
            CaseId      = $caseId
            MainCaseId  = $mainCaseId
            LogDate     = $e.LOG_DATE
            DocName     = $e.DOC_NAME
            DocFileName = $e.DOC_FILE_NAME
            SourcePath  = $sourcePath
            TargetPath  = $targetPath
            SkipReason  = $skipReason
        })
    }

    return $plan.ToArray()
}

function Test-RenToManCopyable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Planned)
    return (-not $Planned.SkipReason) -and $Planned.SourcePath -and $Planned.TargetPath
}

function Copy-RenToManDocument {
    <# Step 5: copy a single planned document, creating the target folder as needed. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Planned)

    $now = Get-Date

    if (-not (Test-RenToManCopyable -Planned $Planned)) {
        return [pscustomobject]@{
            Planned   = $Planned
            Status    = 'skipped'
            Message   = $(if ($Planned.SkipReason) { $Planned.SkipReason } else { 'not copyable' })
            Timestamp = $now
        }
    }

    $srcLong = Get-LongPath $Planned.SourcePath
    $dstLong = Get-LongPath $Planned.TargetPath

    if (-not (Test-Path -LiteralPath $srcLong)) {
        return [pscustomobject]@{
            Planned   = $Planned
            Status    = 'missing_source'
            Message   = "source file not found: $($Planned.SourcePath)"
            Timestamp = $now
        }
    }

    if (Test-Path -LiteralPath $dstLong) {
        return [pscustomobject]@{
            Planned   = $Planned
            Status    = 'skipped'
            Message   = "target already exists: $($Planned.TargetPath)"
            Timestamp = $now
        }
    }

    try {
        $dstDir = Split-Path -Path $dstLong -Parent
        if (-not (Test-Path -LiteralPath $dstDir)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $srcLong -Destination $dstLong -Force
        return [pscustomobject]@{
            Planned   = $Planned
            Status    = 'copied'
            Message   = ''
            Timestamp = $now
        }
    }
    catch {
        return [pscustomobject]@{
            Planned   = $Planned
            Status    = 'error'
            Message   = $_.Exception.Message
            Timestamp = $now
        }
    }
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

function Write-RenToManRunLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Results,
        [Parameter(Mandatory)][string] $Path
    )
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    foreach ($r in $Results) {
        $record = [ordered]@{
            timestamp    = $r.Timestamp.ToString('o')
            doc_log_id   = $r.Planned.DocLogId
            case_id      = $r.Planned.CaseId
            main_case_id = $r.Planned.MainCaseId
            source_path  = $r.Planned.SourcePath
            target_path  = $r.Planned.TargetPath
            status       = $r.Status
            message      = $r.Message
        }
        ($record | ConvertTo-Json -Compress) | Add-Content -Path $Path -Encoding UTF8
    }
}

function Write-RenToManReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Results,
        [Parameter(Mandatory)][string] $Path
    )
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $counts = @{ copied = 0; skipped = 0; missing_source = 0; error = 0 }
    foreach ($r in $Results) {
        if ($counts.ContainsKey($r.Status)) { $counts[$r.Status]++ }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('ren_to_man run report')
    $lines.Add("generated: $((Get-Date).ToString('o'))")
    $lines.Add('')
    $lines.Add("total documents considered: $($Results.Count)")
    foreach ($status in 'copied', 'skipped', 'missing_source', 'error') {
        $lines.Add("  ${status}: $($counts[$status])")
    }
    $lines.Add('')

    $problems = $Results | Where-Object { $_.Status -in @('missing_source', 'error') }
    if ($problems) {
        $lines.Add('Details for missing/errored documents:')
        foreach ($r in $problems) {
            $lines.Add("  DOC_LOG_ID=$($r.Planned.DocLogId) CASE_ID=$($r.Planned.CaseId) status=$($r.Status) message=$($r.Message)")
        }
    }
    else {
        $lines.Add('No missing sources or errors.')
    }

    Set-Content -Path $Path -Value ($lines -join "`r`n") -Encoding UTF8
}

Export-ModuleMember -Function *
