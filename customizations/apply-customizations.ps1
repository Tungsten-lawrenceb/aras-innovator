<#
.SYNOPSIS
  Re-applies Robotics Centre customizations to an Aras Innovator install.

.DESCRIPTION
  Idempotent. Safe to run after Aras MSI installs, version upgrades, or
  Aras Update package installs that touch /Innovator/Client and /OAuthServer.

  Steps performed:
    1. Branding (logos + favicon)
    2. product_name -> "RC PLM" in InnovatorServerConfig.xml + OAuthServer.config
    3. OAuth.ClientServer.config PFX password fix (innovator -> empty)
    4. OAuthServer/OAuth.config InnovatorClient registry:
         - redirect_uri / post_logout_redirect / cors origins for $Hosts
         - profile scope
    5. InnovatorServerConfig.xml OAuthServerDiscovery URLs
    6. login.js patch (UTF-16LE pre-encode for password RSA)
    7. IIS_IUSRS modify ACL on Client/OAuthServer/Server folders
    8. iisreset

  Originals are backed up next to the file as <name>.preRC-<timestamp>.bak.

.PARAMETER InnovatorRoot
  Aras install root, e.g. "C:\Program Files (x86)\Aras\Innovator"

.PARAMETER AssetDir
  Folder containing custom logos + favicon. Defaults to .\images relative to this script.

.PARAMETER ProductName
  Tab/title text. Default "RC PLM".

.PARAMETER Hosts
  Hostnames the OAuth registry should accept (CORS, redirect_uri, etc.).
  Default: localhost, ARAS-WIN22K2, 192.168.1.104

.PARAMETER SkipIisReset
  Don't run iisreset at the end (useful when scripting batch operations).

.EXAMPLE
  PS> C:\Share\customizations\apply-customizations.ps1

.EXAMPLE
  PS> C:\Share\customizations\apply-customizations.ps1 -SkipIisReset
#>
[CmdletBinding()]
param(
    [string]$InnovatorRoot   = 'C:\Program Files (x86)\Aras\Innovator',
    [string]$AssetDir        = (Join-Path $PSScriptRoot 'images'),
    [string]$BinDir          = (Join-Path $PSScriptRoot 'bin'),
    [string]$ProductName     = 'RC PLM',
    [string[]]$Hosts         = @('localhost','ARAS-WIN22K2','192.168.1.104'),
    [string]$ExternalHttpsUrl = 'https://obliged-travesty-sacrament.ngrok-free.dev',
    [string]$AspNetCoreVersion = '8.0.0',

    # Entra ID OIDC (leave empty to skip Entra setup).
    # TenantId can be a tenant GUID (single-tenant), or 'common' / 'organizations'
    # (multi-tenant). Multi-tenant requires the email-domain allowlist below to be
    # set to a meaningful regex, otherwise any Entra principal in the world can
    # auto-create an Aras account.
    [string]$EntraTenantId                  = '',
    [string]$EntraClientId                  = '',
    [string]$EntraClientSecret              = '',
    [string]$EntraDisplayName               = 'Sign in with Microsoft',
    [string]$EntraAllowedEmailDomainsRegex  = '^(tungstencollaborative\.com|robotics-centre\.com)$',

    # SQL connection used to patch the af_ method (DB owner login from install)
    [string]$SqlServer       = 'localhost\SQLEXPRESS',
    [string]$SqlDatabase     = 'InnovatorSolutions',
    [string]$SqlUser         = 'sa',
    [string]$SqlPassword     = 'ArasDB-2025!',

    [switch]$SkipIisReset
)

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'

function Backup-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    # Avoid creating a fresh backup on every re-run if there's already at least one
    # *.preRC-*.bak alongside the file (which means we backed it up at some prior point).
    $existing = Get-ChildItem -Path (Split-Path $Path -Parent) -Filter ((Split-Path $Path -Leaf) + '.preRC-*.bak') -ErrorAction SilentlyContinue
    if ($existing -and $existing.Count -gt 0) { return }
    $bk = "$Path.preRC-$ts.bak"
    if (-not (Test-Path $bk)) {
        Copy-Item $Path $bk -Force
    }
}

function Replace-FileIfDifferent {
    param([string]$Source, [string]$Dest, [switch]$AllowCreate)
    if (-not (Test-Path $Source)) {
        Write-Warning "  Source missing: $Source"
        return $false
    }
    if (-not (Test-Path $Dest)) {
        if (-not $AllowCreate) {
            Write-Warning "  Dest missing (skipping): $Dest"
            return $false
        }
        $destDir = Split-Path $Dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item $Source $Dest -Force
        Write-Host "  + $Dest (created)"
        return $true
    }
    $srcHash = (Get-FileHash -Algorithm MD5 -Path $Source).Hash
    $dstHash = (Get-FileHash -Algorithm MD5 -Path $Dest).Hash
    if ($srcHash -eq $dstHash) {
        Write-Host "  - $Dest (already current)"
        return $false
    }
    Backup-File $Dest
    Copy-Item $Source $Dest -Force
    Write-Host "  + $Dest"
    return $true
}

function Replace-In-File {
    param([string]$Path, [string]$Old, [string]$New)
    if (-not (Test-Path $Path)) {
        Write-Warning "  Skipping (missing): $Path"
        return $false
    }
    $content = Get-Content $Path -Raw
    if (-not $content.Contains($Old)) {
        # Already done, or never had the source string
        return $false
    }
    Backup-File $Path
    $content = $content.Replace($Old, $New)
    Set-Content -Path $Path -Value $content -NoNewline -Encoding UTF8
    Write-Host "  patched $Path"
    return $true
}

Write-Host "============================================================"
Write-Host " Robotics Centre - Aras Innovator customization application"
Write-Host " Run at: $(Get-Date)"
Write-Host " Innovator root: $InnovatorRoot"
Write-Host " Asset dir:      $AssetDir"
Write-Host "============================================================"

if (-not (Test-Path $InnovatorRoot)) {
    throw "InnovatorRoot not found: $InnovatorRoot"
}
if (-not (Test-Path $AssetDir)) {
    throw "AssetDir not found: $AssetDir"
}

# ---------------------------------------------------------------- 1. Branding
Write-Host ""
Write-Host "== Branding =="
$ClientImages    = Join-Path $InnovatorRoot 'Innovator\Client\images'
$OAuthImages     = Join-Path $InnovatorRoot 'OAuthServer\wwwroot\images'

# In-app SPA logo (3 file aliases for different code paths)
foreach ($n in @('HeaderLogo.svg','HeaderLogoNash.svg','aras-innovator.svg')) {
    Replace-FileIfDifferent (Join-Path $AssetDir $n) (Join-Path $ClientImages $n) | Out-Null
}

# Login-page logo
Replace-FileIfDifferent (Join-Path $AssetDir 'arasInnovator.svg') (Join-Path $OAuthImages 'arasInnovator.svg') | Out-Null

