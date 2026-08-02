import Foundation

/// Recognises Claude Code's rate-limit refusals and the reset time they carry.
///
/// The transcript line looks like:
///
///     You've hit your session limit · resets 2:40am (Asia/Bangkok)
///     You've hit your weekly limit · resets 12am (Asia/Bangkok)
///
/// The announced time is a wall-clock time in the named zone with no date, so
/// it is resolved to the next occurrence at or after the moment it was hit.
enum LimitParser {

    private static let regex = try! NSRegularExpression(
        pattern: #"hit your (session|weekly) limit.*?resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    static func parse(text: String, hitAt: Date, rootID: String) -> LimitEvent? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }

        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r])
        }

        guard let kindRaw = group(1)?.lowercased(),
              let kind = LimitKind(rawValue: kindRaw),
              let hourRaw = group(2), var hour = Int(hourRaw),
              let meridiem = group(4)?.lowercased(),
              let zoneName = group(5),
              let zone = TimeZone(identifier: zoneName)
        else { return nil }

        let minute = Int(group(3) ?? "0") ?? 0

        // 12am is hour 0 and 12pm is hour 12; everything else shifts by 12 in
        // the afternoon.
        if meridiem == "am" && hour == 12 { hour = 0 }
        if meridiem == "pm" && hour != 12 { hour += 12 }

        guard let resetAt = nextOccurrence(hour: hour, minute: minute, after: hitAt, in: zone) else {
            return nil
        }
        return LimitEvent(kind: kind, timestamp: hitAt, resetAt: resetAt, rootID: rootID)
    }

    /// The first instant at or after `date` whose wall clock in `zone` reads
    /// `hour:minute`.
    private static func nextOccurrence(hour: Int, minute: Int, after date: Date, in zone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone

        var comps = cal.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard let sameDay = cal.date(from: comps) else { return nil }

        if sameDay > date { return sameDay }
        return cal.date(byAdding: .day, value: 1, to: sameDay)
    }
}
