import Foundation
import AppKit

/// Adds accounts by driving Claude Code's own sign-in rather than asking the
/// user to find a config directory.
///
/// Claude Code stores exactly one logged-in account per config directory, so a
/// second account means a second `CLAUDE_CONFIG_DIR`. This creates that
/// directory and runs `claude auth login` against it in Terminal — Claude
/// performs the OAuth and owns the credentials throughout. This app never sees
/// a token; it only notices that an account has appeared in the new directory.
enum AccountLauncher {

    enum LaunchError: LocalizedError {
        case claudeNotFound
        case directoryFailed(String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "Could not find the `claude` command. Install Claude Code, "
                     + "or sign in manually using the command shown below."
            case .directoryFailed(let path):
                return "Could not create the account directory at \(path)."
            }
        }
    }

    /// Where per-account config directories live. Kept in the home directory
    /// rather than inside Application Support so it is easy to reference from
    /// a shell alias.
    static var accountsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-accounts", isDirectory: true)
    }

    /// Locates the `claude` executable. `NSWorkspace`-launched apps do not
    /// inherit a login shell's PATH, so the usual install locations are checked
    /// directly before falling back to asking a login shell.
    static func claudeExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            home.appendingPathComponent(".bun/bin/claude"),
        ].filter { FileManager.default.isExecutableFile(atPath: $0.path) }

        if let first = candidates.first { return first }
        return whichViaLoginShell()
    }

    private static func whichViaLoginShell() -> URL? {
        guard let path = Shell.loginShell("command -v claude"),
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var isClaudeAvailable: Bool { claudeExecutable() != nil }

    /// A filesystem-safe directory name derived from a user-supplied label.
    static func slug(for label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = label.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
        return cleaned.isEmpty ? "account-\(Int(Date().timeIntervalSince1970))" : cleaned
    }

    /// The command a user runs to work under a given account.
    static func usageCommand(for root: ConfigRoot) -> String {
        "CLAUDE_CONFIG_DIR=\(root.path) claude"
    }

    /// The command to sign in manually, for when `claude` cannot be located.
    static func manualLoginCommand(for root: ConfigRoot) -> String {
        "CLAUDE_CONFIG_DIR=\(root.path) claude auth login"
    }

    /// Creates the config directory for a new account.
    static func prepareRoot(label: String) throws -> ConfigRoot {
        let dir = accountsDirectory.appendingPathComponent(slug(for: label), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Claude Code creates this itself on first run, but making it now
            // means the root reads as valid straight away.
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("projects"), withIntermediateDirectories: true
            )
        } catch {
            throw LaunchError.directoryFailed(dir.path)
        }
        return ConfigRoot(path: dir.path, label: label, isDefault: false)
    }

    /// Opens Terminal and runs `claude auth login` for this config directory.
    ///
    /// A `.command` file is used rather than AppleScript so no Automation
    /// permission prompt is involved — double-clickable scripts open in
    /// Terminal by default.
    static func beginLogin(for root: ConfigRoot) throws {
        guard let claude = claudeExecutable() else { throw LaunchError.claudeNotFound }

        let script = """
        #!/bin/bash
        export CLAUDE_CONFIG_DIR=\(shellQuote(root.path))
        clear
        echo "Burning Claude — adding the account “\(root.label)”"
        echo
        echo "Claude Code will now open your browser to sign in."
        echo "This window belongs to Claude Code; Burning Claude never sees your credentials."
        echo
        \(shellQuote(claude.path)) auth login
        status=$?
        echo
        if [ $status -eq 0 ]; then
          echo "Signed in. Burning Claude will pick up this account within a minute."
          echo
          echo "To work under this account, run Claude like this:"
          echo "    CLAUDE_CONFIG_DIR=\(root.path) claude"
        else
          echo "Sign-in did not complete (exit $status). You can retry this window's command."
        fi
        echo
        echo "You can close this window."
        """

        let url = Storage.directory.appendingPathComponent("login-\(slug(for: root.label)).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