# All favicon.ico locations across the install
$srcFav = Join-Path $AssetDir 'favicon.ico'
if (Test-Path $srcFav) {
    Get-ChildItem $InnovatorRoot -Recurse -Filter 'favicon.ico' -ErrorAction SilentlyContinue |
        ForEach-Object {
            Replace-FileIfDifferent $srcFav $_.FullName | Out-Null
        }
}

# ---------------------------------------------------------------- 2. product_name
Write-Host ""
Write-Host "== product_name -> $ProductName =="
foreach ($cfg in @(
    "$InnovatorRoot\InnovatorServerConfig.xml",
    "$InnovatorRoot\Innovator\Server\InnovatorServerConfig.xml"
)) {
    if (Test-Path $cfg) {
        Backup-File $cfg
        $c = Get-Content $cfg -Raw
        # Replace any product_name="..." with our value (handles arbitrary current value)
        $new = [regex]::Replace($c, 'product_name="[^"]*"', "product_name=`"$ProductName`"")
        if ($new -ne $c) {
            Set-Content -Path $cfg -Value $new -NoNewline -Encoding UTF8
            Write-Host "  patched $cfg"
        }
    }
}
$oauthCfg = "$InnovatorRoot\OAuthServer\OAuthServer.config"
if (Test-Path $oauthCfg) {
    $c = Get-Content $oauthCfg -Raw
    $new = $c
    foreach ($k in @('ProductName','LocalAuthenticationDisplayName')) {
        $new = [regex]::Replace($new, "(<add key=`"$k`" value=)`"[^`"]*`"", "`$1`"$ProductName`"")
    }
    if ($new -ne $c) {
        Backup-File $oauthCfg
        Set-Content -Path $oauthCfg -Value $new -NoNewline -Encoding UTF8
        Write-Host "  patched $oauthCfg"
    }
}

# ---------------------------------------------------------------- 3. PFX password fix
Write-Host ""
Write-Host "== InnovatorClientServer.pfx password (innovator -> empty) =="
$cscfg = "$InnovatorRoot\Innovator\Client\OAuth.ClientServer.config"
Replace-In-File $cscfg 'password="innovator"' 'password=""' | Out-Null

# ---------------------------------------------------------------- 4. OAuth registry
Write-Host ""
Write-Host "== OAuthServer registry (redirect URIs / CORS / profile scope) =="
$srvOauth = "$InnovatorRoot\OAuthServer\OAuth.config"
if (Test-Path $srvOauth) {
    [xml]$xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($srvOauth)

    $ic = $xml.SelectSingleNode("//clientRegistry[@id='InnovatorClient']")
    if ($ic) {
        $changed = $false

        $allowedScopes = $ic.SelectSingleNode('allowedScopes')
        if ($allowedScopes -and -not $allowedScopes.SelectSingleNode("scope[@name='profile']")) {
            $e = $xml.CreateElement('scope'); $e.SetAttribute('name','profile')
            $allowedScopes.AppendChild($e) | Out-Null
            Write-Host "  + scope 'profile'"
            $changed = $true
        }

        $redirectsNode = $ic.SelectSingleNode('redirectUris')
        $logoutNode    = $ic.SelectSingleNode('postLogoutRedirectUris')
        $corsNode      = $ic.SelectSingleNode('allowedCorsOrigins')

        $base = '/InnovatorServer'
        foreach ($h in $Hosts) {
            foreach ($p in @('/Client/OAuth/RedirectCallback','/Client/OAuth/SilentCallback','/Client/OAuth/PopupCallback')) {
                $u = "http://$h$base$p"
                if ($redirectsNode -and -not $redirectsNode.SelectSingleNode("redirectUri[@value='$u']")) {
                    $e = $xml.CreateElement('redirectUri'); $e.SetAttribute('value',$u)
                    $redirectsNode.AppendChild($e) | Out-Null
                    Write-Host "  + redirect_uri $u"
                    $changed = $true
                }
            }
            $lu = "http://$h$base/Client/OAuth/PostLogoutCallback"
            if ($logoutNode -and -not $logoutNode.SelectSingleNode("redirectUri[@value='$lu']")) {
                $e = $xml.CreateElement('redirectUri'); $e.SetAttribute('value',$lu)
                $logoutNode.AppendChild($e) | Out-Null
                Write-Host "  + post_logout $lu"
                $changed = $true
            }
            $co = "http://$h"
            if ($corsNode -and -not $corsNode.SelectSingleNode("origin[@value='$co']")) {
                $e = $xml.CreateElement('origin'); $e.SetAttribute('value',$co)
                $corsNode.AppendChild($e) | Out-Null
                Write-Host "  + cors $co"
                $changed = $true
            }
        }

        if ($changed) {
            Backup-File $srvOauth
            $xml.Save($srvOauth)
            Write-Host "  saved $srvOauth"
        }
    } else {
        Write-Warning "  InnovatorClient registry not found in $srvOauth"
    }
} else {
    Write-Warning "  Missing $srvOauth"
}

# ---------------------------------------------------------------- 5. Discovery URLs
Write-Host ""
Write-Host "== InnovatorServerConfig OAuthServerDiscovery URLs =="
foreach ($cfg in @(
    "$InnovatorRoot\InnovatorServerConfig.xml",
    "$InnovatorRoot\Innovator\Server\InnovatorServerConfig.xml"
)) {
    if (Test-Path $cfg) {
        [xml]$x = New-Object System.Xml.XmlDocument
        $x.PreserveWhitespace = $true
        $x.Load($cfg)
        $urls = $x.SelectSingleNode('//OAuthServerDiscovery/Urls')
        if ($urls) {
            # rebuild URL list deterministically
            $existing = @($urls.SelectNodes('Url') | ForEach-Object { $_.GetAttribute('value') })
            $desired = $Hosts | ForEach-Object { "http://$_/InnovatorServer/OAuthServer/" }
            $needed = $desired | Where-Object { $_ -notin $existing }
            if ($needed) {
                Backup-File $cfg
                # Clear and re-add in priority order
                $urls.RemoveAll() | Out-Null
                foreach ($u in $desired) {
                    $e = $x.CreateElement('Url'); $e.SetAttribute('value',$u)
                    $urls.AppendChild($e) | Out-Null
                }
                $x.Save($cfg)
                Write-Host "  patched $cfg (set $($desired.Count) URLs)"
            }
        }
    }
}

