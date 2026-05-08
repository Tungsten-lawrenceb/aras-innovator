Robotics Centre customizations for Aras Innovator
==================================================

apply-customizations.ps1
    Idempotent script that re-applies all RC tweaks to an Aras install.
    Run it after:
      - A fresh Aras Innovator install (after running InnovatorSetup.msi)
      - An Aras platform version upgrade
      - An Aras Update package install that touched /Innovator/Client or /OAuthServer

    Usage (Server Core PowerShell):
      PS> C:\Share\customizations\apply-customizations.ps1

    Optional flags:
      -InnovatorRoot "<path>"   Override install root
                                (default: C:\Program Files (x86)\Aras\Innovator)
      -ProductName "<text>"     Title-bar text (default: "RC PLM")
      -Hosts "<a>","<b>"        Hostnames the OAuth registry should accept
                                (default: localhost, ARAS-WIN22K2, 192.168.1.104)
      -SkipIisReset             Don't iisreset at the end

    What it changes (each step backs up originals as <file>.preRC-<ts>.bak):
      1. Branding: HeaderLogo*.svg, aras-innovator.svg, arasInnovator.svg,
         favicon.ico (×6 paths), all from .\images\
      2. product_name = "RC PLM" in InnovatorServerConfig.xml & OAuthServer.config
      3. OAuth.ClientServer.config:  password="innovator" -> password=""
         (the shipped PFX has an empty password but config says "innovator")
      4. OAuthServer/OAuth.config InnovatorClient registry:
           - adds redirect_uri / post_logout / cors_origin entries for each Host
           - adds 'profile' scope
      5. OAuthServerDiscovery URLs (advertised to the SPA so it bootstraps OAuth
         from the same hostname the user hit, avoiding cross-origin errors)
      6. login.js: pre-converts password to UTF-16LE bytes before RSA-encrypting,
         which is what Aras Authenticate.aspx expects (shipped login.js sends
         UTF-8, which fails for any password containing only ASCII characters)
      7. IIS_IUSRS modify ACL on Innovator\Client, Innovator\Server, OAuthServer
         (so DataProtection key writes and jsBundles\compile.log writes succeed)
      8. iisreset

images/
    Source assets used by the script.
    Drop replacements in here (same filenames) and re-run.

      HeaderLogo.svg          In-app SPA top-bar logo (classic header path)
      HeaderLogoNash.svg      In-app SPA top-bar logo (Nash modern header path)
      aras-innovator.svg      Misc branding (some help/docs pages)
      arasInnovator.svg       Login page logo (rc-stacked variant)
      favicon.ico             Browser-tab icon (multi-size: 16/24/32/48/64/128/256)

If the in-app logo doesn't update after running the script, hard-refresh the
browser (Ctrl+Shift+R) - the SPA caches assets aggressively, and the X-salt
URL prefix doesn't change unless the Aras build version does.
