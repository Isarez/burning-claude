import Foundation

/// Runs the short-lived commands this app shells out to: locating `claude`,
/// asking it who is signed in, and reading environment a GUI app cannot see.
enum Shell {

    /// Runs a command and returns what it wrote to standard output, or nil if
    /// it could not be started or exited non-zero.
    ///
    /// Output is drained *before* waiting on the process. Waiting first
    /// deadlocks the moment a command writes more than the pipe buffer holds —
    /// a failure that stays invisible until output grows past 64K.
    static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String]? = nil
    ) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let out = Pipe()
        process.standardOutput = out
        // Shell profiles are chatty, and none of it is ours to report.
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    /// Runs a command through the user's login shell, returning its trimmed
    /// output — nil when there was none.
    ///
    /// A GUI app inherits nothing from a shell profile, so whatever the user
    /// set up in `.zshrc` — their `PATH`, their `CLAUDE_CONFIG_DIR` — can only
    /// be reached by asking the shell itself.
    static func loginShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let data = run(URL(fileURLWithPath: shell), ["-lc", command]),
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }
}