# ---------------------------------------------------------------- 6. login.js UTF-16LE patch
Write-Host ""
Write-Host "== login.js UTF-16LE password patch =="
$loginJs = "$InnovatorRoot\OAuthServer\wwwroot\js\login.js"
if (Test-Path $loginJs) {
    $content = Get-Content $loginJs -Raw
    $needle  = 'crypt.encrypt(passwordElement.value)'
    $patched = 'crypt.encrypt(loginPage._toUtf16LeBytesString(passwordElement.value))'
    if ($content.Contains($patched)) {
        Write-Host "  - login.js (already patched)"
    } elseif ($content.Contains($needle)) {
        Backup-File $loginJs
        $content = $content.Replace($needle, $patched)
        # Insert helper function just before _setEncryptedPassword
        $marker = '_setEncryptedPassword: function() {'
        $idx = $content.IndexOf($marker)
        if ($idx -ge 0) {
            $helper = @"
_toUtf16LeBytesString: function(str) {
		// Encode each UTF-16 code unit as two single-byte chars (low byte, high byte)
		// so JSEncrypt's charCodeAt-based encoder produces raw UTF-16LE bytes that
		// Aras's Authenticate.aspx expects.
		var result = '';
		for (var i = 0; i < str.length; i++) {
			var code = str.charCodeAt(i);
			result += String.fromCharCode(code & 0xff);
			result += String.fromCharCode((code >> 8) & 0xff);
		}
		return result;
	},

	$marker
"@
            $content = $content.Substring(0,$idx) + $helper + $content.Substring($idx + $marker.Length)
        }
        Set-Content -Path $loginJs -Value $content -NoNewline -Encoding UTF8
        Write-Host "  patched login.js"
    } else {
        Write-Warning "  login.js layout unrecognized; manual patch needed"
    }
}

# ---------------------------------------------------------------- 6b. PhoneHomeCall silence
Write-Host ""
Write-Host "== Silence phone-home unhandled rejection =="
$setupTs = "$InnovatorRoot\Innovator\Client\Modules\aras.innovator.core.MainWindow\setup.ts"
if (Test-Path $setupTs) {
    $content = Get-Content $setupTs -Raw
    if ($content.Contains('phoneHomeCall.tryGetUpdateInfo().catch')) {
        Write-Host "  - setup.ts (already patched)"
    } elseif ($content.Contains('phoneHomeCall.tryGetUpdateInfo();')) {
        Backup-File $setupTs
        $content = $content.Replace(
            'phoneHomeCall.tryGetUpdateInfo();',
            'phoneHomeCall.tryGetUpdateInfo().catch(function(){});')
        $content = $content.Replace(
            'phoneHomeCall.tryStoreStatistics();',
            'phoneHomeCall.tryStoreStatistics().catch(function(){});')
        Set-Content -Path $setupTs -Value $content -NoNewline -Encoding UTF8
        Write-Host "  patched setup.ts"

        # Bump filesRevision in InnovatorClient.config to bust the SPA's salted cache
        $clientCfg = "$InnovatorRoot\Innovator\Client\InnovatorClient.config"
        if (Test-Path $clientCfg) {
            [xml]$x = New-Object System.Xml.XmlDocument
            $x.PreserveWhitespace = $true
            $x.Load($clientCfg)
            $node = $x.SelectSingleNode('/configuration/cachingModule')
            if ($node) {
                $cur = $node.GetAttribute('filesRevision')
                $new = if ($cur -match '^\d+$') { ([int]$cur + 1).ToString() } else { 'rc-1' }
                $node.SetAttribute('filesRevision', $new)
                $x.Save($clientCfg)
                Write-Host "  filesRevision: $cur -> $new (cache busted)"
            }
        }
    }
}

# ---------------------------------------------------------------- 6b2. Login page "Sign in with Microsoft" button
# Hides the "Login with" dropdown and surfaces a dedicated SSO button below the
# standard Login button. Pure JS injection — works against the shipped Razor view.
$loginJs = "$InnovatorRoot\OAuthServer\wwwroot\js\login.js"
if (Test-Path $loginJs) {
    $content = Get-Content $loginJs -Raw
    if (-not $content.Contains('rc-sso-microsoft')) {
        Write-Host ""
        Write-Host "== login.js: SSO button injector =="
        $append = @'

// === Robotics Centre SSO button injector ===
// Hides the "Login with" dropdown and renders a single "Sign in with Microsoft"
// button below the standard local Login button. CSP-safe (no inline styles —
// supplemental rules live in /css/rc-sso.css which is injected as a <link>).
(function () {
	function inject() {
		if (!document.getElementById('rc-sso-css')) {
			var l = document.createElement('link');
			l.id = 'rc-sso-css';
			l.rel = 'stylesheet';
			l.href = '/InnovatorServer/OAuthServer/css/rc-sso.css';
			document.head.appendChild(l);
		}
		var typeSelect = document.getElementById('AuthenticationType');
		if (!typeSelect) return;
		var hasMicrosoft = false;
		for (var i = 0; i < typeSelect.options.length; i++) {
			if (typeSelect.options[i].value === 'Microsoft') { hasMicrosoft = true; break; }
		}
		if (!hasMicrosoft) return;
		var typeRow = document.getElementsByClassName('login-area__auth-type')[0];
		if (typeRow) { typeRow.hidden = true; }
		var loginBtn = document.getElementById('Login');
		if (!loginBtn) return;
		if (document.getElementById('rc-sso-microsoft')) return;
		var btn = document.createElement('button');
		btn.id = 'rc-sso-microsoft';
		btn.type = 'button';
		btn.className = 'aras-button aras-button_primary login-area__continue-btn rc-sso-button';
		btn.innerHTML = '<span class="aras-button__text">Sign in with Microsoft</span>';
		btn.addEventListener('click', function () {
			var form = document.getElementById('LoginForm');
			if (!form) return;
			// Strip the existing AuthenticationType select from form submission so it cannot
			// fight our explicit value, then add a hidden input we control.
			typeSelect.removeAttribute('name');
			var prior = form.querySelector('input[type=hidden][name="AuthenticationType"]');
			if (prior) prior.parentNode.removeChild(prior);
			var h = document.createElement('input');
			h.type = 'hidden';
			h.name = 'AuthenticationType';
			h.value = 'Microsoft';
			form.appendChild(h);
			form.action = '/InnovatorServer/OAuthServer/External/Challenge';
			form.submit();
		});
		loginBtn.parentNode.insertBefore(btn, loginBtn.nextSibling);
	}
	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', inject);
	} else {
		inject();
	}
})();
'@
        Backup-File $loginJs
        Set-Content -Path $loginJs -Value ($content + $append) -NoNewline -Encoding UTF8
        Write-Host "  patched login.js"
    }
}

# ---------------------------------------------------------------- 6b3. loadTypeScriptMethods null-guard
# Aras's shipped code does `bundle.invalidMethods?.length` but `bundle` itself can be null
# when there are no TypeScript methods in the database. Patch to add `?.` on bundle too.
$ishFile = "$InnovatorRoot\Innovator\Client\scripts\include\InitialSetupHeader.cshtml"
if (Test-Path $ishFile) {
    $ishContent = Get-Content $ishFile -Raw
    $ishOld = 'if (bundle.invalidMethods?.length) {'
    $ishNew = 'if (bundle?.invalidMethods?.length) {'
    if ($ishContent.Contains($ishOld)) {
        Write-Host ""
        Write-Host "== InitialSetupHeader.cshtml: loadTypeScriptMethods null-guard =="
        Backup-File $ishFile
        Set-Content -Path $ishFile -Value $ishContent.Replace($ishOld, $ishNew) -NoNewline -Encoding UTF8
        Write-Host "  patched"
        # filesRevision bump is already handled by the phone-home patch step above; if
        # neither the phone-home nor this file ever changed, nothing else bumps it.
        # Belt-and-suspenders: bump now if not already done in this run.
        $clientCfg = "$InnovatorRoot\Innovator\Client\InnovatorClient.config"
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
                Write-Host "  filesRevision: $cur -> $newRev (cache busted)"
            }
        }
    }
}

