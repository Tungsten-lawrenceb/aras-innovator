# Truncate Aras Innovator log files that are currently held open by IIS / OAuthServer / Client.
# Run as Administrator on the Aras VM. Idempotent.
# The producer processes have these files open for append; we open with FileShare.ReadWrite|Delete
# (which Windows allows even when another handle is appending) and call SetLength(0).

$ErrorActionPreference = 'Continue'

$bases = @(
    'C:\Program Files (x86)\Aras\Innovator\Innovator\OAuthServer\logs',
    'C:\Program Files (x86)\Aras\Innovator\Innovator\Client\logs',
    'C:\Program Files (x86)\Aras\Innovator\Innovator\Server\logs',
    'C:\inetpub\logs\LogFiles\W3SVC1'
)

$truncated = 0; $skipped = 0
foreach ($base in $bases) {
    if (-not (Test-Path $base)) { continue }
    Get-ChildItem -Path $base -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $fs = [System.IO.File]::Open(
                $_.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            $fs.SetLength(0)
            $fs.Close()
            $truncated++
        } catch {
            $skipped++
            Write-Host ("SKIP " + $_.FullName + " :: " + $_.Exception.Message)
        }
    }
}
Write-Host ("Truncated: " + $truncated + "  Skipped: " + $skipped)
