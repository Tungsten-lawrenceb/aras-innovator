# One-shot diagnostic for "site is down" while ngrok is up.
# Captures app pool / site / service state, recent error events, a local probe,
# and (if any pool is stopped) starts it.
#
# Run as Administrator on the Aras VM:
#   powershell -ExecutionPolicy Bypass -File C:\Share\customizations\diag-iis-down.ps1

$ErrorActionPreference = 'Continue'
Import-Module WebAdministration -ErrorAction SilentlyContinue

$banner = '=' * 60
function Write-Section($t) { Write-Host ''; Write-Host $banner; Write-Host "  $t"; Write-Host $banner }

Write-Section 'IIS app pools'
$pools = Get-IISAppPool 2>$null
if ($pools) {
    $pools | Select-Object Name, State, ManagedRuntimeVersion | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
} else {
    Write-Host '  Get-IISAppPool returned nothing.'
}

Write-Section 'IIS sites'
$sites = Get-IISSite 2>$null
if ($sites) {
    $sites | Select-Object Name, State, @{N='Binding';E={($_.Bindings.Collection | ForEach-Object { $_.bindingInformation }) -join ', '}} |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
} else {
    Write-Host '  Get-IISSite returned nothing.'
}

Write-Section 'W3SVC / WAS services'
Get-Service W3SVC, WAS -ErrorAction SilentlyContinue |
    Format-Table Name, Status, StartType -AutoSize | Out-String -Width 200 | Write-Host

Write-Section 'iisreset /status'
& iisreset /status 2>&1 | ForEach-Object { Write-Host "  $_" }

Write-Section 'Recent Application log errors / warnings (last 10 min)'
try {
    $cutoff = (Get-Date).AddMinutes(-10)
    Get-WinEvent -LogName Application -MaxEvents 60 -ErrorAction Stop |
        Where-Object { $_.TimeCreated -gt $cutoff -and $_.LevelDisplayName -in 'Error','Warning','Critical' } |
        Sort-Object TimeCreated |
        ForEach-Object {
            $msg = $_.Message
            if ($msg.Length -gt 220) { $msg = $msg.Substring(0,220) + '...' }
            Write-Host ("  {0:HH:mm:ss}  {1,-10}  {2}/{3}  {4}" -f $_.TimeCreated, $_.LevelDisplayName, $_.ProviderName, $_.Id, $msg)
        }
} catch {
    Write-Host "  Could not read Application log: $($_.Exception.Message)"
}

Write-Section 'Recent System log errors / warnings (last 10 min)'
try {
    $cutoff = (Get-Date).AddMinutes(-10)
    Get-WinEvent -LogName System -MaxEvents 60 -ErrorAction Stop |
        Where-Object { $_.TimeCreated -gt $cutoff -and $_.LevelDisplayName -in 'Error','Warning','Critical' } |
        Sort-Object TimeCreated |
        ForEach-Object {
            $msg = $_.Message
            if ($msg.Length -gt 220) { $msg = $msg.Substring(0,220) + '...' }
            Write-Host ("  {0:HH:mm:ss}  {1,-10}  {2}/{3}  {4}" -f $_.TimeCreated, $_.LevelDisplayName, $_.ProviderName, $_.Id, $msg)
        }
} catch {
    Write-Host "  Could not read System log: $($_.Exception.Message)"
}

Write-Section 'Aras processes'
Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match 'w3wp|Aras|InnovatorServer' } |
    Select-Object Id, ProcessName, StartTime, @{N='WS_MB';E={[math]::Round($_.WS/1MB,1)}} |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

Write-Section 'Local HTTP probe -> http://localhost/InnovatorServer/Client/'
try {
    $resp = Invoke-WebRequest 'http://localhost/InnovatorServer/Client/' -UseBasicParsing -TimeoutSec 8 -MaximumRedirection 0 -ErrorAction Stop
    Write-Host ("  StatusCode  : " + $resp.StatusCode)
    Write-Host ("  Server      : " + $resp.Headers['Server'])
    Write-Host ("  ContentLen  : " + $resp.RawContentLength)
} catch [System.Net.WebException] {
    $r = $_.Exception.Response
    if ($r) {
        Write-Host ("  StatusCode (from exception): " + [int]$r.StatusCode + ' ' + $r.StatusCode)
    } else {
        Write-Host ("  HTTP probe failed before response: " + $_.Exception.Message)
    }
} catch {
    Write-Host ("  HTTP probe failed: " + $_.Exception.Message)
}

Write-Section 'Auto-recovery (start any stopped pool)'
$stopped = @($pools | Where-Object { $_.State -ne 'Started' })
if ($stopped.Count -eq 0) {
    Write-Host '  All pools already Started; nothing to do.'
} else {
    foreach ($p in $stopped) {
        try {
            Start-WebAppPool -Name $p.Name
            Write-Host ("  Started: " + $p.Name)
        } catch {
            Write-Host ("  FAILED to start " + $p.Name + ": " + $_.Exception.Message)
        }
    }
}

Write-Host ''
Write-Host 'Done.'
