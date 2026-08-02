import Foundation

/// Anthropic's own usage figures, as cached by Claude Code.
///
/// Claude Code stores the response of its usage endpoint in `.claude.json`
/// under `cachedUsageUtilization`. These are *the* numbers shown by `/usage`
/// in the terminal, so anything this app derives locally should defer to them.
///
/// The catch is freshness: the cache is only rewritten when Claude Code runs,
/// so between sessions it goes stale and its five-hour window can lapse
/// entirely. `resets_at` makes that detectable, and also pins the exact window
/// bounds — which a locally reconstructed window gets wrong.
///
/// `ClaudeWebClient` produces the same type from claude.ai's usage endpoint,
/// which reports the identical figures without the staleness. Everything
/// downstream of here is therefore indifferent to which source a reading came
/// from; only the badge in the panel distinguishes them.
struct UtilizationSnapshot: Codable, Sendable {
    struct Limit: Codable, Sendable {
        var percent: Int
        var resetsAt: Date

        func isCurrent(now: Date) -> Bool { resetsAt > now }

        /// True when no reset instant was published alongside the percentage.
        var hasResetInstant: Bool { resetsAt != .distantFuture }
    }

    var accountUUID: String
    var fetchedAt: Date
    var fiveHour: Limit?
    var sevenDay: Limit?

    func limit(for kind: LimitKind) -> Limit? {
        kind == .session ? fiveHour : sevenDay
    }
}

enum UtilizationReader {

    /// Reads `cachedUsageUtilization` from a config root, if present.
    ///
    /// Older Claude Code versions and freshly created config directories have
    /// no cache at all, which is reported as `nil` rather than zero — an
    /// absent figure must not read as "0% used".
    static func read(root: ConfigRoot) -> UtilizationSnapshot? {
        for url in root.configJSONCandidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cached = obj["cachedUsageUtilization"] as? [String: Any],
                  let accountUUID = cached["accountUuid"] as? String,
                  let fetchedMs = (cached["fetchedAtMs"] as? NSNumber)?.doubleValue,
                  let utilization = cached["utilization"] as? [String: Any]
            else { continue }

            return UtilizationSnapshot(
                accountUUID: accountUUID,
                fetchedAt: Date(timeIntervalSince1970: fetchedMs / 1000),
                fiveHour: parse(utilization["five_hour"]),
                sevenDay: parse(utilization["seven_day"])
            )
        }
        return nil
    }

    private static func parse(_ value: Any?) -> UtilizationSnapshot.Limit? {
        guard let dict = value as? [String: Any],
              let percent = (dict["utilization"] as? NSNumber)?.intValue,
              let resetsRaw = dict["resets_at"] as? String,
              let resetsAt = ISO8601.date(from: resetsRaw)
        else { return nil }
        return UtilizationSnapshot.Limit(percent: percent, resetsAt: resetsAt)
    }
}
