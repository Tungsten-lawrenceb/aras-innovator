# Grant Aras admin rights to one or more users by adding their alias Identity
# as a Member of "Innovator Admin" (DBA5D86402BF43D5976854B8B48FCDD1).
#
# Pattern: User -> alias Identity (via ALIAS table) -> Member relationship
# under the Innovator Admin Identity (via MEMBER table).
#
# Idempotent: skips users who are already members. Safe to re-run.

param(
    [Parameter(Mandatory=$true)][string]$Logins,   # single comma-separated string (survives PS array splatting over SSH)
    [string]$AdminIdentityId = 'DBA5D86402BF43D5976854B8B48FCDD1',  # Innovator Admin
    [string]$Server     = 'localhost\SQLEXPRESS',
    [string]$Database   = 'InnovatorSolutions',
    [string]$DbUser     = 'innovator',
    [string]$DbPassword = 'ArasDB-2025!'
)
$Logins = $Logins -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

$ErrorActionPreference = 'Stop'

$cs = "Server=$Server;Database=$Database;User ID=$DbUser;Password=$DbPassword;TrustServerCertificate=True"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()

try {
    # 1. Confirm the target admin Identity exists + get its name
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT name FROM innovator.[IDENTITY] WHERE id = @id AND is_current='1'"
    [void]$cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@id', [System.Data.SqlDbType]::Char, 32)))
    $cmd.Parameters['@id'].Value = $AdminIdentityId
    $adminName = [string]$cmd.ExecuteScalar()
    if (-not $adminName) { throw "Admin Identity $AdminIdentityId not found" }
    "Target admin Identity: $adminName  ($AdminIdentityId)"
    ""

    # 2. Find the permission_id used by existing Members of this Identity (so we
    #    don't have to invent one). Fall back to NULL if no other members.
    $cmd2 = $conn.CreateCommand()
    $cmd2.CommandText = "SELECT TOP 1 permission_id FROM innovator.[MEMBER] WHERE is_current='1' AND source_id = @sid AND permission_id IS NOT NULL"
    [void]$cmd2.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@sid', [System.Data.SqlDbType]::Char, 32)))
    $cmd2.Parameters['@sid'].Value = $AdminIdentityId
    $permissionId = [string]$cmd2.ExecuteScalar()
    "Permission_id template: $permissionId"
    ""

    # System "Innovator Admin" identity to attribute the modification to.
    # 30B991F927274263BAEF6B0EE9C745EF is the well-known Innovator-internal admin Identity id.
    $sysAdminId = '30B991F927274263BAEF6B0EE9C745EF'

    foreach ($login in $Logins) {
        Write-Host "==== $login ===="

        # Find user_id + alias identity
        $cmd3 = $conn.CreateCommand()
        $cmd3.CommandText = @"
SELECT u.id AS user_id,
       (SELECT TOP 1 a.related_id FROM innovator.[ALIAS] a WHERE a.source_id = u.id AND a.is_current='1') AS alias_id
FROM innovator.[USER] u
WHERE u.is_current='1' AND u.login_name = @ln
"@
        [void]$cmd3.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@ln', [System.Data.SqlDbType]::NVarChar, 256)))
        $cmd3.Parameters['@ln'].Value = $login
        $r = $cmd3.ExecuteReader()
        $userId = $null; $aliasId = $null
        if ($r.Read()) {
            $userId = [string]$r['user_id']
            $aliasId = if ($r['alias_id'] -is [DBNull]) { $null } else { [string]$r['alias_id'] }
        }
        $r.Close()

        if (-not $userId) { Write-Warning "  user not found"; continue }
        if (-not $aliasId) { Write-Warning "  user has no alias Identity (data inconsistency); skipping"; continue }
        Write-Host "  user_id  = $userId"
        Write-Host "  alias_id = $aliasId"

        # Already a member?
        $cmd4 = $conn.CreateCommand()
        $cmd4.CommandText = "SELECT COUNT(*) FROM innovator.[MEMBER] WHERE is_current='1' AND source_id = @sid AND related_id = @rid"
        [void]$cmd4.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@sid', [System.Data.SqlDbType]::Char, 32)))
        [void]$cmd4.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@rid', [System.Data.SqlDbType]::Char, 32)))
        $cmd4.Parameters['@sid'].Value = $AdminIdentityId
        $cmd4.Parameters['@rid'].Value = $aliasId
        if ([int]$cmd4.ExecuteScalar() -gt 0) {
            Write-Host "  already a member of $adminName. skipping."
            continue
        }

        # INSERT
        $newId = ([guid]::NewGuid().ToString('N')).ToUpper()
        $now = [DateTime]::UtcNow

        $ins = $conn.CreateCommand()
        $ins.CommandText = @"
INSERT INTO innovator.[MEMBER]
    (id, config_id, source_id, related_id, permission_id,
     is_current, is_released, generation, major_rev,
     created_on, modified_on, created_by_id, modified_by_id)
VALUES
    (@id, @id, @src, @rel, @perm,
     '1', '1', 1, 'A',
     @now, @now, @sys, @sys)
"@
        [void]$ins.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@id',   [System.Data.SqlDbType]::Char, 32)))
        [void]$ins.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@src',  [System.Data.SqlDbType]::Char, 32)))
        [void]$ins.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@rel',  [System.Data.SqlDbType]::Char, 32)))
        [void]$ins.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@perm', [System.Data.SqlDbType]::Char, 32)))
        [void]$ins.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@now',  [System.Data.SqlDbType]::DateTime2)))
        [void]$ins.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@sys',  [System.Data.SqlDbType]::Char, 32)))
        $ins.Parameters['@id'].Value = $newId
        $ins.Parameters['@src'].Value = $AdminIdentityId
        $ins.Parameters['@rel'].Value = $aliasId
        $ins.Parameters['@perm'].Value = if ($permissionId) { $permissionId } else { [DBNull]::Value }
        $ins.Parameters['@now'].Value = $now
        $ins.Parameters['@sys'].Value = $sysAdminId

        $rows = $ins.ExecuteNonQuery()
        Write-Host "  added as member of '$adminName' (Member.id = $newId, rows=$rows)"
    }

    ""
    Write-Host "Note: Aras caches Identity / Member relationships per session. Affected users"
    Write-Host "must sign out + sign back in for admin rights to take effect."
}
finally {
    $conn.Close()
    $conn.Dispose()
}
