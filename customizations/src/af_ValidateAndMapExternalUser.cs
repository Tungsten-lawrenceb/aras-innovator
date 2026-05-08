// af_ValidateAndMapExternalUser — RC-extended version
// Original handles only "WindowsRemote" auth type. We add a "Microsoft" branch
// for Entra ID OIDC users, mapping by email -> login_name (UPN), with
// auto-create on first login.
//
// This entire body replaces the body of the existing C# Method
// `af_ValidateAndMapExternalUser` in the InnovatorSolutions database.
LookupError = (name) => CCO.ErrorLookup.Lookup(name);
LookupError1 = (name, param1) => CCO.ErrorLookup.Lookup(name, param1);
_permissions = CCO.Permissions;
return Invoke();
}

internal Func<string, string> LookupError;
internal Func<string, string, string> LookupError1;
internal Aras.Server.Core.Permissions _permissions;

internal Item Invoke()
{
	string claimsPrincipalJson = getProperty("user_claims_principal");
	System.Security.Claims.ClaimsPrincipal claimsPrincipal = ClaimsPrincipalFromJson(claimsPrincipalJson);
	Item user = ValidateAndMapExternalUser(claimsPrincipal);
	return user;
}

internal Item ValidateAndMapExternalUser(System.Security.Claims.ClaimsPrincipal claimsPrincipal)
{
	string authenticationType = claimsPrincipal.Identity.AuthenticationType;
	if (authenticationType == "WindowsRemote")
	{
		return ValidateAndMapWindowsUser(claimsPrincipal);
	}
	else if (authenticationType == "Microsoft")
	{
		return ValidateAndMapMicrosoftUser(claimsPrincipal);
	}
	else
	{
		throw new NotSupportedException(
			LookupError1("af_AuthenticationTypeIsNotSupported", authenticationType));
	}
}

// =================== Microsoft Entra =====================
internal Item ValidateAndMapMicrosoftUser(System.Security.Claims.ClaimsPrincipal claimsPrincipal)
{
	string email      = GetClaimValue(claimsPrincipal, "email")
	                 ?? GetClaimValue(claimsPrincipal, "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress")
	                 ?? GetClaimValue(claimsPrincipal, "preferred_username");
	string upn        = GetClaimValue(claimsPrincipal, "preferred_username")
	                 ?? GetClaimValue(claimsPrincipal, "upn")
	                 ?? GetClaimValue(claimsPrincipal, "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn")
	                 ?? email;
	string nameClaim  = GetClaimValue(claimsPrincipal, "name") ?? "";

	if (string.IsNullOrEmpty(email) && string.IsNullOrEmpty(upn))
	{
		throw new InvalidOperationException("Entra claims missing both 'email' and 'preferred_username' / 'upn'.");
	}

	Innovator inn = getInnovator();

	// 1. Match by email
	if (!string.IsNullOrEmpty(email))
	{
		Item u = inn.newItem("User", "get");
		u.setProperty("email", email);
		u.setProperty("logon_enabled", "1");
		u.setAttribute("select", "login_name");
		u = u.apply();
		if (!u.isError() && u.getItemCount() == 1)
		{
			return u;
		}
	}

	// 2. Match by login_name == UPN
	if (!string.IsNullOrEmpty(upn))
	{
		Item u = inn.newItem("User", "get");
		u.setProperty("login_name", upn);
		u.setProperty("logon_enabled", "1");
		u.setAttribute("select", "login_name");
		u = u.apply();
		if (!u.isError() && u.getItemCount() == 1)
		{
			return u;
		}
	}

	// 3. Auto-create on first login
	return AutoCreateMicrosoftUser(inn, email, upn, nameClaim);
}

