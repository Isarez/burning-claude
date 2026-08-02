import Foundation

/// Parses the ISO-8601 timestamps Claude Code and claude.ai emit.
///
/// Both spellings occur in practice — `…T03:04:05.678Z` from the API and
/// `…T03:04:05Z` from older transcripts — and an `ISO8601DateFormatter` accepts
/// only the one it was configured for, so each is tried in turn.
///
/// Shared rather than per-call: constructing a formatter is expensive and this
/// runs once per transcript line. The instances are only ever read from, which
/// is the condition under which Foundation's formatters are safe to use from
/// several threads at once — and the transcript scan and the claude.ai fetch do
/// run concurrently.
enum ISO8601 {

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain = ISO8601DateFormatter()

    static func date(from raw: String) -> Date? {
        fractional.date(from: raw) ?? plain.date(from: raw)
    }
}