# ---------------------------------------------------------------- 6b35. OAuthServerDiscovery: drop mixed-content URLs
# When the SPA is served over HTTPS via ngrok but the OAuthServerDiscovery
# list still includes the LAN HTTP URLs (192.168.x / hostname / localhost),
# the browser blocks them as mixed content. The SPA's `lastAccessibleUrl`
# in localStorage can pin one of those HTTP URLs as the priority candidate,
# at which point the discovery fetch never resolves to the working HTTPS
# entry. Filter the list at runtime so HTTPS pages only ever try HTTPS URLs.
# Idempotency keys on the marker `RC: drop URLs that would trigger`.
$oauthDiscoveryTs = "$InnovatorRoot\Innovator\Client\Modules\aras.innovator.AuthenticationFramework\Scripts\OAuthServerDiscovery.ts"
if ((Test-Path $oauthDiscoveryTs) -and (-not (Get-Content $oauthDiscoveryTs -Raw).Contains('RC: drop URLs that would trigger'))) {
    Write-Host ""
    Write-Host "== OAuthServerDiscovery: filter mixed-content URLs =="
    $tsContent = Get-Content $oauthDiscoveryTs -Raw
    $tsOld = @'
				const oauthServerUrls = discoveryJson.locations.map(
					function (location) {
						return location.uri;
					}
				);
				return oauthServerUrls;
'@
    $tsNew = @'
				let oauthServerUrls = discoveryJson.locations.map(
					function (location) {
						return location.uri;
					}
				);

				// RC: drop URLs that would trigger mixed-content blocking.
				// When the SPA is loaded over HTTPS, only HTTPS discovery URLs
				// can be fetched by the browser; HTTP candidates are blocked
				// before the request leaves the page, so trying them produces
				// noisy console warnings and a stale `lastAccessibleUrl` in
				// localStorage can pin the SPA to one that will never work.
				if (window.location.protocol === 'https:') {
					oauthServerUrls = oauthServerUrls.filter(function (u) {
						return typeof u === 'string' && u.toLowerCase().indexOf('https:') === 0;
					});
				}
				return oauthServerUrls;
'@
    if ($tsContent.Contains($tsOld)) {
        Backup-File $oauthDiscoveryTs
        Set-Content -Path $oauthDiscoveryTs -Value $tsContent.Replace($tsOld, $tsNew) -NoNewline -Encoding UTF8
        Write-Host "  patched OAuthServerDiscovery.ts"

        # Bump filesRevision so the SPA pulls the new discovery script
        $clientCfg = "$InnovatorRoot\Innovator\Client\InnovatorClient.config"
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
                Write-Host "  filesRevision: $cur -> $newRev"
            }
        }
    } else {
        Write-Warning "  OAuthServerDiscovery.ts source pattern not found; skipping"
    }
}

# ---------------------------------------------------------------- 6b4. Service worker: ngrok-skip-browser-warning injector
# Single atomic patch (v2): inserts a self.fetch monkey-patch right after the
# runServiceWorker entry, AND replaces the existing fetch event listener with a
# combined version that defines `rcInjectNgrokHeader`, short-circuits cross-
# origin requests, and injects the bypass header for non-validateRequest paths.
#
# Cleanup: this step also strips any v1 residue (`Robotics Centre:` blocks
# from the previous patch generation) before the idempotency check, so that
# v2-on-top-of-v1 deployments don't end up with duplicate `__rcOrigFetch`
# / `rcInjectNgrokHeader` const declarations (which would crash the SW with
# `Identifier '...' has already been declared` on importScripts).
$swSrc = "$InnovatorRoot\Innovator\Client\Modules\service-worker\index.ts"
if (Test-Path $swSrc) {
    $swContent = Get-Content $swSrc -Raw
    $swChanged = $false

    # ---- Strip v1 fetch monkey-patch residue ---------------------------------
    # Block runs from `// === Robotics Centre: ngrok-skip-browser-warning header
    # injector ===` through `// === /RC ===` and ALL lines between.
    $v1FetchPattern = '(?s)\t// === Robotics Centre: ngrok-skip-browser-warning header injector ===.*?\t// === /RC ===\r?\n'
    if ([regex]::IsMatch($swContent, $v1FetchPattern)) {
        $swContent = [regex]::Replace($swContent, $v1FetchPattern, '')
        $swChanged = $true
        Write-Host "  stripped v1 fetch monkey-patch residue"
    }

    # ---- Strip v1 standalone rcInjectNgrokHeader helper ----------------------
    # Sits before the v2 listener replacement; declares the same const that
    # v2 then re-declares, hence the duplicate-identifier crash.
    $v1HelperBlock = "`t// === Robotics Centre: always inject ngrok-skip-browser-warning ===`r`n`tconst rcInjectNgrokHeader = (req) => {`r`n`t`tconst h = new Headers(req.headers);`r`n`t`tif (!h.has('ngrok-skip-browser-warning')) h.set('ngrok-skip-browser-warning', 'true');`r`n`t`treturn new Request(req, { headers: h });`r`n`t};`r`n`r`n"
    if ($swContent.Contains($v1HelperBlock)) {
        $swContent = $swContent.Replace($v1HelperBlock, '')
        $swChanged = $true
        Write-Host "  stripped v1 rcInjectNgrokHeader helper residue"
    }

    # Save the cleaned content back if we stripped anything but v2 already done
    $hasV2 = $swContent.Contains('RC_SW_v2')

    if ($swChanged -and $hasV2) {
        # v1 residue removed and v2 already applied — write cleaned file
        Backup-File $swSrc
        Set-Content -Path $swSrc -Value $swContent -NoNewline -Encoding UTF8
        Write-Host "== service-worker: cleaned v1 residue (v2 already in place) =="

        # Bump filesRevision so SPA pulls the cleaned SW
        $clientCfg = "$InnovatorRoot\Innovator\Client\InnovatorClient.config"
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
                Write-Host "  filesRevision: $cur -> $newRev"
            }
        }
    }
}