internal Item AutoCreateMicrosoftUser(Innovator inn, string email, string upn, string displayName)
{
	string loginName = !string.IsNullOrEmpty(upn) ? upn : email;
	string firstName = "";
	string lastName  = "";
	if (!string.IsNullOrEmpty(displayName))
	{
		string[] parts = displayName.Split(new[] { ' ' }, 2);
		firstName = parts[0];
		if (parts.Length > 1) lastName = parts[1];
	}

	// Elevate to "Administrators" — the impersonation context invoking this method
	// (OAuthServer authadmin) doesn't have add-User permission. This is the canonical
	// Aras pattern (cf. acs_CreateTeamForSharing in shipped methods).
	var adminIdent = Aras.Server.Security.Identity.GetByName("Administrators");

	Item created;
	using (_permissions.GrantIdentity(adminIdent))
	{
		Item add = inn.newItem("User", "add");
		add.setProperty("login_name", loginName);
		if (!string.IsNullOrEmpty(email))     add.setProperty("email", email);
		if (!string.IsNullOrEmpty(firstName)) add.setProperty("first_name", firstName);
		if (!string.IsNullOrEmpty(lastName))  add.setProperty("last_name", lastName);
		add.setProperty("logon_enabled", "1");
		// Random password — never used (login goes through Entra), but Aras requires non-null
		string randomPwd = System.Guid.NewGuid().ToString("N") + System.Guid.NewGuid().ToString("N");
		add.setProperty("password", System.BitConverter.ToString(
			System.Security.Cryptography.MD5.Create().ComputeHash(System.Text.Encoding.Unicode.GetBytes(randomPwd))
		).Replace("-", "").ToLowerInvariant());
		created = add.apply();
		if (created.isError())
		{
			throw new Aras.Server.Core.InnovatorServerException(
				"Failed to auto-create Aras user for '" + loginName + "': " + created.getErrorString());
		}

		// Add to "Innovator User" identity (default group for general access)
		Item idQ = inn.newItem("Identity", "get");
		idQ.setProperty("name", "Innovator User");
		Item idR = idQ.apply();
		if (!idR.isError() && idR.getItemCount() == 1)
		{
			Item member = inn.newItem("Member", "add");
			member.setProperty("source_id", idR.getID());
			member.setProperty("related_id", created.getID());
			member.apply();
		}
	}

	// Re-fetch with login_name to match the contract expected by ExternalUserByServerMethodMapper
	Item ret = inn.newItem("User", "get");
	ret.setProperty("login_name", loginName);
	ret.setAttribute("select", "login_name");
	return ret.apply();
}

internal static string GetClaimValue(System.Security.Claims.ClaimsPrincipal cp, string claimType)
{
	System.Security.Claims.Claim c = cp.Claims.FirstOrDefault(x => x.Type == claimType);
	return c == null ? null : c.Value;
}
// =================== /Microsoft Entra =====================

/// <summary>
/// Creates Item based on name claim from ClaimsPrincipal.
/// </summary>
/// <remarks>
/// Method expects external username in the following format: "DomainName\UserName".
/// Username parsing from Windows format "UserName@DomainName" is not supported, because IIS
/// Windows authentication is configured to return username in "DomainName\UserName" format.
///</remarks>
/// <param name="claimsPrincipal">External user credentials.</param>
/// <returns>User Item.</returns>
internal Item ValidateAndMapWindowsUser(System.Security.Claims.ClaimsPrincipal claimsPrincipal)
{
	System.Security.Claims.Claim nameClaim = claimsPrincipal.Claims.FirstOrDefault(claim => claim.Type == System.Security.Claims.ClaimTypes.Name);
	if (nameClaim == null)
	{
		throw new InvalidOperationException(
			LookupError("af_CannotFindNameClaim"));
	}
	string accountName = nameClaim.Value;
	NetworkCredential credentials = ParseWindowsAccountName(accountName);
	string userName = credentials.UserName;
	string domainName = credentials.Domain;

	ValidateDomainAndUser(domainName, userName);

	Item user = MapExternalUserByName(userName);
	return user;
}

