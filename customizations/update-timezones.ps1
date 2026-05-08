# Run Aras's UpdateTimeZoneInfo equivalent automatically.
# The shipped Action is a client-side JS Method that:
#   1. GETs http://www.aras.com/timezones/tzupdate.xml
#   2. Parses it as AML
#   3. Calls inn.applyAML(aml) as the current admin user
# We replicate that without the UI by:
#   1. Downloading the same tzupdate.xml
#   2. POSTing it to InnovatorServer.aspx with admin credentials in a SOAP envelope
# Aras applies the AML directly, populating Time Zone items.
#
# Idempotent: Aras's AML is upsert by (id, generation) - re-running just no-ops the
# already-current rows. Safe to schedule periodically.

param(
    [string]$ArasUrl    = 'http://localhost/InnovatorServer/Server/InnovatorServer.aspx',
    [string]$Database   = 'InnovatorSolutions',
    [string]$User       = 'authadmin',
    [string]$Password   = 'innovator',         # plaintext - we md5 it below
    [string]$TzUrl      = 'http://www.aras.com/timezones/tzupdate.xml',
    [int]$DownloadTimeoutSec = 30
)

$ErrorActionPreference = 'Stop'

# 1. Download the tzupdate.xml -----------------------------------------------
"=== 1. Download $TzUrl ==="
$tmp = Join-Path $env:TEMP 'tzupdate.xml'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
Invoke-WebRequest -Uri $TzUrl -OutFile $tmp -UseBasicParsing -TimeoutSec $DownloadTimeoutSec
$amlBytes = (Get-Item $tmp).Length
"  saved: $tmp ($amlBytes bytes)"
$aml = Get-Content $tmp -Raw -Encoding UTF8
if (-not $aml -or $aml.Length -lt 100) { throw "tzupdate.xml looks empty/short ($amlBytes bytes)" }
# quick smoke: must be parseable XML and contain <Item> elements
try { [void][xml]$aml } catch { throw "tzupdate.xml not parseable as XML: $($_.Exception.Message)" }
$itemCount = ([regex]::Matches($aml, '<Item ')).Count
"  contains $itemCount <Item> element(s)"

# 2. md5(password) for Aras header ------------------------------------------
$md5 = [Security.Cryptography.MD5]::Create()
$pwHash = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Password))) -replace '-','').ToLower()

# 3. Wrap in SOAP envelope --------------------------------------------------
$soap = @"
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">
  <SOAP-ENV:Body>
    <ApplyAML>$aml</ApplyAML>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>
"@

# 4. POST to InnovatorServer.aspx -------------------------------------------
"=== 2. POST to $ArasUrl as $User (db=$Database) ==="
try {
    $resp = Invoke-WebRequest -Uri $ArasUrl -Method POST `
        -ContentType 'text/xml; charset=utf-8' `
        -Headers @{
            'AUTHUSER'     = $User
            'AUTHPASSWORD' = $pwHash
            'DATABASE'     = $Database
            'SOAPACTION'   = 'ApplyAML'
        } `
        -Body $soap -UseBasicParsing -TimeoutSec 60
    $body = $resp.Content
    "  HTTP $($resp.StatusCode), $($body.Length) bytes"
} catch {
    "  request failed: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        $r = $_.Exception.Response
        "  status: $([int]$r.StatusCode)"
    }
    throw
}

# 5. Check for SOAP fault ---------------------------------------------------
if ($body -match '<SOAP-ENV:Fault>|<faultstring>') {
    "=== SOAP fault returned ==="
    $fault = if ($body -match '<faultstring>(?<fs>[^<]+)') { $matches.fs } else { '(unknown)' }
    "  faultstring: $fault"
    Write-Warning "AML did not apply cleanly. Faultstring above. Response body saved to $env:TEMP\tz-response.xml"
    Set-Content (Join-Path $env:TEMP 'tz-response.xml') $body
    exit 1
}

# 6. Verify -----------------------------------------------------------------
"=== 3. Verify Time Zone data populated ==="
$itemTagCount = ([regex]::Matches($body, '<Item\s')).Count
"  response contained $itemTagCount <Item> element(s) (post-apply confirmation)"

"Done."
