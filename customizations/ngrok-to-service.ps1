# Convert ngrok from a hammer-style scheduled task to a proper Windows service.
#
# Diagnosis: the ngrok-aras-tunnel scheduled task fires every 5 min and runs
#   ngrok http 80 --url default.internal
# When the previous run is still online (or its session lingers), the new
# attempt is rejected by ngrok cloud with ERR_NGROK_334 and terminates,
# sometimes also kicking the working agent offline. Result: 57 collision
# events + 19 successful starts in one morning.
#
# Fix:
# 1. Disable the boot-trigger scheduled task.
# 2. Stop any currently-running ngrok agents.
# 3. Bake the tunnel definition into ngrok.yml so the service knows what to start.
# 4. Install ngrok as a Windows service via the agent's built-in command.
# 5. Start the service. Verify via the local API.
#
# Idempotent: safe to re-run.

param(
    [string]$NgrokExe       = 'C:\Tools\ngrok\ngrok.exe',
    [string]$NgrokConfig    = 'C:\Tools\ngrok\ngrok.yml',
    [string]$TaskName       = 'ngrok-aras-tunnel',
    [string]$TunnelName     = 'aras',
    [string]$BackendAddr    = '80',
    [string]$EndpointUrl    = 'default.internal'
)

$ErrorActionPreference = 'Stop'
function Section($t) { Write-Host ''; Write-Host ('=' * 60); Write-Host "  $t"; Write-Host ('=' * 60) }

if (-not (Test-Path $NgrokExe))   { throw "ngrok.exe not found at $NgrokExe" }
if (-not (Test-Path $NgrokConfig)) { throw "ngrok.yml not found at $NgrokConfig" }

# 1. Disable the scheduled task so it stops re-firing -----------------------
Section '1. Disable scheduled task'
$task = schtasks /Query /TN $TaskName 2>&1
if ($LASTEXITCODE -eq 0) {
    schtasks /Change /TN $TaskName /DISABLE 2>&1 | Out-Host
    Write-Host "  Task '$TaskName' disabled (kept around for reference; delete later if you want)."
} else {
    Write-Host "  No task named '$TaskName' found. Nothing to disable."
}

# 2. Stop any running ngrok agents so the cloud session can clear -----------
Section '2. Kill running ngrok agents'
$running = Get-Process ngrok -ErrorAction SilentlyContinue
if ($running) {
    $running | Stop-Process -Force
    Write-Host ("  Stopped " + $running.Count + " ngrok process(es). Waiting 20s for cloud session to clear...")
    Start-Sleep -Seconds 20
} else {
    Write-Host '  No ngrok processes running.'
}

# 3. Bake the tunnel into ngrok.yml -----------------------------------------
Section '3. Update ngrok.yml with tunnel definition'
$existing = Get-Content $NgrokConfig -Raw
$backupPath = $NgrokConfig + '.preService-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak'
if (-not (Test-Path "$NgrokConfig.preService-*.bak")) {
    Copy-Item $NgrokConfig $backupPath
    Write-Host "  Backup: $backupPath"
}

# Already wired up? Idempotent skip.
if ($existing -match "(?ms)^\s*tunnels:\s*[\r\n]+\s*${TunnelName}:") {
    Write-Host "  ngrok.yml already declares tunnel '$TunnelName'. Leaving as-is."
} else {
    # Append tunnel block. The yaml is whitespace-significant.
    $tunnelBlock = @"

tunnels:
  ${TunnelName}:
    proto: http
    addr: ${BackendAddr}
    url: ${EndpointUrl}
"@
    Add-Content -Path $NgrokConfig -Value $tunnelBlock
    Write-Host "  Appended tunnel block ('$TunnelName' -> $BackendAddr / $EndpointUrl)"
}

Write-Host '  Final config (tunnels section, secrets redacted):'
Select-String -Path $NgrokConfig -Pattern '^tunnels:|^\s+\w+:|^\s+(proto|addr|url):' |
    Where-Object { $_.Line -notmatch '^\s*authtoken:' } |
    ForEach-Object { Write-Host ('    ' + $_.Line) }

# 4. Install as a Windows service -------------------------------------------
Section '4. Install ngrok as a Windows service'
$svcExisting = Get-Service ngrok -ErrorAction SilentlyContinue
if ($svcExisting) {
    Write-Host "  Service 'ngrok' already exists (state: $($svcExisting.Status)). Stopping and uninstalling first to refresh config."
    if ($svcExisting.Status -eq 'Running') { Stop-Service ngrok -Force }
    & $NgrokExe service uninstall --config $NgrokConfig 2>&1 | ForEach-Object { Write-Host "    $_" }
    Start-Sleep -Seconds 3
}
& $NgrokExe service install --config $NgrokConfig 2>&1 | ForEach-Object { Write-Host "    $_" }
if ($LASTEXITCODE -ne 0) { throw "ngrok service install failed (exit $LASTEXITCODE)" }

# 5. Start and verify --------------------------------------------------------
Section '5. Start service'
& $NgrokExe service start 2>&1 | ForEach-Object { Write-Host "    $_" }
Start-Sleep -Seconds 5

Section 'Service status'
Get-Service ngrok | Format-Table Name, Status, StartType -AutoSize | Out-Host

Section 'Local API tunnels'
try {
    $r = Invoke-RestMethod 'http://127.0.0.1:4040/api/tunnels' -TimeoutSec 5
    if (-not $r.tunnels -or $r.tunnels.Count -eq 0) {
        Write-Host '  Local API reachable but no tunnels yet (may still be establishing).'
    } else {
        $r.tunnels | ForEach-Object { Write-Host ("  " + $_.name + ": " + $_.public_url + " -> " + $_.config.addr + " (" + $_.proto + ")") }
    }
} catch {
    Write-Host "  Local API not reachable yet: $($_.Exception.Message)"
    Write-Host '  Wait ~10s and try: Invoke-RestMethod http://127.0.0.1:4040/api/tunnels'
}

Section 'Service log tail (last 20 lines)'
$serviceLog = 'C:\Tools\ngrok\logs\ngrok.log'
if (Test-Path $serviceLog) {
    Get-Content $serviceLog -Tail 20 | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "  $serviceLog not found yet (service may write somewhere else; check Get-Service ngrok)."
}

Write-Host ''
Write-Host 'Done. The service will auto-start on boot via Windows SCM.'
Write-Host 'To revert: ngrok service uninstall --config ' + $NgrokConfig
Write-Host '          schtasks /Change /TN ' + $TaskName + ' /ENABLE'
