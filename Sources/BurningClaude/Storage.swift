import Foundation

/// On-disk locations for this app's own state. Nothing here contains
/// credentials — only usage counts, model names and account identifiers.
enum Storage {
    static let directory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("BurningClaude", isDirectory: true)

        // The app used to be called ClaudeTokenMeter. Carry its state across on
        // first run rather than starting empty: the old directory holds the
        // scan offsets and the delivered-alert record, and losing those means
        // re-reading every transcript and re-announcing limits the user has
        // already been told about. Only ever moved into a directory that does
        // not exist yet, so it cannot clobber newer state.
        let legacy = base.appendingPathComponent("ClaudeTokenMeter", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }

        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var accountsFile: URL { directory.appendingPathComponent("accounts.json") }
    static var eventsFile: URL { directory.appendingPathComponent("events.json") }
    static var scanStateFile: URL { directory.appendingPathComponent("scan-state.json") }

    /// Recorded rate-limit refusals.
    static var limitsFile: URL { directory.appendingPathComponent("limits.json") }

    /// Which threshold alerts have already been delivered, so quitting and
    /// relaunching does not re-announce a limit the user has already been told
    /// about.
    static var alertsFile: URL { directory.appendingPathComponent("alerts.json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Writes atomically so a crash mid-save cannot leave a truncated file that
    /// would silently reset the user's history.
    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
