import Foundation

/// Reads live rate-limit percentages published by a status line.
///
/// Claude Code hands its status line command a JSON payload containing
/// `rate_limits.five_hour.used_percentage` and the seven-day equivalent — the
/// same figures `/usage` reports. It does **not** persist them anywhere, and
/// `cachedUsageUtilization` in `.claude.json` is refreshed so rarely that it is
/// routinely hours out of date and can even belong to a previously signed-in
/// account.
///
/// So the only way to mirror the terminal exactly is to have the status line
/// write that payload out. One line appended to a status line script publishes
/// it here, per config directory — which also makes the account association
/// automatic, since a config directory has exactly one signed-in account.
enum RateLimitBridge {

    static let fileName = ".claudetokenmeter-ratelimits.json"

    /// The line a user adds to their status line script.
    static let snippet = #"""
    printf '%s' "$input" | jq -c '{rate_limits, at: now}' \
      > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claudetokenmeter-ratelimits.json"
    """#

    static func file(for root: ConfigRoot) -> URL {
        URL(fileURLWithPath: root.path).appendingPathComponent(fileName)
    }

    static func isInstalled(for root: ConfigRoot) -> Bool {
        FileManager.default.fileExists(atPath: file(for: root).path)
    }

    /// Parses the published payload into the same shape as Claude's own cache.
    static func read(root: ConfigRoot, accountUUID: String) -> UtilizationSnapshot? {
        guard let data = try? Data(contentsOf: file(for: root)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // `at` is seconds since the epoch, written by jq's `now`.
        let fetchedAt = (obj["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            ?? (try? FileManager.default.attributesOfItem(atPath: file(for: root).path)[.modificationDate] as? Date)
            ?? Date()

        guard let limits = obj["rate_limits"] as? [String: Any] else { return nil }
        let five = parse(limits["five_hour"])
        let seven = parse(limits["seven_day"])
        guard five != nil || seven != nil else { return nil }

        return UtilizationSnapshot(
            accountUUID: accountUUID,
            fetchedAt: fetchedAt,
            fiveHour: five,
            sevenDay: seven
        )
    }

    private static func parse(_ value: Any?) -> UtilizationSnapshot.Limit? {
        guard let dict = value as? [String: Any],
              let percent = (dict["used_percentage"] as? NSNumber)?.doubleValue
        else { return nil }

        // `resets_at` is not guaranteed to be present in the status line
        // payload; without it the percentage still stands, only the countdown
        // is unavailable.
        var resetsAt: Date?
        if let raw = dict["resets_at"] as? String {
            resetsAt = ISO8601.date(from: raw)
        } else if let secs = (dict["resets_at"] as? NSNumber)?.doubleValue {
            resetsAt = Date(timeIntervalSince1970: secs)
        }

        return UtilizationSnapshot.Limit(
            percent: Int(percent.rounded()),
            resetsAt: resetsAt ?? .distantFuture
        )
    }
}
