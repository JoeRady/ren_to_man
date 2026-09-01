<#
.SYNOPSIS
    Standalone Nuxeo REST API connectivity test - no dependency on the
    RenToMain module. Run this first to find out whether login even works
    in your environment, before relying on Add-RenToMainVerification /
    Test-RenToMainNuxeoDocumentExists in RenToMain.psm1.

.DESCRIPTION
    Reads Username/Password from a plain-text credential file and calls
    Nuxeo's "who am I" endpoint (/api/v1/me) to confirm the login works.
    Optionally also checks one specific document path if you pass -TestPath.

    This script is deliberately self-contained (no Import-Module) and
    reports each step's outcome plainly, including a clear diagnosis if
    PSCredential creation itself is blocked - which can happen under
    PowerShell Constrained Language Mode (see powershell/README.md) and is
    a real open question for this environment, not yet confirmed either way.

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

Write-Host ''
Write-Host "Calling $BaseUrl/api/v1/me (Nuxeo's 'who am I' check) ..."
$params = @{
    Uri         = "$($BaseUrl.TrimEnd('/'))/api/v1/me"
    Method      = 'Get'
    Credential  = $cred
    ErrorAction = 'Stop'
}
if ($SkipCertificateCheck) { $params.SkipCertificateCheck = $true }

try {
    $me = Invoke-RestMethod @params
    Write-Host '  Login OK.' -ForegroundColor Green
    Write-Host "  Nuxeo reports you as: $($me.id)"
}
catch {
    Write-Host '  FAILED' -ForegroundColor Red
    $statusCode = $null
    if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
    if ($statusCode) { Write-Host "  HTTP status: $statusCode" -ForegroundColor Red }
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        Write-Host ''
        Write-Host '  Response body (this usually has the real reason):' -ForegroundColor Red
        Write-Host "  $($_.ErrorDetails.Message)" -ForegroundColor Red
    }
    if ($statusCode -eq 401) {
        Write-Host '  -> Username or password is wrong, or this account has no Nuxeo access.' -ForegroundColor Yellow
    }
    elseif ($statusCode -eq 500) {
        Write-Host '  -> The request reached Nuxeo and it accepted the connection, but something' -ForegroundColor Yellow
        Write-Host '     threw server-side. See the response body above for the real cause - common' -ForegroundColor Yellow
        Write-Host '     ones: this Nuxeo version does not implement /api/v1/me the way expected,' -ForegroundColor Yellow
        Write-Host '     a required header is missing, or the account hit a server-side bug/quirk.' -ForegroundColor Yellow
        Write-Host '     Worth trying -TestPath against a known document even though this failed -' -ForegroundColor Yellow
        Write-Host '     the /api/v1/path/ endpoint might behave differently.' -ForegroundColor Yellow
    }
    elseif (-not $statusCode) {
        Write-Host '  -> Could not reach the server at all: check VPN/network, the URL itself,' -ForegroundColor Yellow
        Write-Host '     and TLS/certificate issues (only try -SkipCertificateCheck if you' -ForegroundColor Yellow
        Write-Host '     understand the risk and know it is a known internal cert issue).' -ForegroundColor Yellow
    }
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
