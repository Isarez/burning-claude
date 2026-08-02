import Foundation

struct ModelUsage: Identifiable {
    var model: String
    var tokens: TokenCounts
    var id: String { model }
    var displayName: String { ModelInfo.displayName(model) }
}

/// Where a gauge's reading came from, and therefore how much it is worth.
enum CalibrationSource {
    /// Anthropic's own figure, straight from Claude Code's cache, for the
    /// account currently signed in. Matches what `/usage` shows.
    case official(fetchedAt: Date)
    /// Anthropic's own figure, fetched from claude.ai on this refresh. Same
    /// number as `.official`, but never stale — it is not waiting on Claude
    /// Code to run before it updates.
    case live(fetchedAt: Date)
    /// A figure exists but describes a window that has since closed, so it no
    /// longer says anything about current usage.
    case expired(fetchedAt: Date)
    /// No usable figure for this account.
    case none

    var isOfficial: Bool {
        switch self {
        case .official, .live: return true
        case .expired, .none:  return false
        }
    }

    /// Only an in-window official figure is worth rendering as a percentage.
    var isTrusted: Bool { isOfficial }

    var label: String {
        switch self {
        case .official(let at): return "from Claude · \(Fmt.relative(at))"
        case .live(let at):     return "from claude.ai · \(Fmt.relative(at))"
        case .expired:          return "expired — run /usage in Claude Code"
        case .none:             return "run /usage in Claude Code to report usage"
        }
    }
}

/// One usage limit, expressed as a fraction of its ceiling.
///
/// The fraction is Anthropic's own figure wherever possible — Claude Code
/// caches it, and it is exactly what `/usage` reports in the terminal. That
/// cache only refreshes when Claude Code runs, so once it lapses the gauge
/// reports nothing rather than guessing.
struct Gauge {
    /// 0...1, and above 1 when a limit is being exceeded. Zero when there is
    /// nothing trustworthy to report.
    var fraction: Double = 0
    var resetAt: Date?
    var source: CalibrationSource = .none

    var percent: Int { Int((fraction * 100).rounded()) }

    /// Bar fill never overflows its track even when a limit is exceeded.
    var barFraction: Double { min(max(fraction, 0), 1) }

    /// False when the gauge has nothing to show and should render as a dash.
    var isCalibrated: Bool { source.isTrusted }

    var level: UsageLevel { UsageLevel(fraction: fraction) }
}

enum Aggregator {

    static let weekDuration: TimeInterval = 7 * 24 * 60 * 60

    /// Token totals per model over the events at or after `date`, largest
    /// first. Drives the share bar under each account in the panel.
    static func modelBreakdown(_ events: [UsageEvent], since date: Date) -> [ModelUsage] {
        var perModel: [String: TokenCounts] = [:]
        for e in events where e.timestamp >= date {
            perModel[e.model, default: TokenCounts()] += e.tokens
        }
        return perModel
            .map { ModelUsage(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens.total > $1.tokens.total }
    }

    /// Builds a gauge for one limit from Anthropic's own figure.
    ///
    /// Deliberately does *not* fall back to counting local tokens. Transcripts
    /// only cover Claude Code usage under the config directories this app
    /// tracks, while these limits are account-wide and also consume from
    /// claude.ai, the desktop and mobile apps, and other machines. Measured
    /// against known-correct values, a local count came to roughly a third of
    /// real usage — close enough to look plausible and be badly wrong. When
    /// there is no current official figure the gauge reports nothing.
    /// - Parameter live: true when the snapshot was just fetched from
    ///   claude.ai rather than read out of Claude Code's cache. Only affects
    ///   how the reading is labelled; the arithmetic is identical.
    static func gauge(
        kind: LimitKind,
        snapshot: UtilizationSnapshot?,
        now: Date = Date(),
        live: Bool = false
    ) -> Gauge {
        var gauge = Gauge()
        guard let snapshot, let official = snapshot.limit(for: kind) else { return gauge }

        if official.isCurrent(now: now) {
            gauge.fraction = Double(official.percent) / 100
            gauge.resetAt = official.hasResetInstant ? official.resetsAt : nil
            gauge.source = live
                ? .live(fetchedAt: snapshot.fetchedAt)
                : .official(fetchedAt: snapshot.fetchedAt)
            return gauge
        }

        // The window has closed. A weekly limit runs on a fixed cycle so the
        // next boundary is still worth showing; a session window is anchored to
        // when use resumes and cannot be projected.
        if kind == .weekly {
            var end = official.resetsAt
            while end <= now { end.addTimeInterval(weekDuration) }
            gauge.resetAt = end
        }
        gauge.source = .expired(fetchedAt: snapshot.fetchedAt)
        return gauge
    }
}

// MARK: - Formatting

enum Fmt {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    // Built once. These are read on every panel redraw and every tooltip
    // rebuild, and a `DateFormatter` is expensive enough to be worth keeping.
    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayAndTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    private static let dateAndTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    /// Absolute reset instant, e.g. "today 18:00" or "Tue 09:00".
    static func resetAt(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current

        if cal.isDate(date, inSameDayAs: now) {
            return "today \(timeOnly.string(from: date))"
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(timeOnly.string(from: date))"
        }

        // Inside a week the weekday alone locates it; beyond that it does not.
        let days = cal.dateComponents([.day], from: now, to: date).day ?? 0
        return days < 7
            ? weekdayAndTime.string(from: date)
            : dateAndTime.string(from: date)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let d = now.timeIntervalSince(date)
        if d < 60 { return "just now" }
        if d < 3600 { return "\(Int(d / 60))m ago" }
        if d < 86_400 { return "\(Int(d / 3600))h ago" }
        return "\(Int(d / 86_400))d ago"
    }
}
