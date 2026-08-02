import Foundation

/// A claude.ai browser session cookie, validated for shape only.
///
/// Whether the key actually works is not something a regex can answer, so the
/// sign-in flow confirms it against the API before anything is stored. This
/// type exists to keep an unvalidated `String` from being passed around as if
/// it were a credential, and to accept the two forms people actually paste:
/// the bare value, or a whole `Cookie:` header copied out of DevTools.
struct SessionKey: Equatable, Sendable {

    enum Invalid: LocalizedError {
        case empty
        case notASessionKey
        case tooShort

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Paste the session key first."
            case .notASessionKey:
                return "That does not look like a session key. It starts with "
                     + "`sk-ant-` — copy the value of the `sessionKey` cookie "
                     + "for claude.ai, not the whole cookie list."
            case .tooShort:
                return "That session key is truncated. Copy the whole value; "
                     + "it is well over a hundred characters."
            }
        }
    }

    let value: String

    init(_ raw: String) throws {
        // An empty field and a field full of the wrong thing are different
        // mistakes, and telling them apart is the whole value of the message.
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Invalid.empty
        }
        guard let extracted = Self.extract(from: raw) else { throw Invalid.notASessionKey }
        guard extracted.hasPrefix("sk-ant-") else { throw Invalid.notASessionKey }
        guard extracted.count > 32 else { throw Invalid.tooShort }
        value = extracted
    }

    /// Pulls the key out of whatever was pasted. DevTools' "Copy value" gives
    /// the bare key; copying the request header gives `sessionKey=…; other=…`;
    /// copying out of a code snippet or a `document.cookie` dump can wrap the
    /// value in quotes.
    static func extract(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("sk-ant-") { return trimmed }

        let pattern = #"(?i)(?:^|[;\s])sessionKey\s*=\s*['"]?([^;\s'"]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: trimmed)
        else { return nil }
        return String(trimmed[captured])
    }

    /// Safe to show in the UI: enough to tell two keys apart, not enough to use.
    var redacted: String {
        guard value.count > 20 else { return "sk-ant-…" }
        return "\(value.prefix(14))…\(value.suffix(4))"
    }
}

/// An account whose figures come from claude.ai rather than from a Claude Code
/// config directory.
///
/// Identified by organisation UUID, because that is what the usage endpoint is
/// addressed by and what stays stable when the session key is rotated. The key
/// itself is not in here — it lives in the keychain under `keychainAccount`.
struct SessionAccount: Codable, Identifiable, Hashable, Sendable {
    var organizationUUID: String
    var organizationName: String
    /// Email where claude.ai would tell us, otherwise the organisation name.
    var label: String
    var addedAt: Date

    var id: String { organizationUUID }

    /// Namespaced so it can never collide with an `accountUuid` read out of a
    /// `.claude.json`, which would merge two unrelated accounts into one row.
    var accountUUID: String { "session:\(organizationUUID)" }

    var keychainAccount: String { "session:\(organizationUUID)" }

    /// The `Account` shown in the panel and the menu bar.
    var asAccount: Account {
        Account(
            uuid: accountUUID,
            email: label,
            displayName: label,
            organizationName: organizationName,
            organizationUUID: organizationUUID,
            billingType: "",
            rateLimitTier: ""
        )
    }
}