internal NetworkCredential ParseWindowsAccountName(string accountName)
{
	string[] accountNameParts = accountName.Split('\\');
	string domainName = null;
	string userName = null;
	if (accountNameParts.Length != 2)
	{
		throw new InvalidOperationException(
			LookupError1("af_InvalidFormatOfAccountName", accountName));
	}
	else
	{
		domainName = accountNameParts[0];
		userName = accountNameParts[1];
	}
	if (string.IsNullOrEmpty(domainName))
	{
		throw new InvalidOperationException(LookupError("af_DomainNameIsEmpty"));
	}
	if (string.IsNullOrEmpty(userName))
	{
		throw new InvalidOperationException(LookupError("af_UserNameIsEmpty"));
	}

	NetworkCredential credentials = new NetworkCredential(userName, string.Empty, domainName);
	return credentials;
}

internal Item MapExternalUserByName(string userName)
{
	Innovator innovator = getInnovator();
	Item user = innovator.newItem("user", "get");
	user.setProperty("login_name", userName);
	user.setProperty("logon_enabled", "1");
	user.setAttribute("select", "login_name");
	user = user.apply();
	if (user.isError())
	{
		throw new Aras.Server.Core.InnovatorServerException(
			LookupError1("af_LoginFailed", userName));
	}
	return user;
}

internal static System.Security.Claims.ClaimsPrincipal ClaimsPrincipalFromJson(string claimsPrincipalJson)
{
	var serializerSettings = new Newtonsoft.Json.JsonSerializerSettings { DateParseHandling = Newtonsoft.Json.DateParseHandling.None };
	var claimsPrincipalDictionary = Newtonsoft.Json.JsonConvert.DeserializeObject<Dictionary<string, object>>(claimsPrincipalJson, serializerSettings);

	string authenticationType = (string)claimsPrincipalDictionary["authentication_type"];

	var claimsData = claimsPrincipalDictionary["claims"] as Newtonsoft.Json.Linq.JArray;
	var claims = claimsData.Select(
		claimData => new System.Security.Claims.Claim(
			claimData["type"].ToString(),
			claimData["value"].ToString()));

	var claimsIdentity = new System.Security.Claims.ClaimsIdentity(claims, authenticationType);
	var claimsPrincipal = new System.Security.Claims.ClaimsPrincipal(claimsIdentity);
	return claimsPrincipal;
}

internal void ValidateDomainAndUser(string domainName, string userName)
{
	string allowedDomainNamesPattern = getProperty("allowed_domain_names");
	if (!string.IsNullOrEmpty(allowedDomainNamesPattern))
	{
		bool isDomainAllowed = new System.Text.RegularExpressions.Regex(
			allowedDomainNamesPattern,
			System.Text.RegularExpressions.RegexOptions.IgnoreCase)
			.IsMatch(domainName);
		if (!isDomainAllowed)
		{
			throw new Aras.Server.Core.InnovatorServerException(
				LookupError1("af_AccessDeniedByDomainName", domainName));
		}
	}
	string allowedDomainUsersPattern = getProperty("allowed_domain_users");
	if (!string.IsNullOrEmpty(allowedDomainUsersPattern))
	{
		bool isUserAllowed = new System.Text.RegularExpressions.Regex(
			allowedDomainUsersPattern,
			System.Text.RegularExpressions.RegexOptions.IgnoreCase)
			.IsMatch(userName);
		if (!isUserAllowed)
		{
			throw new Aras.Server.Core.InnovatorServerException(
				LookupError1("af_AccessDeniedByUserName", userName));
		}
	}
	string deniedDomainUsersPattern = getProperty("denied_domain_users");
	if (!string.IsNullOrEmpty(deniedDomainUsersPattern))
	{
		bool isUserDenied = new System.Text.RegularExpressions.Regex(
			deniedDomainUsersPattern,
			System.Text.RegularExpressions.RegexOptions.IgnoreCase)
			.IsMatch(userName);
		if (isUserDenied)
		{
			throw new Aras.Server.Core.InnovatorServerException(
				LookupError1("af_AccessDeniedByUserName", userName));
		}
	}
