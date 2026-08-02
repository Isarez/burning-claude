import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    /// Set when the panel's "Sign in" prompt opened this window, so the user
    /// lands on the sign-in form rather than having to find it again.
    var presentSessionKeySheet: Bool = false
    var onDone: () -> Void

    private let prefs = Preferences.shared

    @State private var refreshInterval: Double = Preferences.shared.refreshInterval
    @State private var notifyEnabled: Bool = Preferences.shared.notifyEnabled
    @State private var warn: Double = Preferences.shared.warnThreshold * 100
    @State private var critical: Double = Preferences.shared.criticalThreshold * 100
    @State private var trackedRoots: [ConfigRoot] = Preferences.shared.trackedRoots
    @State private var barLength: Double = Preferences.shared.barLength
    @State private var isRescanning = false
    @State private var isTestingNotification = false
    /// Outcome of the last test notification: "Sent." or why it could not be.
    @State private var testResult: String?
    @State private var testFailed = false
    @State private var showAddAccount = false
    @State private var newAccountLabel = ""
    @State private var loginError: String?
    @State private var sessionAccounts: [SessionAccount] = Preferences.shared.sessionAccounts
    @State private var showSessionKeySheet = false
    /// `onAppear` can fire more than once for the same view. Without this,
    /// dismissing the sign-in form would spring it straight back open and there
    /// would be no way out of Settings.
    @State private var didAutoPresent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    menuBarSection
                    Divider()
                    thresholdSection
                    Divider()
                    refreshSection
                    Divider()
                    rootsSection
                    // Only meaningful for config directories; a session-key-only
                    // setup has no status line to publish from.
                    if !trackedRoots.isEmpty {
                        Divider()
                        bridgeSection
                    }
                    Divider()
                    dataSection
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { apply(); onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 440, minHeight: 520)
        .onAppear {
            guard presentSessionKeySheet, !didAutoPresent else { return }
            didAutoPresent = true
            showSessionKeySheet = true
        }
    }

    // MARK: - Sections

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MENU BAR").sectionHeader()
            HStack {
                Text("Meter length").frame(width: 84, alignment: .leading)
                Slider(value: $barLength, in: 8...80, step: 2)
                Text("\(Int(barLength))pt").monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            Text("Each signed-in account gets its own pair of bars — 5-hour on top, "
                 + "7-day below. Longer bars are easier to read; shorter ones take "
                 + "less room when several accounts are shown.")
                .helpText()
        }
    }

    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THRESHOLDS").sectionHeader()
            Text("Percentages are Anthropic's own, read from the usage figures "
                 + "Claude Code caches — the same numbers /usage shows in the "
                 + "terminal. They refresh whenever Claude Code runs; in between, "
                 + "the gauge is carried forward locally.")
                .helpText()

            HStack {
                Text("Warn at").frame(width: 74, alignment: .leading)
                Slider(value: $warn, in: 20...95, step: 5)
                Text("\(Int(warn))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("Critical at").frame(width: 74, alignment: .leading)
                Slider(value: $critical, in: 30...100, step: 5)
                Text("\(Int(critical))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                    .foregroundStyle(.red)
            }
            Text("Bars turn amber and red at these points, in the menu bar and the panel.")
                .helpText()

            Toggle("Send a notification when a threshold is crossed", isOn: $notifyEnabled)
            Text("Once per threshold, per window — crossing warn notifies once and "
                 + "crossing critical notifies once, then nothing more until the "
                 + "limit resets.")
                .helpText()

            HStack(spacing: 8) {
                Button("Test Notification") {
                    testResult = nil
                    isTestingNotification = true
                    Task {
                        let failure = await Notifier.test()
                        isTestingNotification = false
                        // Focus modes still hide banners, and nothing the app
                        // can do reveals that, so the success line points at
                        // the one place the notification is certain to be.
                        testResult = failure
                            ?? "Sent. If no banner appeared, check Notification Centre — Focus hides them."
                        testFailed = failure != nil
                    }
                }
                .disabled(isTestingNotification)

                if let testResult {
                    Text(testResult)
                        .font(.system(size: 11))
                        .foregroundStyle(testFailed ? Color.orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: warn) { _, v in if critical < v { critical = v } }
        .onChange(of: critical) { _, v in if warn > v { warn = v } }
    }

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("REFRESH").sectionHeader()
            Picker("Refresh every", selection: $refreshInterval) {
                Text("1 minute").tag(60.0)
                Text("5 minutes").tag(300.0)
                Text("10 minutes").tag(600.0)
            }
            Text("Also refreshes each time the panel is opened. The interval sets "
                 + "how precisely an account switch can be pinned down.")
                .helpText()
        }
    }

    private var rootsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACCOUNTS").sectionHeader()
            Text("Two ways to track an account. A config directory is read from "
                 + "disk and reports whatever Claude Code last cached. A session "
                 + "key is fetched from claude.ai on every refresh, so it is never "
                 + "stale — including for usage from the web and mobile apps, "
                 + "which never touches this machine.")
                .helpText()

            if trackedRoots.isEmpty && sessionAccounts.isEmpty {
                Label("No accounts yet — sign in to start tracking one.",
                      systemImage: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(trackedRoots) { root in
                        accountRow(root)
                    }
                    ForEach(sessionAccounts) { account in
                        sessionAccountRow(account)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    showSessionKeySheet = true
                } label: {
                    Label("Sign in with session key…", systemImage: "key")
                }
                Button {
                    showAddAccount = true
                    newAccountLabel = ""
                    loginError = nil
                } label: {
                    Label("Add config directory…", systemImage: "person.badge.plus")
                }
            }

            if !AccountLauncher.isClaudeAvailable {
                Label("`claude` not found — config-directory sign-in must be run by hand",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            if let loginError {
                Text(loginError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            suggestionsSection
        }
        .sheet(isPresented: $showAddAccount) { addAccountSheet }
        .sheet(isPresented: $showSessionKeySheet) {
            SessionKeySheet(
                store: store,
                onSignedIn: {
                    sessionAccounts = Preferences.shared.sessionAccounts
                    showSessionKeySheet = false
                },
                onCancel: { showSessionKeySheet = false }
            )
        }
    }

    /// Config directories that exist on this Mac but are not tracked. Offered,
    /// never adopted — `~/.claude` included, which is the whole point.
    private var suggestedRoots: [ConfigRoot] {
        let tracked = Set(trackedRoots.map(\.path))
        return ConfigDiscovery.discover().filter { !tracked.contains($0.path) }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        let suggestions = suggestedRoots
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("FOUND ON THIS MAC").sectionHeader()
                Text("Not tracked. Add one to read its transcripts and whatever "
                     + "usage figures Claude Code last cached there.")
                    .helpText()
                ForEach(suggestions) { root in
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(root.path)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button {
                            trackedRoots.append(root)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Track this config directory")
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func accountRow(_ root: ConfigRoot) -> some View {
        let exists = FileManager.default.fileExists(atPath: root.projectsURL.path)
        let account = store.account(forRoot: root.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: account != nil ? "checkmark.circle.fill"
                      : (exists ? "clock" : "exclamationmark.triangle.fill"))
                    .font(.system(size: 10))
                    .foregroundStyle(account != nil ? Color.green : (exists ? Color.secondary : Color.orange))
                VStack(alignment: .leading, spacing: 1) {
                    Text(account?.email ?? root.label)
                        .font(.system(size: 11, weight: .medium))
                    Text(account == nil ? "waiting for sign-in — \(root.path)" : root.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                // Every row can go, `~/.claude` included. The directory and its
                // credentials are untouched; it simply drops back to being a
                // suggestion under FOUND ON THIS MAC.
                Button {
                    trackedRoots.removeAll { $0.path == root.path }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(root.isDefault
                      ? "Stop tracking ~/.claude (the directory is left alone)"
                      : "Stop tracking this account (the directory is left alone)")
            }

            if !root.isDefault {
                // Usage only lands in this directory when Claude is run against
                // it, so the command is the essential half of the setup.
                HStack(spacing: 5) {
                    Text(AccountLauncher.usageCommand(for: root))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            AccountLauncher.usageCommand(for: root), forType: .string
                        )
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the command that runs Claude under this account")
                }
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func sessionAccountRow(_ account: SessionAccount) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "key.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.label)
                    .font(.system(size: 11, weight: .medium))
                Text("session key · \(account.organizationName)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Button {
                store.removeSessionAccount(account)
                sessionAccounts = Preferences.shared.sessionAccounts
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop tracking this account and delete its session key from the keychain")
        }
        .padding(6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var addAccountSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to another Claude account")
                .font(.system(size: 13, weight: .semibold))
            Text("A separate config directory is created for this account, then "
                 + "Claude Code's sign-in opens in Terminal. Your browser handles "
                 + "the login exactly as it normally would.")
                .helpText()

            TextField("Name for this account (e.g. work)", text: $newAccountLabel)
                .textFieldStyle(.roundedBorder)

            if !AccountLauncher.isClaudeAvailable {
                Text("The `claude` command could not be found, so Terminal cannot be "
                     + "launched automatically. The directory will still be created and "
                     + "the sign-in command shown for you to run yourself.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { showAddAccount = false }
                Button("Sign in") { startLogin() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newAccountLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func startLogin() {
        let label = newAccountLabel.trimmingCharacters(in: .whitespaces)
        do {
            let root = try AccountLauncher.prepareRoot(label: label)
            guard !trackedRoots.contains(where: { $0.path == root.path }) else {
                loginError = "An account with that name is already being tracked."
                showAddAccount = false
                return
            }
            // Tracked immediately: the user asked for this directory by name,
            // which is exactly the consent that discovery cannot supply.
            trackedRoots.append(root)
            apply()

            do {
                try AccountLauncher.beginLogin(for: root)
                loginError = nil
            } catch {
                // The directory is tracked either way, so a missing `claude`
                // just means the user runs the sign-in themselves.
                loginError = "\(error.localizedDescription)\n\n"
                    + AccountLauncher.manualLoginCommand(for: root)
            }
            showAddAccount = false
        } catch {
            loginError = error.localizedDescription
        }
    }

    private var bridgeSection: some View {
        let installed = trackedRoots.filter { RateLimitBridge.isInstalled(for: $0) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("LIVE FIGURES").sectionHeader()
            Text("Claude Code hands its status line the live 5-hour and 7-day "
                 + "percentages, but never writes them to disk — the copy it "
                 + "caches can be hours old and may even belong to a previously "
                 + "signed-in account. Adding this line to your status line "
                 + "script publishes them, and the panel then matches the "
                 + "terminal exactly.")
                .helpText()

            HStack(alignment: .top, spacing: 6) {
                Text(RateLimitBridge.snippet)
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(RateLimitBridge.snippet, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }

            if installed.isEmpty {
                Label("Not publishing yet — figures come from Claude's cached copy",
                      systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Label(installed.count == 1
                      ? "Publishing from 1 config directory"
                      : "Publishing from \(installed.count) config directories",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            }
        }
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DATA").sectionHeader()
            Text(sessionAccounts.isEmpty
                 ? "Everything is read from local transcript files. Nothing is "
                   + "sent anywhere, and no credentials are read."
                 : "Config-directory accounts are read from local files only. "
                   + "Session-key accounts additionally contact claude.ai, using "
                   + "a key kept in your login keychain — nothing else leaves "
                   + "this Mac.")
                .helpText()

            HStack {
                Button {
                    apply()
                    isRescanning = true
                    Task {
                        await store.rescanEverything()
                        isRescanning = false
                    }
                } label: {
                    if isRescanning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("Rescanning…")
                        }
                    } else {
                        Text("Rescan all transcripts")
                    }
                }
                .disabled(isRescanning)

                Button("Reveal data folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Storage.directory.path)
                }
            }
        }
    }

    // MARK: - Actions

    private func apply() {
        prefs.refreshInterval = refreshInterval
        prefs.notifyEnabled = notifyEnabled
        prefs.warnThreshold = warn / 100
        prefs.criticalThreshold = critical / 100
        prefs.trackedRoots = trackedRoots
        prefs.barLength = barLength
        store.startTimer()
        Task { await store.refresh() }
    }
}

/// Shared by the settings window and the sheets it presents.
extension Text {
    func sectionHeader() -> some View {
        self.font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }

    func helpText() -> some View {
        self.font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