if ((Test-Path $swSrc) -and (-not (Get-Content $swSrc -Raw).Contains('RC_SW_v2'))) {
    Write-Host ""
    Write-Host "== service-worker: ngrok bypass + cross-origin skip (v2) =="
    $swContent = Get-Content $swSrc -Raw

    $entryMarker = 'const runServiceWorker = (self) => {'
    $listenerPattern = "(?s)self\.addEventListener\('fetch',\s*\(event\)\s*=>\s*\{.*?event\.respondWith\(responsePromise\);\s*\}\);"

    if (-not $swContent.Contains($entryMarker)) {
        Write-Warning "  service-worker entry marker not found; skipping"
    } elseif ($swContent -notmatch $listenerPattern) {
        Write-Warning "  service-worker fetch-listener pattern not found; skipping"
    } else {
        $entryInject = @'
const runServiceWorker = (self) => {
	// === RC_SW_v2: ngrok bypass + cross-origin guard ===
	// (a) Monkey-patch self.fetch so every fetch this SW makes carries the bypass header.
	const __rcOrigFetch = self.fetch.bind(self);
	self.fetch = function (input, init) {
		try {
			if (input instanceof Request) {
				const h = new Headers(input.headers);
				if (!h.has('ngrok-skip-browser-warning')) h.set('ngrok-skip-browser-warning', 'true');
				input = new Request(input, { headers: h });
			} else {
				init = init || {};
				init.headers = new Headers(init.headers || {});
				if (!init.headers.has('ngrok-skip-browser-warning')) init.headers.set('ngrok-skip-browser-warning', 'true');
			}
		} catch (e) { /* fall through */ }
		return __rcOrigFetch(input, init);
	};
'@
        $nl = "`r`n"
        $listenerRepl = @"
// === RC_SW_v2: ngrok bypass + cross-origin guard ===$nl	const rcInjectNgrokHeader = (req) => {$nl		const h = new Headers(req.headers);$nl		if (!h.has('ngrok-skip-browser-warning')) h.set('ngrok-skip-browser-warning', 'true');$nl		return new Request(req, { headers: h });$nl	};$nl$nl	self.addEventListener('fetch', (event) => {$nl		const { request } = event;$nl$nl		// Cross-origin: never proxy. Aras's getResponse() chokes; bypass-header force-CORSes opaque fonts.$nl		try {$nl			const reqUrl = new URL(request.url);$nl			if (reqUrl.origin !== self.location.origin) { return; }$nl		} catch (e) { /* fall through */ }$nl$nl		const validRequest = validateRequest(request);$nl		if (!validRequest) {$nl			try {$nl				const url = new URL(request.url);$nl				if (/(?:\.ngrok-free\.(?:dev|app)|\.ngrok\.app|\.ngrok\.io)`$/i.test(url.hostname)) {$nl					event.respondWith(fetch(rcInjectNgrokHeader(request)));$nl				}$nl			} catch (e) { /* fall through */ }$nl			return;$nl		}$nl$nl		const responsePromise = getResponse(request);$nl		event.respondWith(responsePromise);$nl	});
"@
        Backup-File $swSrc
        $swContent = $swContent.Replace($entryMarker, $entryInject)
        $swContent = [regex]::Replace($swContent, $listenerPattern, $listenerRepl)
        Set-Content -Path $swSrc -Value $swContent -NoNewline -Encoding UTF8
        Write-Host "  patched runServiceWorker entry + fetch listener"

        # Bump filesRevision so the SPA pulls the new SW immediately
        $clientCfg = "$InnovatorRoot\Innovator\Client\InnovatorClient.config"
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
                Write-Host "  filesRevision: $cur -> $newRev"
            }
        }
    }
}

# ---------------------------------------------------------------- 6b5. OAuth login page CSS (rc-sso.css)
# Loaded by the SSO button injector. Provides:
#  - .rc-sso-button: spacing under the local Login button
#  - .login-area__logo / __logo-image / __version-info: extra "quiet"
#    whitespace around the custom branded login logo.
$rcCss = "$InnovatorRoot\OAuthServer\wwwroot\css\rc-sso.css"
$rcCssBody = @"
.rc-sso-button {
	margin-top: 12px;
}

/* RC: extra whitespace around the login-page logo */
.login-area__logo {
	padding: 28px 24px 16px;
}
.login-area__logo-image {
	max-width: 70%;
	height: auto;
	margin: 0 auto 12px;
	display: block;
}
.login-area__version-info {
	margin-top: 8px;
	text-align: center;
}
"@
if (-not (Test-Path $rcCss) -or ((Get-Content $rcCss -Raw) -ne $rcCssBody)) {
    Write-Host ""
    Write-Host "== rc-sso.css =="
    Set-Content -Path $rcCss -Value $rcCssBody -NoNewline -Encoding UTF8
    Write-Host "  wrote $rcCss ($(($rcCssBody | Measure-Object -Character).Characters) chars)"
}

