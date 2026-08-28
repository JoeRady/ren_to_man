#Requires -Modules Pester
<#
    Run with:  Invoke-Pester -Path .\powershell\tests\RenToMan.Tests.ps1

    These tests cover only the pure logic (path building, plan building,
    copy behaviour against a local temp folder) - no database connection is
    needed. Written for this repo's Linux dev sandbox to author against, but
    was NOT executed there (no pwsh available) - run it on your Windows
    machine before relying on it, and report back anything that doesn't
    parse or pass.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\RenToMan.psd1') -Force
}

Describe 'Get-CaseFolderPath' {
    It 'builds the default (non-zero-padded case type) path' {
        $fmt = @{
            CaseTypeZeroPad = $false; CaseTypeWidth = 2
            FamilyNumberZeroPad = $true; FamilyNumberWidth = 6
            CountryUppercase = $true; ExtensionUppercase = $false
        }
        $case = [pscustomobject]@{ CASE_TYPE_ID = 2; CASE_NUMBER = 666777; STATE_ID = 'de'; CASE_NUMBER_EXTENSION = 'ep' }

        $path = Get-CaseFolderPath -Root '\\brifile\Renewals\Patricia\documents' -CaseInfo $case -FolderFormat $fmt

        $path | Should -Be '\\brifile\Renewals\Patricia\documents\2\666777\DE\ep'
    }

    It 'zero-pads the case type when configured' {
        $fmt = @{
            CaseTypeZeroPad = $true; CaseTypeWidth = 2
            FamilyNumberZeroPad = $true; FamilyNumberWidth = 6
            CountryUppercase = $true; ExtensionUppercase = $false
        }
        $case = [pscustomobject]@{ CASE_TYPE_ID = 2; CASE_NUMBER = 123; STATE_ID = 'US'; CASE_NUMBER_EXTENSION = 'A1' }

        $path = Get-CaseFolderPath -Root 'D:\docs' -CaseInfo $case -FolderFormat $fmt

        $path | Should -Be 'D:\docs\02\000123\US\A1'
    }
}

Describe 'Get-LongPath' {
    It 'prefixes UNC paths with \\?\UNC\' {
        Get-LongPath '\\brifile\share\a\b' | Should -Be '\\?\UNC\brifile\share\a\b'
    }
    It 'leaves short local paths untouched' {
        Get-LongPath 'C:\short\path.pdf' | Should -Be 'C:\short\path.pdf'
    }
}

