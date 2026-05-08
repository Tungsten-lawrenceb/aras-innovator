using System;
using System.Reflection;
using System.Threading.Tasks;
using Aras.OAuth.Server.Infrastructure;
using Aras.OAuth.Server.Plugins.MicrosoftEntra;
using Aras.Plugins.Infrastructure;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;

[assembly: HostingStartup(typeof(HostingStartup))]
namespace Aras.OAuth.Server.Plugins.MicrosoftEntra;

public class HostingStartup : IHostingStartup
{
    public void Configure(IWebHostBuilder builder)
    {
        builder.ConfigureServices((ctx, services) =>
        {
            var assembly = typeof(HostingStartup).Assembly;
            IConfiguration cfg = Aras.Plugins.Infrastructure.ConfigurationExtensions
                .GetPluginConfiguration(ctx.Configuration, assembly);
            var opts = new EntraOptions();
            cfg.Bind(opts);

            // No-op if not properly configured
            if (string.IsNullOrWhiteSpace(opts.TenantId) || string.IsNullOrWhiteSpace(opts.ClientId))
                return;

            // Multi-tenant support: when TenantId is "common" or "organizations" use the
            // matching well-known endpoint and validate issuer against an allowlist driven
            // from configuration (the email-domain gate in af_ValidateAndMapExternalUser is
            // the actual access boundary; this issuer check just keeps things tidy).
            bool isMultiTenant = string.Equals(opts.TenantId, "common", StringComparison.OrdinalIgnoreCase)
                              || string.Equals(opts.TenantId, "organizations", StringComparison.OrdinalIgnoreCase);

            services.AddAuthentication()
                .AddOpenIdConnect(opts.AuthenticationType, opts.DisplayName, o =>
                {
                    o.Authority = $"https://login.microsoftonline.com/{opts.TenantId}/v2.0";
                    o.ClientId = opts.ClientId;
                    o.ClientSecret = opts.ClientSecret;

                    o.ResponseType = OpenIdConnectResponseType.Code;
                    o.UsePkce = true;
                    o.SaveTokens = false;            // tokens are not forwarded; don't persist
                    o.GetClaimsFromUserInfoEndpoint = true;
                    o.CallbackPath = "/signin-microsoft";
                    o.SignedOutCallbackPath = "/signout-callback-microsoft";

                    o.Scope.Clear();
                    o.Scope.Add("openid");
                    o.Scope.Add("profile");
                    o.Scope.Add("email");

                    // Use the same ExternalCookie scheme that Aras's ExternalController.Callback reads
                    o.SignInScheme = ctx.Configuration.GetSignInScheme();

                    o.TokenValidationParameters = new TokenValidationParameters
                    {
                        NameClaimType = "preferred_username",
                        ValidateIssuer = !isMultiTenant,    // multi-tenant: tenant-id varies in iss
                    };
                    if (isMultiTenant)
                    {
                        // Allow any tenant — domain allowlist downstream is the real gate.
                        o.TokenValidationParameters.IssuerValidator = (string iss, SecurityToken _, TokenValidationParameters _) => iss;
                    }

                    o.Events = new OpenIdConnectEvents
                    {
                        OnTokenValidated = ctxArgs => Task.CompletedTask,
                        // Don't pass an arbitrary errorId to Aras's Account/Login (its
                        // ErrorDispatcher expects an IdentityServer4-issued errorId and NREs
                        // on anything else). Return a generic message — don't echo provider
                        // exception detail back to the browser (info disclosure).
                        OnRemoteFailure = ctxArgs =>
                        {
                            ctxArgs.Response.StatusCode = 502;
                            ctxArgs.Response.ContentType = "text/plain; charset=utf-8";
                            var bytes = System.Text.Encoding.UTF8.GetBytes(
                                "Sign-in with Microsoft failed. Contact your administrator if this persists.\n");
                            var t = ctxArgs.Response.Body.WriteAsync(bytes, 0, bytes.Length);
                            ctxArgs.HandleResponse();
                            return t;
                        }
                    };
                });
        });
    }
}

internal sealed class EntraOptions
{
    public string AuthenticationType { get; set; } = "Microsoft";
    public string DisplayName { get; set; } = "Sign in with Microsoft";
    public string TenantId { get; set; } = "";
    public string ClientId { get; set; } = "";
    public string ClientSecret { get; set; } = "";
}
