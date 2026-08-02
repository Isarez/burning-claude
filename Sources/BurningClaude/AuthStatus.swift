import Foundation

/// The account Claude Code is actually signed in as, according to Claude Code.
///
/// This exists because `.claude.json`'s `oauthAccount` block cannot be trusted
/// to be current. The live credential lives in the Keychain, and after an
/// account switch `oauthAccount` can keep describing the *previous* account
/// indefinitely — as can `cachedUsageUtilization` alongside it. Reporting from
/// that block alone means showing one account's identity and another account's
/// usage. `claude auth status` reads the real credential, so it is the
/// authority on who is signed in.
struct AuthStatus {
    var email: String
    var organizationID: String
    var organizationName: String
    var subscriptionType: String
}

enum AuthStatusReader {

    /// Runs `claude auth status` against a config root. Returns nil when the
    /// CLI is missing or reports no session, in which case callers should fall
    /// back to the `oauthAccount` block.
    static func read(root: ConfigRoot, claude: URL) -> AuthStatus? {
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = root.path

        guard let data = Shell.run(claude, ["auth", "status"], environment: env) else { return nil }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["loggedIn"] as? Bool == true,
              let email = obj["email"] as? String
        else { return nil }

        return AuthStatus(
            email: email,
            organizationID: obj["orgId"] as? String ?? "",
            organizationName: obj["orgName"] as? String ?? "",
            subscriptionType: obj["subscriptionType"] as? String ?? ""
        )
    }
}
