using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Aras.Plugins.ForwardedHeaders;

[assembly: HostingStartup(typeof(HostingStartup))]
namespace Aras.Plugins.ForwardedHeaders;

// Honors X-Forwarded-Proto / X-Forwarded-Host so that when Aras Innovator
// is reached via an HTTPS reverse proxy (ngrok, IIS+TLS, Cloudflare, etc.)
// IdentityServer4 generates absolute URLs (authorize_endpoint, token_endpoint,
// jwks_uri, etc.) with the public scheme/host instead of the inner http one.
public class HostingStartup : IHostingStartup
{
    public void Configure(IWebHostBuilder builder)
    {
        builder.ConfigureServices((ctx, services) =>
        {
            services.Configure<ForwardedHeadersOptions>(o =>
            {
                o.ForwardedHeaders =
                      Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedFor
                    | Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedProto
                    | Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedHost;

                // Trust forwarders from any IP (ngrok edge IPs are not stable)
                o.KnownNetworks.Clear();
                o.KnownProxies.Clear();

                // Two hops in this topology: external proxy -> IIS -> kestrel.
                // X-Forwarded-Proto arrives as "https, http" — ForwardLimit=2 lets the
                // middleware walk past the inner http and pick up the original https.
                o.ForwardLimit = 2;
            });

            services.TryAddEnumerable(
                ServiceDescriptor.Transient<IStartupFilter, ForwardedHeadersStartupFilter>());
        });
    }
}

internal sealed class ForwardedHeadersStartupFilter : IStartupFilter
{
    public System.Action<IApplicationBuilder> Configure(System.Action<IApplicationBuilder> next)
    {
        return app =>
        {
            app.UseForwardedHeaders();
            next(app);
        };
    }
}