# ---------------------------------------------------------------- 6c. External HTTPS host (ngrok / reverse proxy)
if ($ExternalHttpsUrl) {
    Write-Host ""
    Write-Host "== External HTTPS host: $ExternalHttpsUrl =="

    # 6c.1 Add external host to OAuthServerDiscovery URLs (first = highest priority)
    foreach ($cfg in @(
        "$InnovatorRoot\InnovatorServerConfig.xml",
        "$InnovatorRoot\Innovator\Server\InnovatorServerConfig.xml"
    )) {
        if (-not (Test-Path $cfg)) { continue }
        [xml]$x = New-Object System.Xml.XmlDocument
        $x.PreserveWhitespace = $true
        $x.Load($cfg)
        $urls = $x.SelectSingleNode('//OAuthServerDiscovery/Urls')
        if (-not $urls) { continue }
        $extUrl = "$ExternalHttpsUrl/InnovatorServer/OAuthServer/"
        if (-not $urls.SelectSingleNode("Url[@value='$extUrl']")) {
            Backup-File $cfg
            # prepend
            $e = $x.CreateElement('Url'); $e.SetAttribute('value', $extUrl)
            $urls.PrependChild($e) | Out-Null
            $x.Save($cfg)
            Write-Host "  + $cfg discovery URL"
        }
    }

    # 6c.2 OAuth registry: redirect/post-logout/CORS for external host
    $srvOauth = "$InnovatorRoot\OAuthServer\OAuth.config"
    if (Test-Path $srvOauth) {
        [xml]$xml = New-Object System.Xml.XmlDocument
        $xml.PreserveWhitespace = $true
        $xml.Load($srvOauth)
        $ic = $xml.SelectSingleNode("//clientRegistry[@id='InnovatorClient']")
        if ($ic) {
            $changed = $false
            $r = $ic.SelectSingleNode('redirectUris')
            $l = $ic.SelectSingleNode('postLogoutRedirectUris')
            $c = $ic.SelectSingleNode('allowedCorsOrigins')
            foreach ($p in @('/Client/OAuth/RedirectCallback','/Client/OAuth/SilentCallback','/Client/OAuth/PopupCallback')) {
                $u = "$ExternalHttpsUrl/InnovatorServer$p"
                if (-not $r.SelectSingleNode("redirectUri[@value='$u']")) {
                    $e = $xml.CreateElement('redirectUri'); $e.SetAttribute('value', $u); $r.AppendChild($e) | Out-Null
                    Write-Host "  + redirect_uri $u"; $changed = $true
                }
            }
            $lu = "$ExternalHttpsUrl/InnovatorServer/Client/OAuth/PostLogoutCallback"
            if (-not $l.SelectSingleNode("redirectUri[@value='$lu']")) {
                $e = $xml.CreateElement('redirectUri'); $e.SetAttribute('value', $lu); $l.AppendChild($e) | Out-Null
                Write-Host "  + post_logout $lu"; $changed = $true
            }
            if (-not $c.SelectSingleNode("origin[@value='$ExternalHttpsUrl']")) {
                $e = $xml.CreateElement('origin'); $e.SetAttribute('value', $ExternalHttpsUrl); $c.AppendChild($e) | Out-Null
                Write-Host "  + cors $ExternalHttpsUrl"; $changed = $true
            }
            if ($changed) { Backup-File $srvOauth; $xml.Save($srvOauth); Write-Host "  saved $srvOauth" }
        }
    }

    # 6c.3 IIS URL Rewrite: set HTTPS=on when X-Forwarded-Proto=https
    # Required so AspNetCoreModule promotes the request scheme to https in ServerVariables.
    $siteWeb = "C:\inetpub\wwwroot\web.config"
    $rewriteXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="ngrok-fwdproto-to-https" stopProcessing="false">
          <match url=".*" />
          <conditions>
            <add input="{HTTP_X_FORWARDED_PROTO}" pattern="https" />
          </conditions>
          <serverVariables>
            <set name="HTTPS" value="on" />
          </serverVariables>
          <action type="None" />
        </rule>
      </rules>
    </rewrite>
  </system.webServer>
</configuration>
'@
    if (-not (Test-Path $siteWeb) -or (Get-Content $siteWeb -Raw) -notmatch 'ngrok-fwdproto-to-https') {
        if (Test-Path $siteWeb) { Backup-File $siteWeb }
        Set-Content $siteWeb $rewriteXml -Encoding UTF8 -NoNewline
        Write-Host "  + URL Rewrite rule at $siteWeb"
    }

    # 6c.4 Allow HTTPS server variable to be modified
    & "$env:windir\System32\inetsrv\appcmd.exe" set config -section:system.webServer/rewrite/allowedServerVariables /+"[name='HTTPS']" /commit:apphost 2>&1 | Out-Null

    # 6c.5 Deploy ForwardedHeaders plugin
    $fhDll  = Join-Path $BinDir 'Aras.Plugins.ForwardedHeaders.dll'
    $fhDeps = Join-Path $BinDir 'Aras.Plugins.ForwardedHeaders.deps.json'
    if ((Test-Path $fhDll) -and (Test-Path $fhDeps)) {
        foreach ($app in @(
            "$InnovatorRoot\OAuthServer",
            "$InnovatorRoot\Innovator\Client",
            "$InnovatorRoot\Innovator\Server"
        )) {
            if (-not (Test-Path $app)) { continue }
            $bin = if (Test-Path "$app\Bin") { "$app\Bin" } else { "$app\bin" }
            Replace-FileIfDifferent $fhDll  (Join-Path $bin 'Aras.Plugins.ForwardedHeaders.dll') | Out-Null
            $depsDir = "$app\Plugins\additionalDeps\shared\Microsoft.AspNetCore.App\$AspNetCoreVersion"
            New-Item -ItemType Directory -Path $depsDir -Force | Out-Null
            Replace-FileIfDifferent $fhDeps (Join-Path $depsDir 'Aras.Plugins.ForwardedHeaders.deps.json') | Out-Null
            $storeDir = "$app\Plugins\store\x64\net8.0\aras.plugins.forwardedheaders\1.0.0\lib\net8.0"
            New-Item -ItemType Directory -Path $storeDir -Force | Out-Null
            Replace-FileIfDifferent $fhDll (Join-Path $storeDir 'Aras.Plugins.ForwardedHeaders.dll') | Out-Null
        }

        # 6c.6 Enable in each Plugins.json (idempotent JSON-with-comments append)
        foreach ($pj in @(
            @{ Path = "$InnovatorRoot\OAuthServer\OAuthServer.Plugins.json";      Key = 'OAuthServer.Plugins' },
            @{ Path = "$InnovatorRoot\Innovator\Client\InnovatorClient.Plugins.json"; Key = 'InnovatorClient.Plugins' },
            @{ Path = "$InnovatorRoot\Innovator\Server\InnovatorServer.Plugins.json"; Key = 'InnovatorServer.Plugins' }
        )) {
            $f = $pj.Path
            if (-not (Test-Path $f)) { continue }
            $raw = Get-Content $f -Raw
            if ($raw -match '"Aras\.Plugins\.ForwardedHeaders"') { continue }
            # Strip // comments and trailing commas, then parse
            $stripped = ($raw -split "`n" | ForEach-Object { $_ -replace '//.*$','' }) -join "`n"
            $stripped = $stripped -replace ',(\s*[\}\]])', '$1'
            $obj = $null
            try { $obj = $stripped | ConvertFrom-Json } catch { Write-Warning "  Could not parse $f - skipping JSON edit"; continue }
            $newPlugin = [PSCustomObject]@{ Name = 'Aras.Plugins.ForwardedHeaders'; Enabled = $true }
            $arr = @($obj.($pj.Key)) + $newPlugin
            $obj.($pj.Key) = $arr
            Backup-File $f
            $obj | ConvertTo-Json -Depth 10 | Set-Content $f -Encoding UTF8
            Write-Host "  + ForwardedHeaders enabled in $f"
        }
    }
}

