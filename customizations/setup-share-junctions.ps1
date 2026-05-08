# Expose the Aras Innovator install root through the existing C:\Share SMB share
# via a Windows directory junction. Idempotent. Run as Administrator.
#
# After this runs, the Linux side that has the share mounted at /mnt/aras-share
# can read AND write live install files directly:
#   /mnt/aras-share/innovator/Innovator/Client/...
#   /mnt/aras-share/innovator/OAuthServer/...
#   /mnt/aras-share/innovator/Innovator/Server/...
# No more PowerShell heredoc patches for routine file edits.

param(
    [string]$InnovatorRoot = 'C:\Program Files (x86)\Aras\Innovator',
    [string]$ShareRoot     = 'C:\Share'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $InnovatorRoot)) { throw "Innovator root not found: $InnovatorRoot" }
if (-not (Test-Path $ShareRoot))     { throw "Share root not found: $ShareRoot" }

$junction = Join-Path $ShareRoot 'innovator'

if (Test-Path $junction) {
    $item = Get-Item $junction -Force
    $isJunction = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    if ($isJunction -and $item.Target -and ($item.Target | ForEach-Object { $_ -ieq $InnovatorRoot } | Where-Object { $_ })) {
        Write-Host "Junction already exists and points at $InnovatorRoot. Nothing to do."
        return
    }
    Write-Warning "Path exists at $junction but is not the expected junction. Aborting."
    Write-Warning ("  Target(s): " + ($item.Target -join ', '))
    return
}

# cmd.exe's mklink /J is the simplest and most reliable way to create a junction.
$out = & cmd.exe /c "mklink /J `"$junction`" `"$InnovatorRoot`"" 2>&1
Write-Host $out
if (-not (Test-Path $junction)) { throw "Junction creation failed." }

Write-Host ""
Write-Host "Created junction: $junction  ->  $InnovatorRoot"
Write-Host "Linux: /mnt/aras-share/innovator/"
