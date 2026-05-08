# One-shot: strip v1 service-worker patch residue and bump filesRevision.
# Safe to run multiple times. Run as Administrator on the Aras VM.
#
# Background: the v2 SW patch declared `__rcOrigFetch` and `rcInjectNgrokHeader`
# but the older v1 patch's blocks were never removed, so the live SW had two
# `const __rcOrigFetch` declarations and crashed with:
#   "Identifier '__rcOrigFetch' has already been declared"
# Crashing SW means no fetches get the ngrok-skip header, so metadata
# requests get the ngrok HTML interstitial back; downstream JSON.parse
# and XPath errors followed.

param(
    [string]$InnovatorRoot = 'C:\Program Files (x86)\Aras\Innovator'
)

$ErrorActionPreference = 'Stop'

$swSrc = Join-Path $InnovatorRoot 'Innovator\Client\Modules\service-worker\index.ts'
if (-not (Test-Path $swSrc)) { throw "Not found: $swSrc" }

$content = Get-Content $swSrc -Raw
$origLen = $content.Length
$changed = $false

# v1 fetch monkey-patch (between the comment markers, inclusive of trailing newline)
$v1FetchPattern = '(?s)\t// === Robotics Centre: ngrok-skip-browser-warning header injector ===.*?\t// === /RC ===\r?\n'
if ([regex]::IsMatch($content, $v1FetchPattern)) {
    $content = [regex]::Replace($content, $v1FetchPattern, '')
    Write-Host 'stripped v1 fetch monkey-patch'
    $changed = $true
}

# v1 standalone rcInjectNgrokHeader helper (literal block match)
$v1HelperBlock = "`t// === Robotics Centre: always inject ngrok-skip-browser-warning ===`r`n`tconst rcInjectNgrokHeader = (req) => {`r`n`t`tconst h = new Headers(req.headers);`r`n`t`tif (!h.has('ngrok-skip-browser-warning')) h.set('ngrok-skip-browser-warning', 'true');`r`n`t`treturn new Request(req, { headers: h });`r`n`t};`r`n`r`n"
if ($content.Contains($v1HelperBlock)) {
    $content = $content.Replace($v1HelperBlock, '')
    Write-Host 'stripped v1 rcInjectNgrokHeader helper'
    $changed = $true
}

if (-not $changed) {
    Write-Host 'No v1 residue found. Nothing to do.'
    return
}

# Sanity: file should now contain exactly one __rcOrigFetch declaration and
# exactly one rcInjectNgrokHeader declaration.
$origFetchCount = ([regex]::Matches($content, 'const __rcOrigFetch')).Count
$helperCount    = ([regex]::Matches($content, 'const rcInjectNgrokHeader')).Count
Write-Host ("post-strip: __rcOrigFetch declarations=" + $origFetchCount + ", rcInjectNgrokHeader=" + $helperCount)
if ($origFetchCount -ne 1 -or $helperCount -ne 1) {
    throw "Unexpected declaration counts after strip; aborting without write."
}

# Backup once (skip if any pre-RC backup already exists)
$dir = Split-Path $swSrc -Parent
$base = Split-Path $swSrc -Leaf
$existingBackup = Get-ChildItem -Path $dir -Filter "$base.preRC-*.bak" -ErrorAction SilentlyContinue
if (-not $existingBackup) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $swSrc "$swSrc.preRC-$stamp.bak"
    Write-Host "  backup: $swSrc.preRC-$stamp.bak"
}

# Atomic-ish write
$tmp = "$swSrc.tmp"
Set-Content -Path $tmp -Value $content -NoNewline -Encoding UTF8
Move-Item -Path $tmp -Destination $swSrc -Force
Write-Host ("wrote " + $swSrc + "  (" + $origLen + " -> " + $content.Length + " bytes)")

# Bump filesRevision so the SPA fetches the new SW immediately
$clientCfg = Join-Path $InnovatorRoot 'Innovator\Client\InnovatorClient.config'
if (Test-Path $clientCfg) {
    [xml]$x = New-Object System.Xml.XmlDocument
    $x.PreserveWhitespace = $true
    $x.Load($clientCfg)
    $node = $x.SelectSingleNode('/configuration/cachingModule')
    if ($node) {
        $cur = $node.GetAttribute('filesRevision')
        $newRev = if ($cur -match '^\d+$') { ([int]$cur + 1).ToString() } else { 'rc-1' }
        $node.SetAttribute('filesRevision', $newRev)
        $x.Save($clientCfg)
        Write-Host ("filesRevision: " + $cur + " -> " + $newRev)
    }
}

Write-Host ''
Write-Host 'Done. Hard-refresh the SPA in the browser (Ctrl+Shift+R) and unregister'
Write-Host 'any stale service worker via DevTools > Application > Service workers > Unregister.'
