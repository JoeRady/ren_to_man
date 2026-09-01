#Requires -Modules Pester
<#
    Run with:  Invoke-Pester -Path .\powershell\tests\RenToMain.Tests.ps1

    These tests cover only the pure logic (CSV joining, script generation,
    copy behaviour of the generated script against a local temp folder) - no
    database connection is needed, and none of the code under test uses
    System.Data.SqlClient, System.Text.StringBuilder, or generic collections,
    so this also runs fine under PowerShell Constrained Language Mode.

    Written for this repo's Linux dev sandbox to author against, but was NOT
    executed there (no pwsh available) - run it on your Windows machine
    before relying on it, and report back anything that doesn't parse or
    pass.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\RenToMain.psd1') -Force
}

Describe 'Get-LongPath' {
    It 'prefixes UNC paths with \\?\UNC\' {
        Get-LongPath '\\brifile\share\a\b' | Should -Be '\\?\UNC\brifile\share\a\b'
    }
    It 'leaves short local paths untouched' {
        Get-LongPath 'C:\short\path.pdf' | Should -Be 'C:\short\path.pdf'
    }
}

Describe 'ConvertTo-RenToMainPsStringLiteral' {
    It 'escapes single quotes so the value round-trips through Invoke-Expression' {
        $literal = ConvertTo-RenToMainPsStringLiteral "O'Brien ümlaut ' pdf"
        $value = Invoke-Expression $literal
        $value | Should -Be "O'Brien ümlaut ' pdf"
    }

    It 'renders $null for a null value' {
        ConvertTo-RenToMainPsStringLiteral $null | Should -Be '$null'
    }
}

