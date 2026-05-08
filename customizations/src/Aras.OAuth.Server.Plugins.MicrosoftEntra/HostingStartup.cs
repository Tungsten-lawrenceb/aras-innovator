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

            services.AddAuthentication()
                .AddOpenIdConnect(opts.AuthenticationType, opts.DisplayName, o =>
                {
                    o.Authority = $"https://login.microsoftonline.com/{opts.TenantId}/v2.0";
                    o.ClientId = opts.ClientId;
                    o.ClientSecret = opts.ClientSecret;

                    o.ResponseType = OpenIdConnectResponseType.Code;
                    o.UsePkce = true;
                    o.SaveTokens = true;
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
                        // Validate the issuer against Entra's tenant-specific URL
                        ValidateIssuer = true,
                    };

                    // Entra returns claims in v2 endpoint with "oid" (object ID) — keep as-is.
                    // Convert id_token "name" claim into a stable value the af_ method can use.
                    o.Events = new OpenIdConnectEvents
                    {
                        OnTokenValidated = ctxArgs => Task.CompletedTask,
                        // Don't pass an arbitrary errorId to Aras's Account/Login (its
                        // ErrorDispatcher expects an IdentityServer4-issued errorId and NREs
                        // on anything else). Show the raw error inline so we can debug.
                        OnRemoteFailure = ctxArgs =>
                        {
                            var msg = ctxArgs.Failure?.Message ?? "unknown remote failure";
                            ctxArgs.Response.StatusCode = 502;
                            ctxArgs.Response.ContentType = "text/plain; charset=utf-8";
                            var bytes = System.Text.Encoding.UTF8.GetBytes(
                                "Microsoft Entra sign-in failed.\n\n" + msg + "\n");
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
