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

	// Domain allowlist — required for multi-tenant App Registrations so that not
	// every Entra principal in the world can mint an Aras account. Plugin option
	// `AllowedDomainNames` is a regex applied to the part of the address after '@'.
	// Defaults to `.*` (allow all) if the plugin doesn't set it.
	//
	// SECURITY NOTE: when the OIDC plugin is configured for multi-tenant
	// (TenantId="common"|"organizations") this allowlist is the ONLY gate keeping
	// arbitrary Entra principals out. Don't relax it without understanding that.
	string allowedEmailDomains = getProperty("allowed_domain_names");
	if (!string.IsNullOrEmpty(allowedEmailDomains) && allowedEmailDomains != ".*")
	{
		string addressForCheck = !string.IsNullOrEmpty(email) ? email : upn;

		// Reject pathological addresses with multiple '@' signs (e.g. "a@b@allowed.com").
		// Per RFC 5321 a valid address has exactly one '@' between local and domain.
		int firstAt = addressForCheck.IndexOf('@');
		int lastAt  = addressForCheck.LastIndexOf('@');
		if (firstAt < 0 || firstAt != lastAt)
		{
			throw new Aras.Server.Core.InnovatorServerException(
				"Malformed email address (rejected by domain allowlist).");
		}

		string emailDomain = addressForCheck.Substring(lastAt + 1).Trim().ToLowerInvariant();

		// IDNA normalize so an admin-supplied punycode domain matches a Unicode
		// claim domain and vice versa. GetAscii throws for invalid labels —
		// catch and reject.
		try
		{
			emailDomain = new System.Globalization.IdnMapping().GetAscii(emailDomain);
		}
		catch (System.ArgumentException)
		{
			throw new Aras.Server.Core.InnovatorServerException(
				"Email domain '" + emailDomain + "' is not a valid IDN.");
		}

		bool ok = false;
		try
		{
			// 100ms regex timeout: admin-supplied pattern is potentially adversarial; ReDoS
			// shouldn't be able to hang the worker.
			ok = System.Text.RegularExpressions.Regex.IsMatch(
				emailDomain, allowedEmailDomains,
				System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant,
				System.TimeSpan.FromMilliseconds(100));
		}
		catch (System.Text.RegularExpressions.RegexMatchTimeoutException)
		{
			throw new Aras.Server.Core.InnovatorServerException(
				"Email-domain allowlist regex timed out (ReDoS guard tripped). Fix AllowedDomainNames configuration.");
		}

		if (!ok)
		{
			throw new Aras.Server.Core.InnovatorServerException(
				"Email domain '" + emailDomain + "' is not in the allowlist (" + allowedEmailDomains + ")");
		}
	}

	Innovator inn = getInnovator();

	// 1. Match by login_name == UPN (preferred — UPN is immutable in Entra)
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

	// 2. Fallback: match by email (mutable — risk of re-linking to a different
	// principal if a tenant admin reassigns the address). UPN-first above mitigates
	// this for the common case.
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

		// Aras's AML User-add automatically creates the per-user alias Identity (the
		// row that group-membership links target). It is NOT the User's id — it's
		// linked via the Alias relationship: Alias.source_id = User.id, Alias.related_id
		// = the per-user Identity id. Look it up and use that for the Member row.
		Item aliasQ = inn.newItem("User", "get");
		aliasQ.setProperty("id", created.getID());
		aliasQ.setAttribute("select", "id");
		Item aliasRel = aliasQ.createRelationship("Alias", "get");
		aliasRel.setAttribute("select", "related_id");
		Item aliasResult = aliasQ.apply();

		string aliasIdentityId = null;
		if (!aliasResult.isError() && aliasResult.getItemCount() == 1)
		{
			Item rels = aliasResult.getRelationships();
			if (rels.getItemCount() == 1)
			{
				aliasIdentityId = rels.getItemByIndex(0).getProperty("related_id");
			}
		}

		// Add to a configurable list of Aras Identities. The list is read from an
		// Aras Variable named "AutoMemberIdentities" (looked up on every auto-create
		// so operator changes take effect without rebuilding the Method). Format:
		// comma-separated Identity names. Missing / empty -> default "Aras PLM".
		//
		// Why a Variable and not a plugin Option: the shipped
		// ExternalUserByServerMethodMapper.dll only forwards three specific Options
		// (AllowedDomainNames, AllowedDomainUsers, DeniedDomainUsers) as snake_case
		// properties; arbitrary Options are NOT plumbed through to the invoked
		// Method (verified via Cecil decompilation by codex review).
		//
		// To change membership defaults: edit the Variable via the Aras admin UI
		// (TOC -> Administration -> Variables) or run set-variable.ps1.
		//
		// Value examples:
		//   "Aras PLM"                    -> default, basic user
		//   "Aras PLM,Innovator Admin"    -> every new SSO user is also an admin
		//   "Aras PLM,All Employees"      -> org-wide users group
		//
		// Failure model:
		//   - missing alias Identity     -> hard throw (would leave unusable user)
		//   - typo'd / missing Identity  -> soft fail per identity, continue
		//   - Member.add failure         -> soft fail per identity, continue
		//   - already a member           -> idempotent skip (counts as success)
		//   - no identity succeeded      -> hard throw at end
		if (string.IsNullOrEmpty(aliasIdentityId))
		{
			throw new Aras.Server.Core.InnovatorServerException(
				"Auto-created user '" + loginName + "' has no alias Identity row - refusing to leave it without group membership.");
		}

		// Read AutoMemberIdentities Variable from the Innovator DB.
		string memberConfig = null;
		Item varQ = inn.newItem("Variable", "get");
		varQ.setProperty("name", "AutoMemberIdentities");
		varQ.setAttribute("select", "value");
		Item varR = varQ.apply();
		if (!varR.isError() && varR.getItemCount() == 1)
		{
			memberConfig = varR.getProperty("value");
		}

		System.Collections.Generic.List<string> memberIdentities = new System.Collections.Generic.List<string>();
		if (string.IsNullOrEmpty(memberConfig))
		{
			memberIdentities.Add("Aras PLM");
		}
		else
		{
			foreach (string raw in memberConfig.Split(','))
			{
				string trimmed = raw.Trim();
				if (!string.IsNullOrEmpty(trimmed)) { memberIdentities.Add(trimmed); }
			}
			if (memberIdentities.Count == 0)
			{
				memberIdentities.Add("Aras PLM");
			}
		}

		int successCount = 0;
		System.Collections.Generic.List<string> failures = new System.Collections.Generic.List<string>();

		foreach (string identityName in memberIdentities)
		{
			// 1. Resolve Identity by name
			Item idQ = inn.newItem("Identity", "get");
			idQ.setProperty("name", identityName);
			Item idR = idQ.apply();
			if (idR.isError() || idR.getItemCount() != 1)
			{
				failures.Add("identity '" + identityName + "' not found");
				continue;
			}
			string sourceId = idR.getID();

			// 2. Idempotency: skip if user is already a Member
			Item exQ = inn.newItem("Member", "get");
			exQ.setProperty("source_id", sourceId);
			exQ.setProperty("related_id", aliasIdentityId);
			Item exR = exQ.apply();
			if (!exR.isError() && exR.getItemCount() > 0)
			{
				successCount++;
				continue;
			}

			// 3. Add the Member relationship
			Item member = inn.newItem("Member", "add");
			member.setProperty("source_id", sourceId);
			member.setProperty("related_id", aliasIdentityId);
			Item memberResult = member.apply();
			if (memberResult.isError())
			{
				failures.Add("'" + identityName + "' Member.add failed: " + memberResult.getErrorString());
				continue;
			}
			successCount++;
		}

		if (successCount == 0)
		{
			string failuresStr = string.Join("; ", failures.ToArray());
			string configuredStr = string.Join(", ", memberIdentities.ToArray());
			throw new Aras.Server.Core.InnovatorServerException(
				"Auto-created user '" + loginName + "' could not be added to ANY group identity. " +
				"Configured: [" + configuredStr + "]. Failures: [" + failuresStr + "]. " +
				"Either create the missing identities in Aras, or update the AutoMemberIdentities Variable.");
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