Describe 'Get-RenToMainCsvDelimiter' {
    It 'detects a semicolon-delimited header (e.g. German-locale SSMS export)' {
        $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpRoot | Out-Null
        try {
            $path = Join-Path $tmpRoot 'semi.csv'
            Set-Content -Path $path -Value 'A;B;C' -Encoding UTF8
            Get-RenToMainCsvDelimiter -Path $path | Should -Be ';'
        }
        finally {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'detects a comma-delimited header' {
        $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpRoot | Out-Null
        try {
            $path = Join-Path $tmpRoot 'comma.csv'
            Set-Content -Path $path -Value 'A,B,C' -Encoding UTF8
            Get-RenToMainCsvDelimiter -Path $path | Should -Be ','
        }
        finally {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'detects a tab-delimited header (e.g. SSMS "Results to Text" export)' {
        $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpRoot | Out-Null
        try {
            $path = Join-Path $tmpRoot 'tab.csv'
            Set-Content -Path $path -Value "A`tB`tC" -Encoding UTF8
            Get-RenToMainCsvDelimiter -Path $path | Should -Be "`t"
        }
        finally {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'New-RenToMainPlanFromCsv' {
    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpRoot | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'joins source documents and case mapping into a copyable plan' {
        $sourceCsv = Join-Path $tmpRoot 'source_documents.csv'
        $mappingCsv = Join-Path $tmpRoot 'case_mapping.csv'

        @(
            [pscustomobject]@{
                DOC_LOG_ID = 1; CASE_ID = 100; LOGIN_ID = 'jsmith'; LOG_DATE = '2026-01-01'
                DOC_NAME = 'Renewal Reminder'; DOC_FILE_NAME = 'reminder_ümlaut.pdf'; CATEGORY_ID = 5
                SOURCE_PATH = '\\brifile\Renewals\Patricia\documents\2\666777\DE\EP\reminder_ümlaut.pdf'
            }
        ) | Export-Csv -Path $sourceCsv -NoTypeInformation -Encoding UTF8

        @(
            [pscustomobject]@{
                RENEWALS_CASE_ID = 100; MAIN_LIVE_CASE_ID = 200
                TARGET_FOLDER = '\\brimain\Main\Patricia\documents\2\666777\DE\EP'
            }
        ) | Export-Csv -Path $mappingCsv -NoTypeInformation -Encoding UTF8

        $plan = @(New-RenToMainPlanFromCsv -SourceDocumentsCsvPath $sourceCsv -CaseMappingCsvPath $mappingCsv)

        $plan.Count | Should -Be 1
        Test-RenToMainCopyable $plan[0] | Should -Be $true
        $plan[0].SourcePath | Should -Be '\\brifile\Renewals\Patricia\documents\2\666777\DE\EP\reminder_ümlaut.pdf'
        $plan[0].TargetPath | Should -Be '\\brimain\Main\Patricia\documents\2\666777\DE\EP\reminder_ümlaut.pdf'
    }

    It 'skips documents with no matching row in the case mapping CSV' {
        $sourceCsv = Join-Path $tmpRoot 'source_documents.csv'
        $mappingCsv = Join-Path $tmpRoot 'case_mapping.csv'

        @(
            [pscustomobject]@{
                DOC_LOG_ID = 1; CASE_ID = 100; LOGIN_ID = 'jsmith'; LOG_DATE = '2026-01-01'
                DOC_NAME = 'Doc'; DOC_FILE_NAME = 'f.pdf'; CATEGORY_ID = 5
                SOURCE_PATH = '\\brifile\...\f.pdf'
            }
        ) | Export-Csv -Path $sourceCsv -NoTypeInformation -Encoding UTF8

        @() | Export-Csv -Path $mappingCsv -NoTypeInformation -Encoding UTF8
        # Import-Csv needs a header row even for zero data rows.
        Set-Content -Path $mappingCsv -Value '"RENEWALS_CASE_ID","MAIN_LIVE_CASE_ID","TARGET_FOLDER"' -Encoding UTF8

        $plan = @(New-RenToMainPlanFromCsv -SourceDocumentsCsvPath $sourceCsv -CaseMappingCsvPath $mappingCsv)

        $plan.Count | Should -Be 1
        Test-RenToMainCopyable $plan[0] | Should -Be $false
        $plan[0].SkipReason | Should -Match 'mapping'
    }

    It 'handles a semicolon-delimited mapping CSV with NULL rows (German-locale SSMS export)' {
        $sourceCsv = Join-Path $tmpRoot 'source_documents.csv'
        $mappingCsv = Join-Path $tmpRoot 'case_mapping.csv'

        @(
            [pscustomobject]@{
                DOC_LOG_ID = 1; CASE_ID = 100; LOGIN_ID = 'jsmith'; LOG_DATE = '2026-01-01'
                DOC_NAME = 'Doc'; DOC_FILE_NAME = 'f.pdf'; CATEGORY_ID = 5
                SOURCE_PATH = 'C:\src\f.pdf'
            }
        ) | Export-Csv -Path $sourceCsv -NoTypeInformation -Encoding UTF8

        $mappingLines = @(
            'RENEWALS_CASE_ID;MAIN_LIVE_CASE_ID;CASE_TYPE_ID;CASE_NUMBER;COUNTRY;CASE_NUMBER_EXTENSION;TARGET_FOLDER'
            'NULL;413224;6;514324;GB;0;D:\Main\Patricia\documents\6\514324\GB\00'
            '100;200;2;666777;DE;EP;D:\Main\Patricia\documents\2\666777\DE\EP'
        )
        Set-Content -Path $mappingCsv -Value $mappingLines -Encoding UTF8

        $plan = @(New-RenToMainPlanFromCsv -SourceDocumentsCsvPath $sourceCsv -CaseMappingCsvPath $mappingCsv)

        $plan.Count | Should -Be 1
        Test-RenToMainCopyable $plan[0] | Should -Be $true
        $plan[0].TargetPath | Should -Be 'D:\Main\Patricia\documents\2\666777\DE\EP\f.pdf'
    }

    It 'handles a tab-delimited source CSV whose filenames contain literal semicolons (SSMS "Results to Text" export)' {
        $sourceCsv = Join-Path $tmpRoot 'source_documents.csv'
        $mappingCsv = Join-Path $tmpRoot 'case_mapping.csv'

        # Real Patricia document filenames can contain ';' - a semicolon-delimited
        # export would corrupt this row, so this file must stay tab-delimited.
        $sourceLines = @(
            "DOC_LOG_ID`tCASE_ID`tLOGIN_ID`tLOG_DATE`tDOC_TYPE`tDOC_NAME`tDOC_FILE_NAME`tCATEGORY_ID`tSOURCE_PATH"
            "2846098`t185179`tMJR`t2026-06-10 16:36:37.150`t4`t4778705;21165771.TIF`t4778705;21165771 1151382.TIF`t21`t\\brifile\Renewals\Patricia\documents\2\110278\CN\PC\4778705;21165771 1151382.TIF"
        )
        Set-Content -Path $sourceCsv -Value $sourceLines -Encoding UTF8

        $mappingLines = @(
            "RENEWALS_CASE_ID`tMAIN_LIVE_CASE_ID`tTARGET_FOLDER"
            "185179`t285179`tD:\Main\Patricia\documents\2\110278\CN\PC"
        )
        Set-Content -Path $mappingCsv -Value $mappingLines -Encoding UTF8

        $plan = @(New-RenToMainPlanFromCsv -SourceDocumentsCsvPath $sourceCsv -CaseMappingCsvPath $mappingCsv)

        $plan.Count | Should -Be 1
        Test-RenToMainCopyable $plan[0] | Should -Be $true
        $plan[0].DocFileName | Should -Be '4778705;21165771 1151382.TIF'
        $plan[0].TargetPath | Should -Be 'D:\Main\Patricia\documents\2\110278\CN\PC\4778705;21165771 1151382.TIF'
    }
}

Describe 'New-RenToMainCopyScript' {
    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpRoot | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'generates a self-contained script that actually copies a file when run with -Force' {
        $srcDir = Join-Path $tmpRoot 'src'
        New-Item -ItemType Directory -Path $srcDir | Out-Null
        $srcFile = Join-Path $srcDir "ümlaut ' file.pdf"
        Set-Content -LiteralPath $srcFile -Value 'hello' -Encoding UTF8 -NoNewline

        $dstFile = Join-Path $tmpRoot "dst\2\666777\DE\EP\ümlaut ' file.pdf"

        $plan = @([pscustomobject]@{
            DocLogId = 1; CaseId = 100; MainCaseId = 200; LogDate = $null
            DocName = 'Doc'; DocFileName = "ümlaut ' file.pdf"
            SourcePath = $srcFile; TargetPath = $dstFile; SkipReason = $null
        })

        $scriptPath = Join-Path $tmpRoot 'copy_script.ps1'
        $genResult = New-RenToMainCopyScript -Plan $plan -Path $scriptPath

        $genResult.ItemCount | Should -Be 1
        Test-Path -LiteralPath $scriptPath | Should -Be $true

        # The generated script must be fully standalone: no DB types, no
        # module dependency, and (for Constrained Language Mode) no
        # StringBuilder / generic collection method calls.
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content | Should -Not -Match 'SqlConnection'
        $content | Should -Not -Match 'Import-Module'
        $content | Should -Not -Match 'StringBuilder'
        $content | Should -Not -Match 'Generic\.List'

        & $scriptPath -Force

        Test-Path -LiteralPath $dstFile | Should -Be $true
        (Get-Content -LiteralPath $dstFile -Raw) | Should -Be 'hello'

        $logFile = Get-ChildItem -Path $tmpRoot -Filter 'copy_log_*.jsonl' | Select-Object -First 1
        $logFile | Should -Not -BeNullOrEmpty
        $logRecord = Get-Content -LiteralPath $logFile.FullName -Raw | ConvertFrom-Json
        $logRecord.status | Should -Be 'copied'
    }

    It 'excludes non-copyable (skipped) plan entries from the generated script' {
        $plan = @([pscustomobject]@{
            DocLogId = 1; CaseId = 100; MainCaseId = $null; LogDate = $null
            DocName = 'Doc'; DocFileName = 'f.pdf'
            SourcePath = $null; TargetPath = $null; SkipReason = 'no mapping'
        })

        $scriptPath = Join-Path $tmpRoot 'copy_script.ps1'
        $genResult = New-RenToMainCopyScript -Plan $plan -Path $scriptPath

        $genResult.ItemCount | Should -Be 0
        $genResult.SkippedAtPlanning | Should -Be 1
    }
}

Describe 'Write-RenToMainCandidateCsv' {
    It 'writes a CSV with the expected columns' {
        $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpRoot | Out-Null
        try {
            $plan = @([pscustomobject]@{
                DocLogId = 1; CaseId = 100; MainCaseId = 200; LogDate = '2026-01-01'
                DocName = 'Doc'; DocFileName = 'f.pdf'
                SourcePath = 'C:\src\f.pdf'; TargetPath = 'C:\dst\f.pdf'; SkipReason = $null
            })
            $csvPath = Join-Path $tmpRoot 'candidates.csv'

            Write-RenToMainCandidateCsv -Plan $plan -Path $csvPath

            $rows = @(Import-Csv -LiteralPath $csvPath)
            $rows.Count | Should -Be 1
            $rows[0].DOC_LOG_ID | Should -Be '1'
            $rows[0].TARGET_PATH | Should -Be 'C:\dst\f.pdf'
        }
        finally {
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-RenToMainNuxeoPath' {
    It 'builds the Nuxeo path with the same zero-padding convention as the filesystem target' {
        $planned = [pscustomobject]@{
            MainCaseTypeId = 2; MainCaseNumber = 666777; MainCountry = 'de'
            MainExtension  = 'EP'; DocFileName = "ümlaut ' file.pdf"
        }
        $path = Get-RenToMainNuxeoPath -RootPath '\Workspaces\Patricia\Documents\' -Planned $planned
        $path | Should -Be "Workspaces/Patricia/Documents/2/666777/DE/EP/ümlaut ' file.pdf"
    }
}

Describe 'ConvertTo-RenToMainSqlStringLiteral' {
    It 'escapes single quotes and wraps in N-prefixed quotes' {
        ConvertTo-RenToMainSqlStringLiteral "O'Brien" | Should -Be "N'O''Brien'"
    }
    It 'returns the literal NULL keyword for $null' {
        ConvertTo-RenToMainSqlStringLiteral $null | Should -Be 'NULL'
    }
    It 'returns the literal NULL keyword for an empty string' {
        ConvertTo-RenToMainSqlStringLiteral '' | Should -Be 'NULL'
    }
}

Describe 'Test-RenToMainCopyable / Test-RenToMainInsertNeeded' {
    It 'falls back to the pre-verification rule when Action was never set (e.g. plain unit-test fixtures)' {
        $planned = [pscustomobject]@{
            SourcePath = 'C:\src\f.pdf'; TargetPath = 'C:\dst\f.pdf'; SkipReason = $null
        }
        Test-RenToMainCopyable $planned | Should -Be $true
        Test-RenToMainInsertNeeded $planned | Should -Be $false
    }

    It 'uses Action when present' {
        $copyAndInsert = [pscustomobject]@{ Action = 'CopyAndInsert' }
        $insertOnly = [pscustomobject]@{ Action = 'InsertOnly' }
        $noAction = [pscustomobject]@{ Action = 'NoAction' }

        Test-RenToMainCopyable $copyAndInsert | Should -Be $true
        Test-RenToMainInsertNeeded $copyAndInsert | Should -Be $true

        Test-RenToMainCopyable $insertOnly | Should -Be $false
        Test-RenToMainInsertNeeded $insertOnly | Should -Be $true

        Test-RenToMainCopyable $noAction | Should -Be $false
        Test-RenToMainInsertNeeded $noAction | Should -Be $false
    }
}

Describe 'Add-RenToMainVerification' {
    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpRoot | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'applies the full decision matrix (Main-Live x Nuxeo -> Action)' {
        $mainLiveCsv = Join-Path $tmpRoot 'main_live_documents.csv'
        $mainLiveLines = @(
            'CASE_ID,DOC_FILE_NAME'
            '200,both.pdf'      # in Main-Live
            '200,mainonly.pdf'  # in Main-Live
        )
        Set-Content -Path $mainLiveCsv -Value $mainLiveLines -Encoding UTF8

        $plan = @(
            [pscustomobject]@{ DocLogId = 1; MainCaseId = 200; DocFileName = 'both.pdf'; MainCaseTypeId = 2; MainCaseNumber = 1; MainCountry = 'DE'; MainExtension = 'EP'; SkipReason = $null }
            [pscustomobject]@{ DocLogId = 2; MainCaseId = 200; DocFileName = 'mainonly.pdf'; MainCaseTypeId = 2; MainCaseNumber = 1; MainCountry = 'DE'; MainExtension = 'EP'; SkipReason = $null }
            [pscustomobject]@{ DocLogId = 3; MainCaseId = 200; DocFileName = 'neither.pdf'; MainCaseTypeId = 2; MainCaseNumber = 1; MainCountry = 'DE'; MainExtension = 'EP'; SkipReason = $null }
            [pscustomobject]@{ DocLogId = 4; MainCaseId = 200; DocFileName = 'nuxeoonly.pdf'; MainCaseTypeId = 2; MainCaseNumber = 1; MainCountry = 'DE'; MainExtension = 'EP'; SkipReason = $null }
            [pscustomobject]@{ DocLogId = 5; MainCaseId = 200; DocFileName = 'inconclusive.pdf'; MainCaseTypeId = 2; MainCaseNumber = 1; MainCountry = 'DE'; MainExtension = 'EP'; SkipReason = $null }
            [pscustomobject]@{ DocLogId = 6; MainCaseId = $null; DocFileName = $null; MainCaseTypeId = $null; MainCaseNumber = $null; MainCountry = $null; MainExtension = $null; SkipReason = 'no mapping' }
        )

        Mock -ModuleName RenToMain -CommandName Test-RenToMainNuxeoDocumentExists -MockWith {
            param($BaseUrl, $Path, $Credential, [switch] $SkipCertificateCheck)
            if ($Path -like '*/both.pdf') { return $true }
            if ($Path -like '*/mainonly.pdf') { return $false }
            if ($Path -like '*/neither.pdf') { return $false }
            if ($Path -like '*/nuxeoonly.pdf') { return $true }
            if ($Path -like '*/inconclusive.pdf') { return $null }
            return $null
        }

        # NuxeoCredential is untyped in Add-RenToMainVerification and never
        # actually used here since Test-RenToMainNuxeoDocumentExists is
        # mocked - a plain string avoids constructing a PSCredential (not a
        # Constrained-Language-Mode "core type") just for this test.
        $result = @(Add-RenToMainVerification -Plan $plan -MainLiveDocumentsCsvPath $mainLiveCsv `
            -NuxeoBaseUrl 'https://nuxeo.example' -NuxeoRootPath '/Workspaces/Patricia/Documents' `
            -NuxeoCredential 'dummy')

        ($result | Where-Object DocLogId -eq 1).Action | Should -Be 'NoAction'
        ($result | Where-Object DocLogId -eq 2).Action | Should -Be 'CopyOnly'
        ($result | Where-Object DocLogId -eq 3).Action | Should -Be 'CopyAndInsert'
        ($result | Where-Object DocLogId -eq 4).Action | Should -Be 'InsertOnly'
        ($result | Where-Object DocLogId -eq 5).Action | Should -Be 'VerificationFailed'
        ($result | Where-Object DocLogId -eq 6).Action | Should -Be 'NoAction'
    }
}

Describe 'New-RenToMainInsertScript' {
    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpRoot | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'only includes items whose Action needs an insert' {
        $plan = @(
            [pscustomobject]@{ DocLogId = 1; MainCaseId = 200; LoginId = 'jsmith'; LogDate = '2026-01-01'; DocType = '4'; DocName = 'Doc'; DocFileName = 'a.pdf'; CategoryId = '5'; Action = 'CopyAndInsert' }
            [pscustomobject]@{ DocLogId = 2; MainCaseId = 201; LoginId = 'jsmith'; LogDate = '2026-01-02'; DocType = '4'; DocName = 'Doc2'; DocFileName = 'b.pdf'; CategoryId = '5'; Action = 'InsertOnly' }
            [pscustomobject]@{ DocLogId = 3; MainCaseId = 202; LoginId = 'jsmith'; LogDate = '2026-01-03'; DocType = '4'; DocName = 'Doc3'; DocFileName = 'c.pdf'; CategoryId = '5'; Action = 'CopyOnly' }
            [pscustomobject]@{ DocLogId = 4; MainCaseId = 203; LoginId = 'jsmith'; LogDate = '2026-01-04'; DocType = '4'; DocName = 'Doc4'; DocFileName = 'd.pdf'; CategoryId = '5'; Action = 'NoAction' }
        )
        $scriptPath = Join-Path $tmpRoot 'insert.sql'

        $genResult = New-RenToMainInsertScript -Plan $plan -Path $scriptPath

        $genResult.RowCount | Should -Be 2
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content | Should -Match "N'a\.pdf'"
        $content | Should -Match "N'b\.pdf'"
        $content | Should -Not -Match "N'c\.pdf'"
        $content | Should -Not -Match "N'd\.pdf'"
    }
}