# ---------------------------------------------------------------- 6d. Microsoft Entra OIDC plugin (optional)
if ($EntraTenantId -and $EntraClientId) {
    Write-Host ""
    Write-Host "== Microsoft Entra OIDC plugin =="

    # 6d.1 Deploy the MicrosoftEntra plugin DLL (OAuthServer only — that's where login flows live)
    $entraDll  = Join-Path $BinDir 'Aras.OAuth.Server.Plugins.MicrosoftEntra.dll'
    $entraDeps = Join-Path $BinDir 'Aras.OAuth.Server.Plugins.MicrosoftEntra.deps.json'
    if ((Test-Path $entraDll) -and (Test-Path $entraDeps)) {
        $oauth = "$InnovatorRoot\OAuthServer"
        Replace-FileIfDifferent $entraDll  "$oauth\Bin\Aras.OAuth.Server.Plugins.MicrosoftEntra.dll" -AllowCreate | Out-Null
        $depsDir = "$oauth\Plugins\additionalDeps\shared\Microsoft.AspNetCore.App\$AspNetCoreVersion"
        New-Item -ItemType Directory -Path $depsDir -Force | Out-Null
        Replace-FileIfDifferent $entraDeps (Join-Path $depsDir 'Aras.OAuth.Server.Plugins.MicrosoftEntra.deps.json') -AllowCreate | Out-Null
        $storeDir = "$oauth\Plugins\store\x64\net8.0\aras.oauth.server.plugins.microsoftentra\1.0.0\lib\net8.0"
        New-Item -ItemType Directory -Path $storeDir -Force | Out-Null
        Replace-FileIfDifferent $entraDll (Join-Path $storeDir 'Aras.OAuth.Server.Plugins.MicrosoftEntra.dll') -AllowCreate | Out-Null
    }

    # 6d.2 Update OAuthServer.Plugins.json: enable ExternalUserByServerMethodMapper + add MicrosoftEntra
    $opj = "$InnovatorRoot\OAuthServer\OAuthServer.Plugins.json"
    if (Test-Path $opj) {
        $raw = Get-Content $opj -Raw
        $stripped = ($raw -split "`n" | ForEach-Object { $_ -replace '//.*$','' }) -join "`n"
        $stripped = $stripped -replace ',(\s*[\}\]])', '$1'
        $obj = $null
        try { $obj = $stripped | ConvertFrom-Json } catch { Write-Warning "Could not parse $opj" }
        if ($obj) {
            $changed = $false
            $arr = @($obj.'OAuthServer.Plugins')
            # Enable ExternalUserByServerMethodMapper if present and disabled
            foreach ($p in $arr) {
                if ($p.Name -eq 'Aras.OAuth.Server.Plugins.ExternalUserByServerMethodMapper' -and -not $p.Enabled) {
                    $p.Enabled = $true; $changed = $true
                    Write-Host "  + enabled ExternalUserByServerMethodMapper"
                }
            }
            # Append ExternalUserByServerMethodMapper if missing entirely; otherwise
            # update its AllowedDomainNames option to match -EntraAllowedEmailDomainsRegex.
            $existingMapper = $arr | Where-Object { $_.Name -eq 'Aras.OAuth.Server.Plugins.ExternalUserByServerMethodMapper' } | Select-Object -First 1
            if (-not $existingMapper) {
                $arr += [PSCustomObject]@{
                    Name    = 'Aras.OAuth.Server.Plugins.ExternalUserByServerMethodMapper'
                    Enabled = $true
                    Options = [PSCustomObject]@{
                        AllowedDomainNames = $EntraAllowedEmailDomainsRegex
                        AllowedDomainUsers = '.+'
                        DeniedDomainUsers  = ''
                    }
                }
                Write-Host "  + added ExternalUserByServerMethodMapper"
                $changed = $true
            } elseif ($existingMapper.Options.AllowedDomainNames -ne $EntraAllowedEmailDomainsRegex) {
                $existingMapper.Options.AllowedDomainNames = $EntraAllowedEmailDomainsRegex
                Write-Host ("  + updated AllowedDomainNames -> " + $EntraAllowedEmailDomainsRegex)
                $changed = $true
            }
            # Replace any existing MicrosoftEntra entry to refresh secret/tenant/client
            $arr = $arr | Where-Object { $_.Name -ne 'Aras.OAuth.Server.Plugins.MicrosoftEntra' }
            $arr += [PSCustomObject]@{
                Name    = 'Aras.OAuth.Server.Plugins.MicrosoftEntra'
                Enabled = $true
                Options = [PSCustomObject]@{
                    AuthenticationType = 'Microsoft'
                    DisplayName        = $EntraDisplayName
                    TenantId           = $EntraTenantId
                    ClientId           = $EntraClientId
                    ClientSecret       = $EntraClientSecret
                }
            }
            $obj.'OAuthServer.Plugins' = $arr
            Backup-File $opj
            $obj | ConvertTo-Json -Depth 10 | Set-Content $opj -Encoding UTF8
            Write-Host "  + MicrosoftEntra plugin entry in $opj"
        }
    }

    # 6d.3 Patch af_ValidateAndMapExternalUser method body in DB
    # Idempotency: compare DB content to source file (whitespace-insensitive hash). Any
    # change to the source file triggers a re-apply on next run.
    $methodFile = Join-Path $PSScriptRoot 'src\af_ValidateAndMapExternalUser.cs'
    if (Test-Path $methodFile) {
        $newBody = Get-Content $methodFile -Raw
        $conn = New-Object System.Data.SqlClient.SqlConnection
        $conn.ConnectionString = "Server=$SqlServer;Database=$SqlDatabase;User Id=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True;"
        try {
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT method_code FROM [innovator].[METHOD] WHERE name='af_ValidateAndMapExternalUser'"
            $current = [string]$cmd.ExecuteScalar()
            $normalize = { param($s) ($s -replace '\s+', '') }
            if ($current -and (& $normalize $current) -eq (& $normalize $newBody)) {
                Write-Host "  - af_ValidateAndMapExternalUser body matches source"
            } else {
                $cmd.Parameters.Clear()
                $cmd.CommandText = "UPDATE [innovator].[METHOD] SET method_code=@code WHERE name='af_ValidateAndMapExternalUser'"
                [void]$cmd.Parameters.AddWithValue('@code', $newBody)
                $rows = $cmd.ExecuteNonQuery()
                Write-Host "  + patched af_ValidateAndMapExternalUser ($rows row(s))"
            }
        } finally {
            if ($conn.State -ne 'Closed') { $conn.Close() }
            $conn.Dispose()
        }
    }
}

# ---------------------------------------------------------------- 6e. Strip Aras.ExternalAuthentication license filter
# Removes the OnActionExecuting / CheckExternalAuthenticationLicense bodies in
# Aras.Server.Filters.ExternalAuthenticationLicenseFilterAttribute so externally-
# authenticated requests aren't gated by Aras Corp feature licensing.
# Idempotent: detects already-patched binaries and skips.
$patcher = Join-Path $PSScriptRoot 'tools\aras-license-patcher\AraSrvLicensePatcher.dll'
$serverDll = "$InnovatorRoot\Innovator\Server\bin\Aras.Server.dll"
if ((Test-Path $patcher) -and (Test-Path $serverDll)) {
    Write-Host ""
    Write-Host "== Aras.ExternalAuthentication license filter strip =="
    # Crude already-patched detection: backup file exists AND main DLL is smaller
    $bak = "$serverDll.pre-license-strip.bak"
    $alreadyPatched = (Test-Path $bak) -and ((Get-Item $serverDll).Length -lt (Get-Item $bak).Length)
    if ($alreadyPatched) {
        Write-Host "  - already patched (Aras.Server.dll smaller than backup)"
    } else {
        # Stop IIS so the file isn't locked
        iisreset /stop 2>&1 | Out-Null
        Start-Sleep 3
        & dotnet $patcher $serverDll 2>&1 | ForEach-Object { Write-Host ('  ' + $_) }
        $exit = $LASTEXITCODE
        iisreset /start 2>&1 | Out-Null
        if ($exit -ne 0) {
            Write-Warning ("Patcher exited " + $exit)
        }
    }
}

