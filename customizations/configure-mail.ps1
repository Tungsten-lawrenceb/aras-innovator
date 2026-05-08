# Configure Aras to send mail via Microsoft Graph (OAuth2 client credentials)
# instead of SMTP. Updates BOTH InnovatorServerConfig.xml files (root and
# Innovator/Server/). Idempotent: replaces existing <Mail .../> element.
#
# Aras 14.35 schema (from Aras.Server.Core.ConfigSections.SmtpServerConfig):
#   <Mail SMTPServer="" deliveryMethod="MicrosoftGraphApi"
#         tenantId="..." clientId="..." clientSecret="..." />
#
# When deliveryMethod=MicrosoftGraphApi, the rest of the SMTP-only attributes
# (SMTPServerPort, user, password, enableSsl) are ignored.

param(
    [Parameter(Mandatory=$true)][string]$TenantId,
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ClientSecret,
    [string]$InnovatorRoot = 'C:\Program Files (x86)\Aras\Innovator'
)

$ErrorActionPreference = 'Stop'

$configs = @(
    Join-Path $InnovatorRoot 'InnovatorServerConfig.xml'
    Join-Path $InnovatorRoot 'Innovator\Server\InnovatorServerConfig.xml'
)

foreach ($cfg in $configs) {
    if (-not (Test-Path $cfg)) {
        Write-Host "  skip (not found): $cfg"
        continue
    }
    Write-Host ""
    Write-Host "==== $cfg ===="

    # Backup once
    $bak = $cfg + '.preMailGraph-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak'
    if (-not (Test-Path "$cfg.preMailGraph-*.bak")) {
        Copy-Item $cfg $bak
        Write-Host "  backup: $bak"
    }

    [xml]$x = New-Object System.Xml.XmlDocument
    $x.PreserveWhitespace = $true
    $x.Load($cfg)

    $mail = $x.SelectSingleNode('/Innovator/Mail')
    if (-not $mail) {
        # No Mail element yet (unlikely - the install always creates one); add it
        $mail = $x.CreateElement('Mail')
        $x.DocumentElement.AppendChild($mail) | Out-Null
        Write-Host "  created new <Mail> element"
    } else {
        Write-Host "  existing <Mail> element found - updating"
    }

    # Set/replace the Graph-API attributes; keep SMTPServer empty so the SMTP path
    # short-circuits and Graph is selected via deliveryMethod.
    $mail.SetAttribute('SMTPServer', '')
    $mail.SetAttribute('deliveryMethod', 'MicrosoftGraphApi')
    $mail.SetAttribute('tenantId', $TenantId)
    $mail.SetAttribute('clientId', $ClientId)
    $mail.SetAttribute('clientSecret', $ClientSecret)

    # Remove stale SMTP-AUTH attributes if present (they're ignored by Graph
    # path but cleaner without them).
    foreach ($a in 'SMTPServerPort','user','password','enableSsl','pickupDirectoryLocation') {
        if ($mail.HasAttribute($a)) { $mail.RemoveAttribute($a) }
    }

    $x.Save($cfg)
    Write-Host "  written: $cfg"

    # Show the resulting line (with secret redacted)
    $line = ((Get-Content $cfg) | Where-Object { $_ -match '<Mail ' }) -replace 'clientSecret="[^"]+"', 'clientSecret="***"'
    Write-Host "  result: $line"
}

Write-Host ""
Write-Host "==== Recycle Aras Innovator pool ===="
Import-Module WebAdministration
Restart-WebAppPool -Name 'Aras Innovator AppPool ASP.NET Core'
Start-Sleep -Seconds 4
$state = (Get-IISAppPool -Name 'Aras Innovator AppPool ASP.NET Core').State
Write-Host "  pool state: $state"

Write-Host ""
Write-Host "Done."