Describe 'New-RenToManPlan' {
    BeforeAll {
        $script:fmt = @{
            CaseTypeZeroPad = $false; CaseTypeWidth = 2
            FamilyNumberZeroPad = $true; FamilyNumberWidth = 6
            CountryUppercase = $true; ExtensionUppercase = $false
        }
    }

    It 'builds a copyable plan for a fully mapped document' {
        $entries = @([pscustomobject]@{
            DOC_LOG_ID = 1; CASE_ID = 100; LOGIN_ID = 'jsmith'
            LOG_DATE = (Get-Date '2026-01-01'); DOC_NAME = 'Renewal Reminder'
            DOC_FILE_NAME = 'reminder_ümlaut.pdf'; CATEGORY_ID = 5
        })
        $sourceCases = @{ 100 = [pscustomobject]@{ CASE_ID = 100; CASE_TYPE_ID = 2; CASE_NUMBER = 666777; STATE_ID = 'DE'; CASE_NUMBER_EXTENSION = 'EP' } }
        $caseIdMap = @{ 100 = 200 }
        $targetCases = @{ 200 = [pscustomobject]@{ CASE_ID = 200; CASE_TYPE_ID = 2; CASE_NUMBER = 666777; STATE_ID = 'DE'; CASE_NUMBER_EXTENSION = 'EP' } }

        $plan = New-RenToManPlan -Entries $entries -SourceCases $sourceCases -CaseIdMap $caseIdMap `
            -TargetCases $targetCases -SourceRoot '\\brifile\Renewals\Patricia\documents' `
            -TargetRoot '\\brimain\Main\Patricia\documents' -FolderFormat $fmt

        $plan.Count | Should -Be 1
        Test-RenToManCopyable $plan[0] | Should -Be $true
        $plan[0].SourcePath | Should -Be '\\brifile\Renewals\Patricia\documents\2\666777\DE\EP\reminder_ümlaut.pdf'
        $plan[0].TargetPath | Should -Be '\\brimain\Main\Patricia\documents\2\666777\DE\EP\reminder_ümlaut.pdf'
    }

    It 'skips documents with no case-id mapping' {
        $entries = @([pscustomobject]@{
            DOC_LOG_ID = 1; CASE_ID = 100; LOGIN_ID = 'jsmith'
            LOG_DATE = (Get-Date '2026-01-01'); DOC_NAME = 'Doc'; DOC_FILE_NAME = 'f.pdf'; CATEGORY_ID = 5
        })
        $sourceCases = @{ 100 = [pscustomobject]@{ CASE_ID = 100; CASE_TYPE_ID = 2; CASE_NUMBER = 666777; STATE_ID = 'DE'; CASE_NUMBER_EXTENSION = 'EP' } }

        $plan = New-RenToManPlan -Entries $entries -SourceCases $sourceCases -CaseIdMap @{} `
            -TargetCases @{} -SourceRoot '\\brifile\Renewals\Patricia\documents' `
            -TargetRoot '\\brimain\Main\Patricia\documents' -FolderFormat $fmt

        Test-RenToManCopyable $plan[0] | Should -Be $false
        $plan[0].SkipReason | Should -Match 'mapping'
    }

    It 'skips documents whose source case is missing' {
        $entries = @([pscustomobject]@{
            DOC_LOG_ID = 1; CASE_ID = 999; LOGIN_ID = 'jsmith'
            LOG_DATE = (Get-Date '2026-01-01'); DOC_NAME = 'Doc'; DOC_FILE_NAME = 'f.pdf'; CATEGORY_ID = 5
        })

        $plan = New-RenToManPlan -Entries $entries -SourceCases @{} -CaseIdMap @{} `
            -TargetCases @{} -SourceRoot '\\brifile\Renewals\Patricia\documents' `
            -TargetRoot '\\brimain\Main\Patricia\documents' -FolderFormat $fmt

        Test-RenToManCopyable $plan[0] | Should -Be $false
        $plan[0].SkipReason | Should -Match 'source case'
    }
}

Describe 'Copy-RenToManDocument' {
    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpRoot | Out-Null
    }
    AfterEach {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'copies a file with a non-ASCII name, creating target folders' {
        $srcDir = Join-Path $tmpRoot 'src'
        New-Item -ItemType Directory -Path $srcDir | Out-Null
        $srcFile = Join-Path $srcDir 'ümlaut file.pdf'
        Set-Content -LiteralPath $srcFile -Value 'hello' -Encoding UTF8

        $dstFile = Join-Path $tmpRoot 'dst\2\666777\DE\EP\ümlaut file.pdf'

        $planned = [pscustomobject]@{
            DocLogId = 1; CaseId = 100; MainCaseId = 200; LogDate = $null
            DocName = 'Doc'; DocFileName = 'ümlaut file.pdf'
            SourcePath = $srcFile; TargetPath = $dstFile; SkipReason = $null
        }

        $result = Copy-RenToManDocument -Planned $planned

        $result.Status | Should -Be 'copied'
        Test-Path -LiteralPath $dstFile | Should -Be $true
    }

    It 'reports missing_source when the source file does not exist' {
        $planned = [pscustomobject]@{
            DocLogId = 1; CaseId = 100; MainCaseId = 200; LogDate = $null
            DocName = 'Doc'; DocFileName = 'nope.pdf'
            SourcePath = (Join-Path $tmpRoot 'does_not_exist.pdf')
            TargetPath = (Join-Path $tmpRoot 'dst\nope.pdf'); SkipReason = $null
        }

        (Copy-RenToManDocument -Planned $planned).Status | Should -Be 'missing_source'
    }

    It 'reports skipped when the plan carries a SkipReason' {
        $planned = [pscustomobject]@{
            DocLogId = 1; CaseId = 100; MainCaseId = $null; LogDate = $null
            DocName = 'Doc'; DocFileName = 'f.pdf'
            SourcePath = $null; TargetPath = $null; SkipReason = 'no mapping'
        }

        $result = Copy-RenToManDocument -Planned $planned
        $result.Status | Should -Be 'skipped'
        $result.Message | Should -Be 'no mapping'
    }
}
