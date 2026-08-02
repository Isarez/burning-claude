import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    /// Opens the Settings window. The flag asks it to go straight to the
    /// session-key form. Settings deliberately lives outside this popover — see
    /// `AppDelegate.openSettings`.
    var openSettings: (_ signIn: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.accounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            AccountSection(entry: entry)
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 460)

            Divider()
            footer
        }
        .frame(width: 380)
    }

    // MARK: - Header (refresh lives here)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Burning Claude").font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if store.isScanning {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 16, height: 16)
            } else {
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }

            Button { openSettings(false) } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        if store.accounts.isEmpty { return "No accounts yet" }
        if store.isScanning { return "Scanning transcripts…" }
        guard let last = store.lastRefresh else { return "Not yet refreshed" }
        let n = store.accounts.count
        let accounts = n == 1 ? "1 account" : "\(n) accounts"
        return "\(accounts) · updated \(Fmt.relative(last))"
    }

    /// Shown until the first account is added. Nothing is tracked by default —
    /// not even `~/.claude` — so this is the state a fresh install opens in, and
    /// it has to say what to do rather than merely reporting emptiness.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Not signed in").font(.system(size: 13, weight: .semibold))
                Text("Sign in with a claude.ai session key to see your 5-hour and "
                     + "7-day usage. It covers the whole account and refreshes "
                     + "every time this panel opens.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                openSettings(true)
            } label: {
                Label("Sign in with session key…", systemImage: "key")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Text("Prefer to keep everything local? Settings can track a Claude "
                 + "Code config directory instead — no credentials, but only "
                 + "what Claude Code last cached on this Mac.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private var calibrationNote: String {
        if store.accounts.isEmpty { return "Nothing tracked yet" }
        var official = 0
        for entry in store.accounts where entry.fiveHour.source.isOfficial || entry.weekly.source.isOfficial {
            official += 1
        }
        if official == 0 { return "Run Claude Code to refresh its usage figures" }
        return official == store.accounts.count
            ? "Figures reported by Claude"
            : "Reported by Claude where available"
    }

    // MARK: - Footer

    /// The byline. Deliberately not folded into `calibrationNote`: that string
    /// reports where the numbers came from and changes with the data, whereas
    /// this never changes. Kept to one line so the footer stays two rows at
    /// every popover width.
    private static let credit = "Created by Isarez · Powered by Claude"

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(calibrationNote)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(Self.credit)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - One account

private struct AccountSection: View {
    var entry: AccountGauges

    /// The organisation, tagged with the source when it is not the usual one.
    private var subtitle: String {
        let org = entry.account.organizationName
        guard entry.isSessionKey else { return org }
        return org.isEmpty ? "claude.ai · session key" : "\(org) · session key"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.isCurrent ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.account.email)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if entry.isSessionKey {
                    Image(systemName: "key.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .help("Fetched from claude.ai with a session key, so it "
                              + "covers the whole account and refreshes on demand.")
                } else if entry.isCurrent {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.green)
                }
                if entry.containsInferred {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("""
                        Transcripts do not record which account produced them. \
                        Usage from before this app first ran is attributed to the \
                        earliest account seen in each config directory.
                        """)
                }
            }

            if let errorMessage = entry.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GaugeRow(title: "5-hour limit", gauge: entry.fiveHour)
            GaugeRow(title: "7-day limit", gauge: entry.weekly)

            if !entry.byModel.isEmpty {
                ModelStrip(models: entry.byModel)
            }
        }
    }
}

private struct GaugeRow: View {
    var title: String
    var gauge: Gauge

    private var color: Color { gauge.level.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if gauge.source.isOfficial {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .help("This is Anthropic's own figure, the same one `/usage` "
                              + "shows in the terminal (\(gauge.source.label)).")
                } else if gauge.isCalibrated {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .help("Claude's cached figure has gone stale, so this is "
                              + "carried forward locally (\(gauge.source.label)). "
                              + "Run Claude Code to refresh it.")
                } else {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .help("Claude Code has not reported usage for this account yet.")
                }
                Spacer()
                Text(gauge.isCalibrated ? "\(gauge.percent)%" : "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(gauge.isCalibrated ? color : .secondary)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * gauge.barFraction)
                }
            }
            .frame(height: 6)

            if let resetAt = gauge.resetAt {
                Text("resets \(Fmt.resetAt(resetAt)) · in \(Fmt.duration(resetAt.timeIntervalSinceNow))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                Text(gauge.source.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact model breakdown for the last 30 days, as a share bar.
private struct ModelStrip: View {
    var models: [ModelUsage]

    private var total: Int { max(models.reduce(0) { $0 + $1.tokens.total }, 1) }

    private static let palette: [Color] = [.blue, .purple, .teal, .indigo, .mint, .gray]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(models.prefix(6).enumerated()), id: \.element.id) { i, m in
                        Rectangle()
                            .fill(Self.palette[i % Self.palette.count])
                            .frame(width: max(geo.size.width * Double(m.tokens.total) / Double(total) - 1, 1))
                    }
                }
            }
            .frame(height: 4)
            .clipShape(Capsule())

            HStack(spacing: 8) {
                ForEach(Array(models.prefix(3).enumerated()), id: \.element.id) { i, m in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Self.palette[i % Self.palette.count])
                            .frame(width: 5, height: 5)
                        Text(m.displayName)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("30d")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
