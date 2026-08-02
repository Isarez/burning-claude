import SwiftUI
import AppKit

/// How close a reading has come to its ceiling, under the user's own
/// thresholds.
///
/// One definition, because three parts of the app act on the same judgement:
/// the menu bar tints its bars and flame, the panel tints its gauges, and the
/// notifier decides whether a crossing is worth announcing. They have to agree.
/// A bar sitting red beside a notification that never fired reads as a bug, and
/// keeping the comparison in three places is how that happens.
enum UsageLevel: Int, Comparable, Codable {
    case normal = 0
    case warn = 1
    case critical = 2

    init(fraction: Double) {
        let prefs = Preferences.shared
        if fraction >= prefs.criticalThreshold {
            self = .critical
        } else if fraction >= prefs.warnThreshold {
            self = .warn
        } else {
            self = .normal
        }
    }

    static func < (a: UsageLevel, b: UsageLevel) -> Bool { a.rawValue < b.rawValue }

    /// Word for the headline of a notification covering several crossings.
    var severity: String {
        switch self {
        case .critical: return "critical"
        case .warn:     return "warning"
        case .normal:   return "normal"
        }
    }

    /// Panel gauges.
    var color: Color {
        switch self {
        case .critical: return .red
        case .warn:     return .orange
        case .normal:   return .green
        }
    }

    /// Menu bar, which draws in AppKit so the system appearance applies.
    var nsColor: NSColor {
        switch self {
        case .critical: return .systemRed
        case .warn:     return .systemOrange
        case .normal:   return .systemGreen
        }
    }
}