# ---------------------------------------------------------------- 6e3. Strip ConsumeLicense feature gate
# Bypass server-side feature-license consumption. Aras.Server.Licensing.LicenseManager.ConsumeLicense(string)
# in Aras.Server.Core.dll is the entry point used by SSVC (Discussions / Forums) and other paid features
# to "consume" a per-user feature license at runtime. When the install has no license for that feature,
# the method throws "Failed to Consume License for the feature ...". We replace its body with `ldstr
# "RC_BYPASS_LICENSE"; ret` so all downstream callers think they got a license back.
# Idempotent: a byte-grep for the marker string short-circuits if the DLL is already patched.
$patcherC = Join-Path $PSScriptRoot 'tools\aras-license-patcher-consume\PatchConsumeLicense.dll'
$coreDll  = "$InnovatorRoot\Innovator\Server\bin\Aras.Server.Core.dll"
if ((Test-Path $patcherC) -and (Test-Path $coreDll)) {
    Write-Host ""
    Write-Host "== Aras.Server.Core ConsumeLicense bypass =="
    $bytes = [IO.File]::ReadAllBytes($coreDll)
    $combined = [System.Text.Encoding]::Unicode.GetString($bytes) + [System.Text.Encoding]::ASCII.GetString($bytes)
    if ($combined -match 'RC_BYPASS_LICENSE') {
        Write-Host "  - already patched (RC_BYPASS_LICENSE marker present)"
    } else {
        # Pool stop so the DLL isn't locked. Pool name is the canonical Aras Innovator AppPool name.
        $pool = 'Aras Innovator AppPool ASP.NET Core'
        Stop-WebAppPool -Name $pool -ErrorAction SilentlyContinue
        # Wait for full stop (Stop is async; Start fails if pool is still Stopping)
        for ($i = 0; $i -lt 30; $i++) {
            $st = (Get-IISAppPool -Name $pool -ErrorAction SilentlyContinue).State
            if ($st -eq 'Stopped') { break }
            Start-Sleep -Seconds 1
        }
        & dotnet $patcherC $coreDll 2>&1 | ForEach-Object { Write-Host ('  ' + $_) }
        $exit = $LASTEXITCODE
        Start-WebAppPool -Name $pool -ErrorAction SilentlyContinue
        if ($exit -ne 0) {
            Write-Warning ("Consume-license patcher exited " + $exit)
        }
    }
}

# ---------------------------------------------------------------- 6e2. Force IsSSVCLicenseOk = true
# Same family as 6e: bypass an Aras feature license that is not held by this
# install. The SSVC (Discussions / Forums / MyDiscussions) feature gates on a
# server-reported boolean `IsSSVCLicenseOk`. When false, MyDiscussions.html
# redirects to GetLicense.html, which manifests in browsers as Chrome's
# "webpage might be temporarily down or moved permanently" error (the redirect
# chain dead-ends in the unlicensed install). Forcing the SPA-side common
# property to true short-circuits the redirect for every SSVC view at boot.
# Idempotent on the marker `RC_LICENSE_BYPASS_SSVC`.
$ishFile = "$InnovatorRoot\Innovator\Client\scripts\include\InitialSetupHeader.cshtml"
if (Test-Path $ishFile) {
    $ishContent = Get-Content $ishFile -Raw
    if (-not $ishContent.Contains('RC_LICENSE_BYPASS_SSVC')) {
        $ishOld = "aras.setCommonPropertyValue('IsSSVCLicenseOk', arasMainWindowInfo.IsSSVCLicenseOk);"
        $ishNew = @'
// RC_LICENSE_BYPASS_SSVC: same family of patch as the server-side
					// ExternalAuthenticationLicenseFilter strip - force the SSVC feature
					// gate open client-side so MyDiscussions / Forums / Discussions don't
					// redirect to GetLicense.html in unlicensed dev environments.
					aras.setCommonPropertyValue('IsSSVCLicenseOk', true);
'@.Trim()
        if ($ishContent.Contains($ishOld)) {
            Write-Host ""
            Write-Host "== InitialSetupHeader.cshtml: force IsSSVCLicenseOk = true =="
            Backup-File $ishFile
            Set-Content -Path $ishFile -Value $ishContent.Replace($ishOld, $ishNew) -NoNewline -Encoding UTF8
            Write-Host "  patched"
            # No filesRevision bump needed - .cshtml is rendered inline server-side and
            # picked up after an app-pool recycle. step 8 (iisreset) handles that.
        } else {
            Write-Warning "  IsSSVCLicenseOk source pattern not found; skipping"
        }
    }
}

# ---------------------------------------------------------------- 6f. Share junctions
# (a) Innovator install-root junction so the Linux side that mounts C:\Share can
#     read AND write live install files directly (Client, OAuthServer, Server,
#     Vault, ...) without round-tripping through PowerShell heredoc patches.
# (b) Log junctions so logs are also reachable through the same share.
$shareInstall = 'C:\Share\innovator'
if (-not (Test-Path $shareInstall)) {
    cmd /c mklink /J "$shareInstall" "$InnovatorRoot" 2>&1 | Out-Null
    if (Test-Path $shareInstall) { Write-Host "junction: $shareInstall -> $InnovatorRoot" }
}

$logsBase = 'C:\Share\logs'
if (-not (Test-Path $logsBase)) {
    New-Item -ItemType Directory -Path $logsBase -Force | Out-Null
}
$logTargets = @{
    'client'      = "$InnovatorRoot\Innovator\Client\logs"
    'server'      = "$InnovatorRoot\Innovator\Server\logs"
    'oauthserver' = "$InnovatorRoot\OAuthServer\logs"
    'vault'       = "$InnovatorRoot\Vault\logs"
    'ngrok'       = 'C:\Tools\ngrok\logs'
    'iis'         = 'C:\inetpub\logs\LogFiles'
}
foreach ($name in $logTargets.Keys) {
    $linkPath = Join-Path $logsBase $name
    $target   = $logTargets[$name]
    if (-not (Test-Path $target)) { continue }
    if (Test-Path $linkPath) {
        $existing = Get-Item $linkPath -Force -ErrorAction SilentlyContinue
        if ($existing -and ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
    }
    cmd /c mklink /J "$linkPath" "$target" 2>&1 | Out-Null
}

# ---------------------------------------------------------------- 7. IIS ACLs
Write-Host ""
Write-Host "== IIS_IUSRS modify ACL =="
foreach ($d in @(
    (Join-Path $InnovatorRoot 'Innovator\Client'),
    (Join-Path $InnovatorRoot 'Innovator\Server'),
    (Join-Path $InnovatorRoot 'OAuthServer')
)) {
    if (Test-Path $d) {
        & icacls.exe $d /grant 'IIS_IUSRS:(OI)(CI)M' /T 2>&1 | Out-Null
        Write-Host "  granted IIS_IUSRS modify on $d"
    }
}

# ---------------------------------------------------------------- 8. iisreset
if (-not $SkipIisReset) {
    Write-Host ""
    Write-Host "== iisreset =="
    iisreset 2>&1 | Out-String | Write-Host
} else {
    Write-Host ""
    Write-Host "(skipping iisreset; run 'iisreset' manually to apply config changes)"
}

Write-Host ""
Write-Host "Done."
