# Generic Aras Variable UPSERT.
# Same pattern as set-corporate-tz.ps1 but parameterized so any Variable
# can be set without writing a one-off script per Variable.
#
# Idempotent: no-op if the value already matches.

param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Value,
    [string]$Server     = 'localhost\SQLEXPRESS',
    [string]$Database   = 'InnovatorSolutions',
    [string]$DbUser     = 'innovator',
    [string]$DbPassword = 'ArasDB-2025!'
)

$ErrorActionPreference = 'Stop'

$cs = "Server=$Server;Database=$Database;User ID=$DbUser;Password=$DbPassword;TrustServerCertificate=True"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()

try {
    # Find current generation
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT TOP 1 id, value FROM innovator.[VARIABLE] WHERE name = @n AND is_current = '1' ORDER BY generation DESC"
    [void]$cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@n', [System.Data.SqlDbType]::NVarChar, 256)))
    $cmd.Parameters['@n'].Value = $Name
    $r = $cmd.ExecuteReader()
    $existing = if ($r.Read()) { @{ id = [string]$r['id']; value = [string]$r['value'] } } else { $null }
    $r.Close()

    if ($existing) {
        Write-Host ("Found existing Variable '" + $Name + "' id=" + $existing.id + " value='" + $existing.value + "'")
        if ($existing.value -eq $Value) {
            Write-Host "Already set to '$Value'. Nothing to do."
            return
        }
        $upd = $conn.CreateCommand()
        $upd.CommandText = @"
UPDATE innovator.[VARIABLE]
SET value = @v,
    modified_on = SYSUTCDATETIME(),
    modified_by_id = '30B991F927274263BAEF6B0EE9C745EF'
WHERE id = @id
"@
        [void]$upd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@v',  [System.Data.SqlDbType]::NVarChar, -1)))
        [void]$upd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@id', [System.Data.SqlDbType]::NVarChar, 32)))
        $upd.Parameters['@v'].Value = $Value
        $upd.Parameters['@id'].Value = $existing.id
        $rows = $upd.ExecuteNonQuery()
        Write-Host ("Updated. Rows: " + $rows + ". value: '" + $existing.value + "' -> '" + $Value + "'")
        return
    }

    # INSERT new
    Write-Host ("Variable '" + $Name + "' not found. Inserting.")
    $newId = ([guid]::NewGuid().ToString('N')).ToUpper()
    $now   = [DateTime]::UtcNow

    $ins = $conn.CreateCommand()
    $ins.CommandText = @"
INSERT INTO innovator.[VARIABLE]
    (id, config_id, [name], [value], is_current, is_released, [generation], major_rev,
     created_on, modified_on, created_by_id, modified_by_id,
     permission_id, locked_by_id)
VALUES
    (@id, @cfg, @n, @v, '1', '1', 1, 'A',
     @now, @now, '30B991F927274263BAEF6B0EE9C745EF', '30B991F927274263BAEF6B0EE9C745EF',
     'A3365E2BAE76402F9CC2D4F8AE63205F', NULL)
"@
    [void]$ins.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@id',  [System.Data.SqlDbType]::NVarChar, 32)))
    [void]$ins.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@cfg', [System.Data.SqlDbType]::NVarChar, 32)))
    [void]$ins.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@n',   [System.Data.SqlDbType]::NVarChar, 256)))
    [void]$ins.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@v',   [System.Data.SqlDbType]::NVarChar, -1)))
    [void]$ins.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@now', [System.Data.SqlDbType]::DateTime2)))
    $ins.Parameters['@id'].Value  = $newId
    $ins.Parameters['@cfg'].Value = $newId
    $ins.Parameters['@n'].Value   = $Name
    $ins.Parameters['@v'].Value   = $Value
    $ins.Parameters['@now'].Value = $now
    $rows = $ins.ExecuteNonQuery()
    Write-Host ("Inserted. Rows: " + $rows + ". id=" + $newId + " value='" + $Value + "'")
}
finally {
    $conn.Close()
    $conn.Dispose()
}
