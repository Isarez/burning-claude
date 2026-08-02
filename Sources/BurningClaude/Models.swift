import Foundation

/// The five token counters Claude Code records per assistant message.
struct TokenCounts: Codable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheWrite5m: Int = 0
    var cacheWrite1h: Int = 0
    var cacheRead: Int = 0

    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
            cacheRead: a.cacheRead + b.cacheRead
        )
    }

    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

/// One deduplicated assistant response, attributed to an account.
struct UsageEvent: Codable {
    var timestamp: Date
    var model: String
    var accountUUID: String
    var rootID: String
    var tokens: TokenCounts
    /// True when the event predates the first time this app observed which
    /// account was logged in, so attribution is inferred rather than recorded.
    var inferredAccount: Bool
    /// `usage.speed == "fast"` — fast mode is billed at a premium rate.
    var fast: Bool

    private enum CodingKeys: String, CodingKey {
        case timestamp = "t", model = "m", accountUUID = "a"
        case rootID = "r", tokens = "k", inferredAccount = "i", fast = "f"
    }

    init(timestamp: Date, model: String, accountUUID: String, rootID: String,
         tokens: TokenCounts, inferredAccount: Bool, fast: Bool) {
        self.timestamp = timestamp
        self.model = model
        self.accountUUID = accountUUID
        self.rootID = rootID
        self.tokens = tokens
        self.inferredAccount = inferredAccount
        self.fast = fast
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        model = try c.decode(String.self, forKey: .model)
        accountUUID = try c.decode(String.self, forKey: .accountUUID)
        rootID = try c.decode(String.self, forKey: .rootID)
        tokens = try c.decode(TokenCounts.self, forKey: .tokens)
        inferredAccount = try c.decodeIfPresent(Bool.self, forKey: .inferredAccount) ?? false
        fast = try c.decodeIfPresent(Bool.self, forKey: .fast) ?? false
    }
}

/// Which of the two limits a figure describes.
///
/// Its own type rather than a member of `LimitEvent`: every gauge, snapshot and
/// panel row is addressed by it, none of which has anything to do with the
/// refusal events that happen to share the vocabulary.
enum LimitKind: String, Codable {
    case session   // the 5-hour limit
    case weekly    // the 7-day limit
}

/// A moment when Claude actually refused a request because a plan limit was
/// reached. Claude Code writes these into the transcript as a 429 entry, e.g.
/// `You've hit your session limit · resets 2:40am (Asia/Bangkok)`.
///
/// These are the only ground truth available locally about where the limits
/// actually sit. Nothing reads them back yet — the gauges take Anthropic's own
/// percentages instead — but they are recorded because they cannot be
/// recovered after the fact: a transcript that has rolled over is gone.
struct LimitEvent: Codable {
    var kind: LimitKind
    /// When the limit was hit.
    var timestamp: Date
    /// The reset instant Claude announced.
    var resetAt: Date
    var rootID: String

    private enum CodingKeys: String, CodingKey {
        case kind = "k", timestamp = "t", resetAt = "r", rootID = "d"
    }
}

/// An OAuth account as recorded in a config directory's `.claude.json`.
struct Account: Codable, Identifiable, Hashable {
    var uuid: String
    var email: String
    var displayName: String
    var organizationName: String
    var organizationUUID: String
    var billingType: String
    var rateLimitTier: String

    var id: String { uuid }

    /// Short label for menus. Prefers the email local part, which is what
    /// distinguishes accounts in practice.
    var shortLabel: String {
        if let at = email.firstIndex(of: "@") { return String(email[..<at]) }
        return displayName.isEmpty ? String(uuid.prefix(8)) : displayName
    }

    static let unknown = Account(
        uuid: "unknown", email: "(unknown account)", displayName: "Unknown",
        organizationName: "", organizationUUID: "", billingType: "", rateLimitTier: ""
    )
}

/// A Claude Code configuration directory: one `projects/` tree plus the
/// `.claude.json` that names the account currently logged in to it.
struct ConfigRoot: Codable, Identifiable, Hashable {
    /// Path to the config directory (the one containing `projects/`).
    var path: String
    /// User-facing name; defaults to the directory name.
    var label: String
    /// True for the built-in `~/.claude` root, which cannot be removed.
    var isDefault: Bool

    var id: String { path }

    var projectsURL: URL { URL(fileURLWithPath: path).appendingPathComponent("projects") }

    /// Candidate locations of the `.claude.json` that names the logged-in
    /// account, in priority order.
    ///
    /// With `CLAUDE_CONFIG_DIR` the file lives *inside* the directory; the
    /// default install keeps it as a *sibling* (`~/.claude/` pairs with
    /// `~/.claude.json`). Both can exist at once — a stub inside plus the real
    /// one outside — so existence is not enough to choose between them. The
    /// caller picks the first candidate that actually parses to an account.
    var configJSONCandidates: [URL] {
        let dir = URL(fileURLWithPath: path)
        let inside = dir.appendingPathComponent(".claude.json")
        let sibling = dir.deletingLastPathComponent()
            .appendingPathComponent("\(dir.lastPathComponent).json")
        return [inside, sibling].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var defaultRoot: ConfigRoot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ConfigRoot(
            path: home.appendingPathComponent(".claude").path,
            label: "Default (~/.claude)",
            isDefault: true
        )
    }
}

/// A window during which a given account was observed logged in to a root.
struct AccountObservation: Codable {
    var rootID: String
    var accountUUID: String
    var firstSeen: Date
    var lastSeen: Date
}
