param(
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
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT TOP 1 id, method_code FROM innovator.[METHOD] WHERE name='UpdateTimeZoneInfo' AND is_current='1' ORDER BY generation DESC"
    $r = $cmd.ExecuteReader()
    if (-not $r.Read()) { throw "Method 'UpdateTimeZoneInfo' not found" }
    $id = [string]$r['id']
    $code = [string]$r['method_code']
    $r.Close()

    "  method id: $id"
    "  body length: $($code.Length) chars"

    if ($code -match 'https://www\.aras\.com/timezones/') {
        "  already https - nothing to patch"
        return
    }
    if ($code -notmatch 'http://www\.aras\.com/timezones/') {
        Write-Warning "  no http://www.aras.com/timezones URL found; method body shape changed?"
        return
    }

    $patched = $code -replace 'http://www\.aras\.com/timezones/', 'https://www.aras.com/timezones/'
    "  patching http://www.aras.com/timezones/ -> https://"

    $upd = $conn.CreateCommand()
    $upd.CommandText = "UPDATE innovator.[METHOD] SET method_code = @c, modified_on = SYSUTCDATETIME() WHERE id = @id"
    [void]$upd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@c',  [System.Data.SqlDbType]::NVarChar, -1)))
    [void]$upd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@id', [System.Data.SqlDbType]::NVarChar, 32)))
    $upd.Parameters['@c'].Value = $patched
    $upd.Parameters['@id'].Value = $id
    $rows = $upd.ExecuteNonQuery()
    "  UPDATE rows: $rows"
}
finally { $conn.Close(); $conn.Dispose() }

# Bump filesRevision so the SPA picks up the new method body via the SW metadata cache
$cfg = 'C:\Program Files (x86)\Aras\Innovator\Innovator\Client\InnovatorClient.config'
[xml]$x = New-Object System.Xml.XmlDocument
$x.PreserveWhitespace = $true
$x.Load($cfg)
$node = $x.SelectSingleNode('/configuration/cachingModule')
if ($node) {
    $cur = $node.GetAttribute('filesRevision')
    $newRev = if ($cur -match '^\d+$') { ([int]$cur + 1).ToString() } else { 'rc-1' }
    $node.SetAttribute('filesRevision', $newRev)
    $x.Save($cfg)
    "  filesRevision: $cur -> $newRev"
}
