<#
.SYNOPSIS
    Standalone Nuxeo REST API connectivity test - no dependency on the
    RenToMain module. Run this first to find out whether login even works
    in your environment, before relying on Add-RenToMainVerification /
    Test-RenToMainNuxeoDocumentExists in RenToMain.psm1.

.DESCRIPTION
    Reads Username/Password from a plain-text credential file and calls
    Nuxeo's repository-root endpoint (/api/v1/path/) to confirm login and
    the REST API both work - the same endpoint style
    Test-RenToMainNuxeoDocumentExists uses for document checks, so success
    here means the real verification step should work too. Also tries the
    "who am I" endpoint (/api/v1/me), but treats its failure as informational
    only: Nuxeo Platform 7.3 (confirmed in use here) may not implement it at
    all, independent of whether login itself works. Optionally also checks
    one specific document path if you pass -TestPath.

    This script is deliberately self-contained (no Import-Module) and
    reports each step's outcome plainly, including a clear diagnosis if
    PSCredential creation itself is blocked - which can happen under
    PowerShell Constrained Language Mode (see powershell/README.md); on this
    corporate PC it was confirmed to work fine.

    SECURITY WARNING: the credential file this script reads is PLAIN TEXT.
    Only use this for one-off connectivity testing:
      - never commit it to version control (already covered by
        .gitignore's powershell/nuxeo.credentials.txt entry)
      - delete it once you're done testing
      - for actual verification runs (Run-RenToMain.ps1
        -MainLiveDocumentsCsvPath ...), use the encrypted credential cache
        instead (Get-RenToMainCredential in RenToMain.psm1) - that one only
        ever writes an Export-Clixml-encrypted file (DPAPI, readable only by
        the same Windows user on the same machine), never plain text.

.PARAMETER CredentialFilePath
    Path to a plain-text file with two lines, e.g.:
        Username=svc_account
        Password=the_password
    Default: .\nuxeo.credentials.txt next to this script.

.PARAMETER BaseUrl
    Nuxeo base URL. Default: https://ndc-edms-01.corp.withersrogers.com/nuxeo

.PARAMETER TestPath
    Optional: also check whether a specific document path exists, e.g.
    /Workspaces/Patricia/Documents/2/666777/DE/EP/somefile.pdf
    Use a path you already know the answer for (exists or not), to confirm
    the path convention Get-RenToMainNuxeoPath assumes is actually correct.

.PARAMETER SkipCertificateCheck
    Skip TLS certificate validation. Only use this if you understand the
    risk (e.g. a known internal certificate issue) - default is to validate
    normally.

.EXAMPLE
    .\Test-NuxeoConnection.ps1

.EXAMPLE
    .\Test-NuxeoConnection.ps1 -TestPath '/Workspaces/Patricia/Documents/2/666777/DE/EP/somefile.pdf'
#>
[CmdletBinding()]
param(
    [string] $CredentialFilePath = (Join-Path $PSScriptRoot 'nuxeo.credentials.txt'),
    [string] $BaseUrl = 'https://ndc-edms-01.corp.withersrogers.com/nuxeo',
    [string] $TestPath,
    [switch] $SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'

function Read-NuxeoCredentialFile {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw @"
Credential file not found: $Path

Create it as PLAIN TEXT with two lines, e.g.:
    Username=svc_account
    Password=the_password

WARNING: this is a plain-text file - only use it for this one-off
connectivity test, delete it afterwards, and never commit it to git.
"@
    }

    $username = $null
    $password = $null
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*Username\s*=\s*(.*)$') { $username = $Matches[1].Trim() }
        if ($line -match '^\s*Password\s*=\s*(.*)$') { $password = $Matches[1].Trim() }
    }
    if ((-not $username) -or (-not $password)) {
        throw "Credential file '$Path' must contain both a 'Username=' line and a 'Password=' line."
    }
    return @{ Username = $username; Password = $password }
}

Write-Host "Reading credentials from: $CredentialFilePath"
$parsed = Read-NuxeoCredentialFile -Path $CredentialFilePath
Write-Host "  Username: $($parsed.Username)"

$secure = ConvertTo-SecureString -String $parsed.Password -AsPlainText -Force

