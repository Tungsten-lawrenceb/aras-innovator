Import-Module WebAdministration

$pools = @(
    'Aras Innovator AppPool ASP.NET Core',
    'Aras OAuth AppPool ASP.NET Core',
    'Aras Vault AppPool ASP.NET Core'
)

foreach ($p in $pools) {
    $exists = (Get-IISAppPool -Name $p -ErrorAction SilentlyContinue) -ne $null
    if (-not $exists) {
        Write-Host "skip (not found): $p"
        continue
    }
    Write-Host "==== $p ===="

    # 1. Disable idle timeout (was: 00:20:00 Terminate)
    Set-ItemProperty -Path "IIS:\AppPools\$p" -Name processModel.idleTimeout -Value '00:00:00'

    # 2. Always-running mode so the worker is started immediately on app pool start,
    #    not lazy on first request.
    Set-ItemProperty -Path "IIS:\AppPools\$p" -Name startMode -Value 'AlwaysRunning'

    # 3. Verify
    $cfg = Get-ItemProperty "IIS:\AppPools\$p"
    Write-Host ("  processModel.idleTimeout: " + $cfg.processModel.idleTimeout)
    Write-Host ("  startMode: " + $cfg.startMode)
}

Write-Host ""
Write-Host "==== Enable preload on the InnovatorServer site application(s) ===="
# Preload is per-application, not per-pool. The Default Web Site has the
# /InnovatorServer/Client and similar applications under it.
Get-WebApplication -Site 'Default Web Site' -EA SilentlyContinue |
    Where-Object { $_.ApplicationPool -match 'Aras' } |
    ForEach-Object {
        $appPath = "IIS:\Sites\Default Web Site$($_.Path)"
        try {
            Set-ItemProperty -Path $appPath -Name preloadEnabled -Value $true
            Write-Host ("  enabled preload: " + $_.Path + "  (pool: " + $_.ApplicationPool + ")")
        } catch {
            Write-Host ("  FAIL on " + $_.Path + ": " + $_.Exception.Message)
        }
    }

Write-Host ""
Write-Host "==== Final state ==="
foreach ($p in $pools) {
    $cfg = Get-ItemProperty "IIS:\AppPools\$p" -EA SilentlyContinue
    if ($cfg) {
        Write-Host ("  $p  idleTimeout=" + $cfg.processModel.idleTimeout + "  startMode=" + $cfg.startMode)
    }
}
