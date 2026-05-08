# Patch the Aras Method `cui_common_layouts_init` to guard the unsafe
# destructure that fails for users with no saved favorite layout:
#
#   const { pagination } = favoriteLayoutData.settings;
#                                              ^^^^^^^ undefined for new users
#
# Replace with:
#
#   const { pagination } = (favoriteLayoutData && favoriteLayoutData.settings) || {};
#
# Idempotent: skips the rewrite if the patched marker is already present, and
# never blindly INSERTs new rows - only UPDATEs an existing Method.
#
# Usage (as Administrator on the Aras VM):
#   powershell -ExecutionPolicy Bypass -File C:\Share\customizations\patch-cui-method.ps1
#   powershell -ExecutionPolicy Bypass -File C:\Share\customizations\patch-cui-method.ps1 -DryRun

param(
    [string]$Server     = 'localhost\SQLEXPRESS',
    [string]$Database   = 'InnovatorSolutions',
    [string]$DbUser     = 'innovator',
    [string]$DbPassword = 'ArasDB-2025!',
    [string]$MethodName = 'cui_common_layouts_init',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---- SQL helpers ----
Add-Type -AssemblyName 'System.Data'

function Open-Connection {
    $cs = "Server=$Server;Database=$Database;User ID=$DbUser;Password=$DbPassword;TrustServerCertificate=True"
    $c = New-Object System.Data.SqlClient.SqlConnection $cs
    $c.Open()
    return $c
}

function Get-Method($conn, $name) {
    # Pick the current generation. Aras keeps history rows in the same table; updating an
    # historical row would not change what the SPA serves, so target is_current = '1' only.
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = @"
SELECT TOP 1 id, method_code
FROM innovator.[METHOD]
WHERE name = @n AND is_current = '1'
ORDER BY generation DESC
"@
    [void]$cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@n', [System.Data.SqlDbType]::NVarChar, 256)))
    $cmd.Parameters['@n'].Value = $name
    $r = $cmd.ExecuteReader()
    try {
        if ($r.Read()) { return @{ id = $r['id']; code = [string]$r['method_code'] } }
        return $null
    } finally { $r.Close() }
}

function Update-MethodCode($conn, $id, $code) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = @"
UPDATE innovator.[METHOD]
SET method_code = @c,
    modified_on = SYSUTCDATETIME(),
    modified_by_id = '30B991F927274263BAEF6B0EE9C745EF'  -- Innovator Admin
WHERE id = @id
"@
    [void]$cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@id', [System.Data.SqlDbType]::NVarChar, 32)))
    [void]$cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@c',  [System.Data.SqlDbType]::NVarChar, -1)))
    $cmd.Parameters['@id'].Value = $id
    $cmd.Parameters['@c'].Value  = $code
    return $cmd.ExecuteNonQuery()
}

# ---- Main ----
$conn = Open-Connection
try {
    $m = Get-Method $conn $MethodName
    if (-not $m) {
        Write-Warning "Method '$MethodName' not found in $Database. Nothing to patch."
        return
    }

    Write-Host ("Method found: id=" + $m.id + ", body length=" + $m.code.Length + " chars")

    if ($m.code -match 'RC_PATCH_cui_common_layouts_init_v1') {
        Write-Host "Already patched (marker present). Nothing to do."
        return
    }

    # Show the lines around the unsafe destructure for visibility
    $lines = $m.code -split "(`r`n|`n)"
    $hits = @()
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match 'favoriteLayoutData\.settings') { $hits += $i }
    }
    if ($hits.Count -eq 0) {
        Write-Warning "No reference to 'favoriteLayoutData.settings' found in the method body. Aborting without changes."
        Write-Warning "(The method body may have been customized away; review the method manually.)"
        return
    }
    Write-Host ""
    Write-Host "Lines mentioning 'favoriteLayoutData.settings':"
    foreach ($i in $hits) {
        $start = [Math]::Max(0, $i - 1)
        $end   = [Math]::Min($lines.Length - 1, $i + 1)
        for ($j = $start; $j -le $end; $j++) {
            $marker = if ($j -eq $i) { ' >> ' } else { '    ' }
            Write-Host ("  " + ('{0,4}' -f ($j + 1)) + $marker + $lines[$j])
        }
        Write-Host '  ----'
    }

    # Surgical regex: convert the unsafe destructure into a guarded one.
    # We match `= favoriteLayoutData.settings` (and consume the trailing `;` so
    # we can reattach it) but ONLY when it's NOT already followed by `||` or
    # `??`. We don't touch anything else in the body.
    $pattern  = '=\s*favoriteLayoutData\.settings(?!\s*(\|\||\?\?))\s*;'
    $replace  = '= (favoriteLayoutData && favoriteLayoutData.settings) || {};'
    $patched  = [regex]::Replace($m.code, $pattern, $replace)

    if ($patched -eq $m.code) {
        Write-Warning "Pattern matched no occurrences with the surgical replace. The method body's syntax differs from the assumed shape."
        Write-Warning "Open the method in the Aras admin UI and patch by hand, then re-run with the marker added."
        return
    }

    # Insert idempotency marker as a leading comment so future runs short-circuit.
    $marker = "// RC_PATCH_cui_common_layouts_init_v1: guarded favoriteLayoutData.settings destructure" + [Environment]::NewLine
    $patched = $marker + $patched

    Write-Host ""
    Write-Host ("Replacement count: " + ([regex]::Matches($m.code, $pattern)).Count)
    Write-Host ("New body length:   " + $patched.Length + " chars")

    if ($DryRun) {
        Write-Host ""
        Write-Host "DryRun mode - not writing. Use without -DryRun to apply."
        return
    }

    $rows = Update-MethodCode $conn $m.id $patched
    Write-Host ""
    Write-Host ("UPDATE affected rows: " + $rows)
    Write-Host ("Done. Method '" + $MethodName + "' is patched.")
    Write-Host ""
    Write-Host "Note: the SPA caches method bodies via the service worker's metadata cache."
    Write-Host "After this patch, end users should hard-refresh (Ctrl+Shift+R) or unregister"
    Write-Host "the SW once for the new method body to take effect."
}
finally {
    $conn.Close()
    $conn.Dispose()
}