Write-Host ''
Write-Host 'Building a PSCredential object ...'
try {
    $cred = New-Object System.Management.Automation.PSCredential($parsed.Username, $secure)
    Write-Host '  OK'
}
catch {
    Write-Host '  FAILED' -ForegroundColor Red
    Write-Host ''
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Host '  This usually means PowerShell is running under Constrained Language Mode' -ForegroundColor Yellow
    Write-Host '  and building a PSCredential this way is blocked in your environment.' -ForegroundColor Yellow
    Write-Host '  Check with:  $ExecutionContext.SessionState.LanguageMode' -ForegroundColor Yellow
    Write-Host '  If that is ConstrainedLanguage, this specific approach cannot work here -' -ForegroundColor Yellow
    Write-Host '  report this back, we will need a different auth approach (e.g. an API' -ForegroundColor Yellow
    Write-Host '  token instead of username/password, or an IT-side policy change).' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host "Baseline reachability check: $BaseUrl (no auth, no specific API route) ..."
$baseParams = @{ Uri = $BaseUrl; Method = 'Get'; ErrorAction = 'Stop'; UseBasicParsing = $true }
if ($SkipCertificateCheck) { $baseParams.SkipCertificateCheck = $true }
try {
    $baseResp = Invoke-WebRequest @baseParams
    Write-Host "  Reachable - HTTP $($baseResp.StatusCode)." -ForegroundColor Green
}
catch {
    $baseStatus = $null
    if ($_.Exception.Response) { $baseStatus = [int]$_.Exception.Response.StatusCode }
    if ($baseStatus) {
        Write-Host "  Reachable, but HTTP $baseStatus - server responded, that's still useful to know." -ForegroundColor Yellow
    }
    else {
        Write-Host "  UNREACHABLE: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  -> Check VPN/network and the URL itself before going further.' -ForegroundColor Yellow
    }
}

function Write-NuxeoFailureDiagnosis {
    param($ErrorRecord, [string] $Context)

    Write-Host '  FAILED' -ForegroundColor Red
    $statusCode = $null
    if ($ErrorRecord.Exception.Response) { $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode }
    if ($statusCode) { Write-Host "  HTTP status: $statusCode" -ForegroundColor Red }
    Write-Host "  $($ErrorRecord.Exception.Message)" -ForegroundColor Red
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        Write-Host ''
        Write-Host '  Response body (this usually has the real reason):' -ForegroundColor Red
        Write-Host "  $($ErrorRecord.ErrorDetails.Message)" -ForegroundColor Red
    }
    if ($statusCode -eq 401) {
        Write-Host '  -> Username or password is wrong, or this account has no Nuxeo access.' -ForegroundColor Yellow
    }
    elseif ($statusCode -eq 500) {
        Write-Host "  -> The request reached Nuxeo and it accepted the connection, but $Context" -ForegroundColor Yellow
        Write-Host '     threw server-side. See the response body above for the real cause.' -ForegroundColor Yellow
    }
    elseif (-not $statusCode) {
        Write-Host '  -> Could not reach the server at all: check VPN/network, the URL itself,' -ForegroundColor Yellow
        Write-Host '     and TLS/certificate issues (only try -SkipCertificateCheck if you' -ForegroundColor Yellow
        Write-Host '     understand the risk and know it is a known internal cert issue).' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host "Calling $BaseUrl/api/v1/path/ (repository root - the same endpoint style" -NoNewline
Write-Host ' Add-RenToMainVerification uses for document existence checks) ...'
$rootParams = @{
    Uri         = "$($BaseUrl.TrimEnd('/'))/api/v1/path/"
    Method      = 'Get'
    Credential  = $cred
    ErrorAction = 'Stop'
}
if ($SkipCertificateCheck) { $rootParams.SkipCertificateCheck = $true }

$rootOk = $false
try {
    $root = Invoke-RestMethod @rootParams
    Write-Host '  Login + API OK.' -ForegroundColor Green
    Write-Host "  Repository root title: $($root.title)"
    $rootOk = $true
}
catch {
    Write-NuxeoFailureDiagnosis -ErrorRecord $_ -Context 'the /api/v1/path/ call'
}

Write-Host ''
Write-Host "Calling $BaseUrl/api/v1/me (optional - Nuxeo 7.x may not implement this endpoint at all, a failure here doesn't necessarily mean anything is wrong) ..."
$meParams = @{
    Uri         = "$($BaseUrl.TrimEnd('/'))/api/v1/me"
    Method      = 'Get'
    Credential  = $cred
    ErrorAction = 'Stop'
}
if ($SkipCertificateCheck) { $meParams.SkipCertificateCheck = $true }

try {
    $me = Invoke-RestMethod @meParams
    Write-Host '  OK.' -ForegroundColor Green
    Write-Host "  Nuxeo reports you as: $($me.id)"
}
catch {
    Write-NuxeoFailureDiagnosis -ErrorRecord $_ -Context 'the /api/v1/me call (this endpoint may simply not exist on your Nuxeo version)'
}

if ($TestPath) {
    Write-Host ''
    Write-Host "Checking path: $TestPath ..."
    $segments = $TestPath.Trim('/') -split '/'
    $encodedSegments = foreach ($s in $segments) { [System.Uri]::EscapeDataString($s) }
    $pathUrl = "$($BaseUrl.TrimEnd('/'))/api/v1/path/$($encodedSegments -join '/')"

    $pathParams = @{
        Uri         = $pathUrl
        Method      = 'Get'
        Credential  = $cred
        ErrorAction = 'Stop'
    }
    if ($SkipCertificateCheck) { $pathParams.SkipCertificateCheck = $true }

    try {
        $doc = Invoke-RestMethod @pathParams
        Write-Host '  EXISTS' -ForegroundColor Green
        Write-Host "  Title: $($doc.title)"
        Write-Host "  Path:  $($doc.path)"
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if ($statusCode -eq 404) {
            Write-Host '  NOT FOUND (404) - either genuinely missing, or the path convention is wrong.' -ForegroundColor Yellow
            Write-Host "  URL tried: $pathUrl" -ForegroundColor Yellow
        }
        else {
            Write-Host "  FAILED (status: $statusCode): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host 'Done.'
