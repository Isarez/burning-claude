import Foundation

/// Finds the Claude Code config directories that exist on this machine, so
/// Settings can *offer* them.
///
/// It does not decide what to track. Tracking something the user did not ask
/// for is the worse failure of the two: a directory they never use reports an
/// idle account's figures in the menu bar, which looks merely wrong rather than
/// misconfigured. An unoffered directory, by contrast, is one click away.
enum ConfigDiscovery {

    /// Every directory that looks like a Claude Code config root. Suggestions
    /// only — see `Preferences.trackedRoots` for what is actually read.
    static func discover() -> [ConfigRoot] {
        var found: [String: ConfigRoot] = [:]

        func add(_ path: String, label: String, isDefault: Bool = false) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let resolved = url.resolvingSymlinksInPath().path
            // No exemption for `~/.claude`: an empty or absent default
            // directory is not worth offering either.
            guard looksLikeConfigRoot(resolved) else { return }
            guard found[resolved] == nil else { return }
            found[resolved] = ConfigRoot(path: resolved, label: label, isDefault: isDefault)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        add(ConfigRoot.defaultRoot.path, label: ConfigRoot.defaultRoot.label, isDefault: true)

        // The directory the user's shell actually points Claude Code at.
        if let fromShell = configDirFromLoginShell() {
            add(fromShell, label: URL(fileURLWithPath: fromShell).lastPathComponent)
        }
        if let fromEnv = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !fromEnv.isEmpty {
            add(fromEnv, label: URL(fileURLWithPath: fromEnv).lastPathComponent)
        }

        // Conventional siblings: `~/.claude-work`, and anything created by this
        // app under `~/.claude-accounts/`.
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: home.path) {
            for name in entries where name.hasPrefix(".claude-") && name != ".claude-accounts" {
                add(home.appendingPathComponent(name).path, label: name)
            }
        }
        if let entries = try? fm.contentsOfDirectory(atPath: AccountLauncher.accountsDirectory.path) {
            for name in entries {
                add(AccountLauncher.accountsDirectory.appendingPathComponent(name).path, label: name)
            }
        }

        return found.values.sorted { ($0.isDefault ? 0 : 1, $0.path) < ($1.isDefault ? 0 : 1, $1.path) }
    }

    /// A directory qualifies if it holds Claude Code's own state, so unrelated
    /// dotfolders are not swept in.
    private static func looksLikeConfigRoot(_ path: String) -> Bool {
        let dir = URL(fileURLWithPath: path)
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("projects").path)
            || fm.fileExists(atPath: dir.appendingPathComponent(".claude.json").path)
    }

    /// `CLAUDE_CONFIG_DIR` is typically exported from a shell profile, which a
    /// GUI app does not inherit — so ask a login shell for it.
    private static func configDirFromLoginShell() -> String? {
        guard let path = Shell.loginShell("printf %s \"$CLAUDE_CONFIG_DIR\"") else { return nil }
        return NSString(string: path).expandingTildeInPath
    }
}
