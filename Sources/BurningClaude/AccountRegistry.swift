import Foundation

/// Tracks which Claude account is logged in to each config root, and keeps a
/// history of that so past usage can be attributed to the right account.
///
/// This exists because transcripts carry no account identity at all, and
/// `.claude.json` records only the account logged in *right now*. The only way
/// to attribute history in a shared config directory is to record who was
/// logged in each time we look, and match transcript timestamps against those
/// windows. Usage that predates the app's first run is attributed to the
/// earliest account we ever saw and flagged as inferred.
final class AccountRegistry {

    struct Persisted: Codable {
        var accounts: [String: Account] = [:]
        var observations: [AccountObservation] = []
    }

    private var state: Persisted

    /// If the config file has not changed in this long, still refresh the
    /// observation window so a continuously-running session stays covered.
    private static let observationGap: TimeInterval = 60 * 60  // 1 hour

    init() {
        state = Storage.load(Persisted.self, from: Storage.accountsFile) ?? Persisted()
    }

    var allAccounts: [Account] {
        state.accounts.values.sorted { $0.email < $1.email }
    }

    /// The account currently logged in to a root, if we have ever seen one.
    func currentAccount(forRoot rootID: String) -> Account? {
        let latest = state.observations
            .filter { $0.rootID == rootID }
            .max(by: { $0.lastSeen < $1.lastSeen })
        return latest.flatMap { state.accounts[$0.accountUUID] }
    }

    /// Read each root's `.claude.json` and record who is logged in right now.
    /// Call this on every refresh — it is how the timeline gets built.
    @discardableResult
    func observe(roots: [ConfigRoot], now: Date = Date()) -> Bool {
        var changed = false
        for root in roots {
            guard let account = readAccount(from: root) else { continue }
            if state.accounts[account.uuid] != account {
                state.accounts[account.uuid] = account
                changed = true
            }
            if extendObservation(rootID: root.id, accountUUID: account.uuid, now: now) {
                changed = true
            }
        }
        if changed { save() }
        return changed
    }

    /// Extends the most recent observation window for this root when the same
    /// account is still logged in, otherwise opens a new window.
    private func extendObservation(rootID: String, accountUUID: String, now: Date) -> Bool {
        let idx = state.observations.lastIndex {
            $0.rootID == rootID && $0.accountUUID == accountUUID
        }
        // Only extend if this is genuinely the newest window for the root;
        // otherwise the user switched away and back, which is a new window.
        let newestForRoot = state.observations
            .filter { $0.rootID == rootID }
            .max(by: { $0.lastSeen < $1.lastSeen })

        if let idx, let newest = newestForRoot, newest.accountUUID == accountUUID {
            if now.timeIntervalSince(state.observations[idx].lastSeen) < 1 { return false }
            state.observations[idx].lastSeen = max(state.observations[idx].lastSeen, now)
            return true
        }

        state.observations.append(
            AccountObservation(rootID: rootID, accountUUID: accountUUID, firstSeen: now, lastSeen: now)
        )
        return true
    }

    /// Attribute a timestamp to an account. `inferred` is true when the answer
    /// is a best guess rather than something we actually observed.
    func attribute(rootID: String, at date: Date) -> (uuid: String, inferred: Bool) {
        let obs = state.observations
            .filter { $0.rootID == rootID }
            .sorted { $0.firstSeen < $1.firstSeen }
        guard let first = obs.first, let last = obs.last else {
            return (Account.unknown.uuid, true)
        }

        if date < first.firstSeen {
            // Predates tracking: assume the earliest account we ever saw.
            return (first.accountUUID, true)
        }
        if date > last.lastSeen {
            // After our last look: the current account is still logged in.
            return (last.accountUUID, false)
        }
        for o in obs where date >= o.firstSeen && date <= o.lastSeen {
            return (o.accountUUID, false)
        }
        // Falls in a gap between two windows — attribute to the window that
        // was open before the gap, but mark it inferred.
        let before = obs.last { $0.lastSeen < date }
        return (before?.accountUUID ?? first.accountUUID, true)
    }

    /// Determines which account a config root is signed in as.
    ///
    /// `claude auth status` is authoritative because it reads the live
    /// credential; the `oauthAccount` block is only used to enrich that with
    /// the account UUID, and only when the two agree on the email. When they
    /// disagree the block is stale from a previous account and its UUID must
    /// not be attached to the current one.
    private func readAccount(from root: ConfigRoot) -> Account? {
        let stored = readStoredAccount(from: root)

        guard let claude = AccountLauncher.claudeExecutable(),
              let live = AuthStatusReader.read(root: root, claude: claude)
        else { return stored }

        if let stored, stored.email.caseInsensitiveCompare(live.email) == .orderedSame {
            return stored
        }

        // Signed in as someone the config file has not caught up with. Identify
        // the account by organisation, which `auth status` does report.
        return Account(
            uuid: "org:\(live.organizationID)",
            email: live.email,
            displayName: live.email,
            organizationName: live.organizationName,
            organizationUUID: live.organizationID,
            billingType: live.subscriptionType,
            rateLimitTier: ""
        )
    }

    /// Parses the `oauthAccount` block, which may describe a stale account.
    private func readStoredAccount(from root: ConfigRoot) -> Account? {
        for url in root.configJSONCandidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = obj["oauthAccount"] as? [String: Any],
                  let uuid = oauth["accountUuid"] as? String
            else { continue }

            func str(_ key: String) -> String { oauth[key] as? String ?? "" }
            return Account(
                uuid: uuid,
                email: str("emailAddress"),
                displayName: str("displayName"),
                organizationName: str("organizationName"),
                organizationUUID: str("organizationUuid"),
                billingType: str("billingType"),
                rateLimitTier: str("organizationRateLimitTier")
            )
        }
        return nil
    }

    /// Forgets observations for config roots that are no longer tracked, and
    /// any account left with no observations at all.
    func prune(keeping activeRoots: Set<String>) {
        let before = state.observations.count
        state.observations.removeAll { !activeRoots.contains($0.rootID) }
        guard state.observations.count != before else { return }

        let stillSeen = Set(state.observations.map(\.accountUUID))
        state.accounts = state.accounts.filter { stillSeen.contains($0.key) }
        save()
    }

    private func save() { Storage.save(state, to: Storage.accountsFile) }
}
