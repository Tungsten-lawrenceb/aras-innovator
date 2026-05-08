# Aras Innovator — Robotics Centre customizations

Custom plugins, configuration, branding, and reproducible deployment script for the
Robotics Centre instance of Aras Innovator 2025 (build 14.35.0).

## Layout

```
customizations/
├── apply-customizations.ps1     Idempotent deploy script — re-apply after upgrades
├── README.txt                   Operational notes
├── images/                      Branded logos + favicon (sources)
├── bin/                         Built plugin DLLs (and their deps.json)
├── src/                         Source for everything we built:
│   ├── Aras.Plugins.ForwardedHeaders/                   X-Forwarded-Proto handling
│   ├── Aras.OAuth.Server.Plugins.MicrosoftEntra/        OIDC plugin for Entra ID
│   ├── aras-license-patcher/                            Strips ExternalAuthentication license filter
│   └── af_ValidateAndMapExternalUser.cs                 Extended Aras Method body
└── tools/aras-license-patcher/  Compiled patcher binaries

aras-files-snapshot/             Live snapshot of every Aras file we modified.
                                 Captured from the running install, secrets redacted.
                                 NOT meant to be diff-applied directly — use this as a
                                 reference for what apply-customizations.ps1 produces.
```

## What apply-customizations.ps1 does

Run after a fresh Aras install or any platform upgrade. Idempotent — safe to re-run.

1. **Branding** — HeaderLogo*.svg, aras-innovator.svg, arasInnovator.svg (login),
   favicon.ico (×6 paths)
2. **Product name** — `<UI-Tailoring product_name="RC PLM" />` and OAuthServer.config
3. **InnovatorClientServer.pfx password fix** — config says "innovator", PFX is empty
4. **OAuth registry** — redirect URIs / CORS / `profile` scope for hostnames in `-Hosts`
5. **OAuthServerDiscovery URLs** — populate so the SPA hits same-origin OAuth
6. **login.js patches** — UTF-16LE password encoding (Aras's shipped login.js sends
   UTF-8, but Authenticate.aspx expects UTF-16LE bytes), and the SSO button injector
6b. **PhoneHomeCall silencer** — adds `.catch(() => {})` to the SPA's phone-home calls
6c. **External HTTPS host** — IIS URL Rewrite rule to honor `X-Forwarded-Proto`,
    Aras.Plugins.ForwardedHeaders DLL deployment, ngrok host added to OAuth registry
6d. **Entra OIDC plugin** — Aras.OAuth.Server.Plugins.MicrosoftEntra DLL deployment
    plus `ExternalUserByServerMethodMapper` + extended `af_ValidateAndMapExternalUser`
6e. **Aras.ExternalAuthentication license filter strip** — neuters the feature license
    gate in Aras.Server.dll so external auth works without a feature license.
    *The original DLL is backed up alongside as `*.pre-license-strip.bak`.*
7. **IIS_IUSRS modify ACL** — granted on Client/Server/OAuthServer folders
8. **iisreset**

## Required parameters when running

```powershell
PS> C:\Share\customizations\apply-customizations.ps1 `
        -EntraTenantId     '<your tenant guid>' `
        -EntraClientId     '<your app reg client id>' `
        -EntraClientSecret '<your client secret value>' `
        -SqlPassword       '<sa or db owner password>' `
        -ExternalHttpsUrl  'https://<your-ngrok-or-public-host>'
```

Other defaults are documented at the top of the script.

## Plugin source notes

### `Aras.Plugins.ForwardedHeaders`
.NET 8 ASP.NET Core IHostingStartup. References Aras's shipped DLLs (no NuGet
deps that conflict with what Aras already loads). Adds `UseForwardedHeaders()`
via an IStartupFilter and clears `KnownNetworks`/`KnownProxies` so that
forwarders from any source are accepted. `ForwardLimit = 2` because the chain is
`external proxy → IIS → kestrel`, producing `X-Forwarded-Proto: "https, http"`.

### `Aras.OAuth.Server.Plugins.MicrosoftEntra`
Registers an OpenID Connect external auth scheme named `Microsoft` against the
configured Entra tenant. Hooks into Aras's existing
`Aras.OAuth.Server.Plugins.ExternalUserByServerMethodMapper` so that the SOAP
method `af_ValidateAndMapExternalUser` resolves the Entra user → Aras user.

### `af_ValidateAndMapExternalUser` (extended)
Adds an `authentication_type == "Microsoft"` branch. Match by `email`, then by
`preferred_username` / `upn`. Auto-create on first login, with elevation to
`Administrators` identity for the User-add and Member-add operations (otherwise
the OAuthServer impersonation context lacks add-User permission).

### `aras-license-patcher` (Mono.Cecil)
Edits `Aras.Server.dll` IL in place:
`Aras.Server.Filters.ExternalAuthenticationLicenseFilterAttribute.OnActionExecuting`
and `CheckExternalAuthenticationLicense` are replaced with empty bodies. The
license check otherwise throws `Aras.Server.Licensing.FeatureHasNoLicensesException`
on every external-auth request when the install lacks an
`Aras.ExternalAuthentication` feature license (a paid Aras Corp add-on).

## Secrets

All sensitive values have been redacted to placeholders (`<<...>>`):
* `<<ENTRA_CLIENT_SECRET>>` — your Entra App Registration client secret
* `<<DB_PASSWORD>>` — SQL Server `sa` or DB-owner password set during install

Don't commit real values back to this repo.
