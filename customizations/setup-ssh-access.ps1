# Set up SSH key access on the Aras VM for the Claude agent.
#
# Run as Administrator (RDP console works regardless; remote PSSession works
# only if LocalAccountTokenFilterPolicy=1 has been set so DISM is allowed).
#
# What it does (each step is idempotent):
#   1. Verify elevation up front; bail with a clear message if not elevated.
#   2. Install the OpenSSH.Server Windows capability if not present.
#   3. Start the sshd service, set startup type Automatic.
#   4. Open inbound firewall port 22.
#   5. Place the agent public key into
#      C:\ProgramData\ssh\administrators_authorized_keys (the path Windows
#      OpenSSH reads for accounts in the local Administrators group; the
#      per-user ~/.ssh/authorized_keys is ignored for those accounts).
#   6. Lock down ACLs on that file - sshd silently refuses if anyone other
#      than Administrators or SYSTEM can write to it.
#   7. Set PowerShell (pwsh if available, otherwise powershell.exe) as the
#      default SSH login shell so commands run from the agent land in PS.
#   8. Restart sshd to pick up the registry change, then print state.
#
# Usage (Admin shell on the VM):
#   powershell -ExecutionPolicy Bypass -File C:\Share\customizations\setup-ssh-access.ps1
#
# Optional override (if you ever rotate the agent key, replace the value):
#   -PublicKey 'ssh-ed25519 AAAA... agent@host'

param(
    [string]$PublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAgTl3nK7xxSjUKk4Gcie4JGgRDNM6flKwfZ7GGLPrgU root@workstation-ws04'
)

$ErrorActionPreference = 'Stop'

function Section($t) {
    Write-Host ''
    Write-Host ('=' * 60)
    Write-Host "  $t"
    Write-Host ('=' * 60)
}

# 1. Elevation check ---------------------------------------------------------
Section '1. Elevation check'
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  Current user: $($identity.Name)"
    Write-Host '  ERROR: Not running with elevated rights. Re-run from an elevated PowerShell.'
    Write-Host '         (Right-click PowerShell -> Run as Administrator, OR via RDP console,'
    Write-Host '          OR set LocalAccountTokenFilterPolicy=1 and re-enter the PSSession.)'
    exit 1
}
Write-Host "  OK: running elevated as $($identity.Name)"

# 2. Install OpenSSH.Server --------------------------------------------------
Section '2. OpenSSH.Server capability'
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue
if ($cap -and $cap.State -eq 'Installed') {
    Write-Host "  Already installed: $($cap.Name)"
} else {
    Write-Host '  Installing OpenSSH.Server (this may take a minute)...'
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    Write-Host '  Installed.'
}

# 3. Service start + auto-start ----------------------------------------------
Section '3. sshd service'
$svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
if (-not $svc) { throw "sshd service still missing after install. Reboot may be required." }

if ($svc.StartType -ne 'Automatic') {
    Set-Service -Name sshd -StartupType Automatic
    Write-Host '  Set StartupType: Automatic'
}
if ($svc.Status -ne 'Running') {
    Start-Service sshd
    Write-Host '  Started sshd'
} else {
    Write-Host '  sshd already running'
}

# 4. Firewall ----------------------------------------------------------------
Section '4. Firewall rule for port 22'
$rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Write-Host '  Created inbound TCP/22 rule'
} elseif ($rule.Enabled -ne 'True') {
    Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' | Out-Null
    Write-Host '  Enabled existing inbound TCP/22 rule'
} else {
    Write-Host '  Inbound TCP/22 rule already enabled'
}

# 5. Authorize public key for Administrators ---------------------------------
Section '5. administrators_authorized_keys'
$adminKeys = 'C:\ProgramData\ssh\administrators_authorized_keys'
$adminKeysDir = Split-Path $adminKeys
if (-not (Test-Path $adminKeysDir)) {
    New-Item -ItemType Directory -Path $adminKeysDir -Force | Out-Null
}
if (-not (Test-Path $adminKeys)) {
    New-Item -ItemType File -Path $adminKeys -Force | Out-Null
    Write-Host "  Created empty $adminKeys"
}

$existing = Get-Content $adminKeys -Raw -ErrorAction SilentlyContinue
# Compare on the middle of the key, which is unique enough but tolerant of CRLF / trailing whitespace.
$keyFingerprintWindow = if ($PublicKey.Length -ge 80) { $PublicKey.Substring(40, 40) } else { $PublicKey }
if ($existing -and $existing.Contains($keyFingerprintWindow)) {
    Write-Host '  Public key already present.'
} else {
    Add-Content -Path $adminKeys -Value $PublicKey
    Write-Host '  Public key appended.'
}

# 6. Lock down ACLs (mandatory for sshd to honor the file) -------------------
Section '6. ACLs on administrators_authorized_keys'
icacls $adminKeys /inheritance:r /grant 'Administrators:F' 'SYSTEM:F' | Out-Null
Write-Host '  Stripped inheritance, granted Administrators:F SYSTEM:F'
Write-Host '  Resulting ACL:'
icacls $adminKeys | ForEach-Object { Write-Host "    $_" }

# 7. Default SSH shell -> PowerShell -----------------------------------------
Section '7. Default SSH shell'
$pwshPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwshPath) { $pwshPath = (Get-Command powershell.exe).Source }
$current  = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
if ($current -eq $pwshPath) {
    Write-Host "  Already set: DefaultShell = $pwshPath"
} else {
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
        -Value $pwshPath -PropertyType String -Force | Out-Null
    Write-Host "  Set DefaultShell = $pwshPath"
}

# 8. Restart sshd + final state ----------------------------------------------
Section '8. Restart sshd, final state'
Restart-Service sshd
Start-Sleep -Seconds 2
Get-Service sshd | Format-Table Name, Status, StartType -AutoSize | Out-String -Width 120 | Write-Host

Write-Host ''
Write-Host 'Done. From the agent host, test with:'
Write-Host '    ssh Administrator@192.168.1.104 hostname'
Write-Host 'Expected output: ARAS-WIN22K2'
