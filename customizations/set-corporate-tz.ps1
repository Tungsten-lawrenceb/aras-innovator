# Set the Aras 'CorporateTimeZone' Variable to "Eastern Standard Time"
# (Windows TZ id - Microsoft uses the same name for both EST and EDT, the
# TZ engine handles DST automatically.)
#
# Pattern matches patch-cui-method.ps1: connect via System.Data.SqlClient,
# UPSERT the current generation row, idempotent.

param(
    [string]$Server     = 'localhost\SQLEXPRESS',
    [string]$Database   = 'InnovatorSolutions',
    [string]$DbUser     = 'innovator',
    [string]$DbPassword = 'ArasDB-2025!',
    [string]$VarName    = 'CorporateTimeZone',
    [string]$VarValue   = 'Eastern Standard Time'
)

$ErrorActionPreference = 'Stop'

$cs = "Server=$Server;Database=$Database;User ID=$DbUser;Password=$DbPassword;TrustServerCertificate=True"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()

try {
    # 1. Look up current generation
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT TOP 1 id, value FROM innovator.[VARIABLE] WHERE name = @n AND is_current = '1' ORDER BY generation DESC"
    [void]$cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@n', [System.Data.SqlDbType]::NVarChar, 256)))
    $cmd.Parameters['@n'].Value = $VarName
    $r = $cmd.ExecuteReader()
    $existing = if ($r.Read()) { @{ id = [string]$r['id']; value = [string]$r['value'] } } else { $null }
    $r.Close()

    if ($existing) {
        Write-Host ("Found existing Variable '" + $VarName + "' id=" + $existing.id + " value='" + $existing.value + "'")
        if ($existing.value -eq $VarValue) {
            Write-Host "Already set to '$VarValue'. Nothing to do."
            return
        }
        # Update
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
        $upd.Parameters['@v'].Value = $VarValue
        $upd.Parameters['@id'].Value = $existing.id
        $rows = $upd.ExecuteNonQuery()
        Write-Host ("Updated Variable. Rows affected: " + $rows + ". value: '" + $existing.value + "' -> '" + $VarValue + "'")
        return
    }

    # 2. Variable does not exist - INSERT a fresh current generation
    Write-Host ("Variable '" + $VarName + "' not found. Inserting.")
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
    $ins.Parameters['@n'].Value   = $VarName
    $ins.Parameters['@v'].Value   = $VarValue
    $ins.Parameters['@now'].Value = $now
    $rows = $ins.ExecuteNonQuery()
    Write-Host ("Inserted Variable. Rows affected: " + $rows + ". id=" + $newId + " value='" + $VarValue + "'")
}
finally {
    $conn.Close()
    $conn.Dispose()
}
