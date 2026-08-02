import Foundation
import Combine
import UserNotifications

/// One account's two limit gauges.
struct AccountGauges: Identifiable {
    var account: Account
    var isCurrent: Bool
    var fiveHour: Gauge
    var weekly: Gauge
    var byModel: [ModelUsage]
    var containsInferred: Bool
    /// Read from claude.ai with a session key rather than from a config
    /// directory. There is no transcript history behind these, so no model mix.
    var isSessionKey: Bool = false
    /// Why the last fetch failed, if it did. Shown in the panel rather than
    /// swallowed: a session key that has quietly expired otherwise looks
    /// identical to an account that simply has no usage.
    var errorMessage: String? = nil

    var id: String { account.uuid }

    /// Whichever limit is closer to its ceiling — the number worth acting on.
    var headlineFraction: Double { max(fiveHour.fraction, weekly.fraction) }
}

/// Owns the scan → aggregate → publish pipeline and the periodic refresh timer.
@MainActor
final class UsageStore: ObservableObject {

    @Published private(set) var accounts: [AccountGauges] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isScanning = false

    private let registry = AccountRegistry()
    private let scanner: UsageScanner
    private var events: [UsageEvent] = []
    private var limits: [LimitEvent] = []
    private var snapshots: [String: UtilizationSnapshot] = [:]
    /// Keyed by `SessionAccount.accountUUID`.
    private var sessionSnapshots: [String: UtilizationSnapshot] = [:]
    private var sessionErrors: [String: String] = [:]
    private var timer: Timer?
    /// The highest threshold already announced for each account/limit, keyed by
    /// the window it belongs to. Persisted so a relaunch does not re-announce.
    private var notified: [String: AlertState] = [:]

    /// Raw events older than this are dropped; the app is a live meter, not an
    /// archive, and this bounds the on-disk file.
    private static let retention: TimeInterval = 180 * 24 * 60 * 60

    init() {
        scanner = UsageScanner(registry: registry)
        events = Storage.load([UsageEvent].self, from: Storage.eventsFile) ?? []
        limits = Storage.load([LimitEvent].self, from: Storage.limitsFile) ?? []
        notified = Storage.load([String: AlertState].self, from: Storage.alertsFile) ?? [:]
        recompute()
        startTimer()
        Task { await refresh() }
    }

    func startTimer() {
        timer?.invalidate()
        let interval = max(Preferences.shared.refreshInterval, 30)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Re-reads config roots and any transcript bytes appended since last time.
    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let roots = Preferences.shared.allRoots
        // Record who is logged in *before* scanning, so events written since
        // the last refresh are attributed to the account that produced them.
        registry.observe(roots: roots)
        purgeRemovedRoots(keeping: roots)

        // Live figures where a status line publishes them, otherwise Claude's
        // own cache — but only when that cache belongs to the account currently
        // signed in to the root, since it survives an account switch.
        snapshots = [:]
        for root in roots {
            guard let account = registry.currentAccount(forRoot: root.id) else { continue }
            if let bridged = RateLimitBridge.read(root: root, accountUUID: account.uuid) {
                snapshots[account.uuid] = bridged
            } else if let cached = UtilizationReader.read(root: root),
                      cached.accountUUID == account.uuid {
                snapshots[account.uuid] = cached
            }
        }

        let scanner = self.scanner
        async let scanned = Task.detached(priority: .utility) {
            scanner.scan(roots: roots)
        }.value
        // Independent of the transcript scan, and network-bound, so the two
        // run together rather than adding their latencies.
        async let fetched: Void = refreshSessionAccounts()

        let fresh = await scanned
        await fetched

        let cutoff = Date().addingTimeInterval(-Self.retention)
        if !fresh.usage.isEmpty {
            events.append(contentsOf: fresh.usage)
            events.removeAll { $0.timestamp < cutoff }
            events.sort { $0.timestamp < $1.timestamp }
            Storage.save(events, to: Storage.eventsFile)
        }
        if !fresh.limits.isEmpty {
            limits.append(contentsOf: fresh.limits)
            limits.removeAll { $0.timestamp < cutoff }
            limits.sort { $0.timestamp < $1.timestamp }
            Storage.save(limits, to: Storage.limitsFile)
        }

        lastRefresh = Date()
        recompute()
        checkThresholds()
    }

    // MARK: - Session-key accounts

    /// Fetches each session-key account's figures from claude.ai.
    ///
    /// Failures are recorded per account rather than thrown: one expired key
    /// must not stop the other accounts — or the transcript scan — from
    /// refreshing. The previous good reading is kept so a dropped Wi-Fi
    /// connection shows a figure that is visibly ageing rather than a dash.
    private func refreshSessionAccounts() async {
        let configured = Preferences.shared.sessionAccounts
        guard !configured.isEmpty else {
            sessionSnapshots = [:]
            sessionErrors = [:]
            return
        }

        var snapshots: [String: UtilizationSnapshot] = [:]
        var errors: [String: String] = [:]

        await withTaskGroup(of: (String, Result<UtilizationSnapshot, Error>).self) { group in
            for account in configured {
                let id = account.accountUUID
                let org = account.organizationUUID
                guard let stored = Keychain.read(account: account.keychainAccount) else {
                    errors[id] = "No session key in the keychain for this account — "
                               + "remove it and sign in again."
                    continue
                }
                guard let key = try? SessionKey(stored) else {
                    errors[id] = "The stored session key is unreadable — "
                               + "remove this account and sign in again."
                    continue
                }
                group.addTask {
                    do {
                        return (id, .success(try await ClaudeWebClient.usage(organization: org, key: key)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let snapshot): snapshots[id] = snapshot
                case .failure(let error):    errors[id] = error.localizedDescription
                }
            }
        }

        // Carry forward the last good reading, but only for accounts that are
        // still configured — otherwise a removed account's figures survive it.
        let live = Set(configured.map(\.accountUUID))
        for (id, previous) in sessionSnapshots where snapshots[id] == nil && live.contains(id) {
            snapshots[id] = previous
        }

        sessionSnapshots = snapshots
        sessionErrors = errors
    }

    /// Stores a validated session key in the keychain and starts tracking the
    /// account it belongs to.
    func addSessionAccount(_ account: SessionAccount, key: SessionKey) throws {
        try Keychain.save(key.value, account: account.keychainAccount)
        var accounts = Preferences.shared.sessionAccounts
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        Preferences.shared.sessionAccounts = accounts
    }

    /// Stops tracking a session-key account and destroys its stored key.
    func removeSessionAccount(_ account: SessionAccount) {
        Keychain.delete(account: account.keychainAccount)
        Preferences.shared.sessionAccounts.removeAll { $0.id == account.id }
        sessionSnapshots[account.accountUUID] = nil
        sessionErrors[account.accountUUID] = nil
        recompute()
    }

    /// Forgets incremental state and re-reads every transcript from scratch.
    func rescanEverything() async {
        scanner.reset()
        events = []
        limits = []
        Storage.save(events, to: Storage.eventsFile)
        Storage.save(limits, to: Storage.limitsFile)
        await refresh()
    }

    /// Drops everything belonging to config roots that are no longer tracked,
    /// so removing an account in Settings actually makes it disappear rather
    /// than lingering on the strength of its stored history.
    private func purgeRemovedRoots(keeping roots: [ConfigRoot]) {
        let active = Set(roots.map(\.id))

        if events.contains(where: { !active.contains($0.rootID) })
            || limits.contains(where: { !active.contains($0.rootID) }) {
            // Deleting just this root's events is not enough. The scanner keeps
            // per-file byte offsets and a *global* set of seen message IDs,
            // neither of which is attributed to a root — so after a targeted
            // delete, re-adding the directory would re-read nothing and dedupe
            // away everything, leaving an account with no history at all.
            //
            // Untracking is a routine operation now rather than a rare one, so
            // it has to be reversible: throw the derived state away and let the
            // scan that follows rebuild it from the transcripts. Costs one full
            // re-parse of the roots that remain.
            events = []
            limits = []
            scanner.reset()
            Storage.save(events, to: Storage.eventsFile)
            Storage.save(limits, to: Storage.limitsFile)
        }

        // Pruned unconditionally: a root can be removed before any of its usage
        // was ever recorded, and gating this on stale events would leave the
        // account behind in the registry.
        registry.prune(keeping: active)
    }

    // MARK: - Aggregation

    /// Re-derives account attribution for every stored event.
    ///
    /// Attribution depends on the observation timeline, which grows over time,
    /// so it is recomputed rather than frozen at scan time. Without this, events
    /// scanned before the app had ever seen an account would stay attributed to
    /// "unknown" permanently.
    private func reattribute() {
        for i in events.indices {
            let r = registry.attribute(rootID: events[i].rootID, at: events[i].timestamp)
            events[i].accountUUID = r.uuid
            events[i].inferredAccount = r.inferred
        }
    }

    private func recompute() {
        reattribute()
        let now = Date()

        let currentUUIDs = Set(
            Preferences.shared.allRoots.compactMap { registry.currentAccount(forRoot: $0.id)?.uuid }
        )
        let seen = Set(events.map(\.accountUUID))
        let known = registry.allAccounts.filter { seen.contains($0.uuid) || currentUUIDs.contains($0.uuid) }

        // Each account has its own rate limits, so every gauge is computed
        // from that account's events alone — combining them would be
        // meaningless against a per-account ceiling.
        var built: [AccountGauges] = []
        for account in known {
            let own = events.filter { $0.accountUUID == account.uuid }
            // Matched strictly on account UUID. Claude Code leaves the previous
            // account's figures in place after a switch, and showing those
            // against the new account is the mismatch this guards against.
            let snapshot = snapshots[account.uuid]

            built.append(AccountGauges(
                account: account,
                isCurrent: currentUUIDs.contains(account.uuid),
                fiveHour: Aggregator.gauge(kind: .session, snapshot: snapshot, now: now),
                weekly: Aggregator.gauge(kind: .weekly, snapshot: snapshot, now: now),
                byModel: Aggregator.modelBreakdown(own, since: now.addingTimeInterval(-30 * 86_400)),
                containsInferred: own.contains(where: \.inferredAccount)
            ))
        }

        // Session-key accounts. Always "current": unlike a config directory,
        // which only reports when Claude Code has been run against it, these
        // are fetched on every refresh.
        for session in Preferences.shared.sessionAccounts {
            let snapshot = sessionSnapshots[session.accountUUID]
            built.append(AccountGauges(
                account: session.asAccount,
                isCurrent: true,
                fiveHour: Aggregator.gauge(kind: .session, snapshot: snapshot, now: now, live: true),
                weekly: Aggregator.gauge(kind: .weekly, snapshot: snapshot, now: now, live: true),
                byModel: [],
                containsInferred: false,
                isSessionKey: true,
                errorMessage: sessionErrors[session.accountUUID]
            ))
        }

        accounts = built.sorted {
            ($0.isCurrent ? 0 : 1, -$0.headlineFraction, $0.account.email)
                < ($1.isCurrent ? 0 : 1, -$1.headlineFraction, $1.account.email)
        }
    }

    /// The account currently signed in to a config root, if any has been seen.
    /// Exposes the registry to the settings UI.
    func account(forRoot rootID: String) -> Account? {
        registry.currentAccount(forRoot: rootID)
    }

    /// One meter group per account, in the same order as the panel.
    /// `nil` readings mean no calibrated ceiling yet, drawn as a dash.
    var menuBarMeters: [AccountMeter] {
        accounts.map { entry in
            AccountMeter(
                initial: entry.account.shortLabel.prefix(1).uppercased(),
                fiveHour: entry.fiveHour.isCalibrated ? entry.fiveHour.fraction : nil,
                weekly: entry.weekly.isCalibrated ? entry.weekly.fraction : nil
            )
        }
    }

    // MARK: - Notifications

    private func checkThresholds() {
        guard Preferences.shared.notifyEnabled else { return }

        let before = notified
        let now = Date()
        // Gathered first and posted once. A refresh can carry several accounts
        // and two limits each past a threshold at the same moment, and four
        // separate banners for one event is noise, not information.
        var crossings: [Crossing] = []
        for entry in accounts {
            if let c = crossing(entry, gauge: entry.fiveHour, label: "5-hour", key: "5h", now: now) {
                crossings.append(c)
            }
            if let c = crossing(entry, gauge: entry.weekly, label: "7-day", key: "7d", now: now) {
                crossings.append(c)
            }
        }

        // Drop state for accounts that are no longer tracked, so the file does
        // not accumulate entries for every account ever seen.
        let live = Set(accounts.map(\.account.uuid))
        notified = notified.filter { live.contains($0.key.components(separatedBy: "|")[0]) }

        if notified != before { Storage.save(notified, to: Storage.alertsFile) }
        announce(crossings)
    }

    /// Records that one gauge has crossed a threshold, at most once per
    /// threshold per window.
    ///
    /// The recorded level only ever rises within a window, so crossing "warn"
    /// counts once and crossing "critical" counts once — and a figure that
    /// hovers on a threshold, or a refresh that simply re-reads the same
    /// percentage, stays silent until the window it belongs to has run out.
    ///
    /// Returns the crossing when there is something new to announce, so the
    /// caller can fold every gauge's crossing into a single notification.
    private func crossing(
        _ entry: AccountGauges, gauge: Gauge, label: String, key: String, now: Date
    ) -> Crossing? {
        // Without a reset instant there is no window to scope the alert to, and
        // an alert that can never be cleared would either fire forever or never
        // fire again.
        guard gauge.isCalibrated, let resetAt = gauge.resetAt else { return nil }

        let stateKey = "\(entry.account.uuid)|\(key)"
        // Re-arm only once the announced window has actually elapsed — never
        // merely because the published reset instant moved. claude.ai reports
        // the five-hour reset as a rolling instant, so `resets_at` creeps
        // forward on every fetch; matching the stored window against it for
        // equality re-armed the alert on each manual and timed refresh and
        // re-announced a threshold the user had already been told about. The
        // window is pinned when the alert arms and left alone afterwards, so
        // that creep cannot push the next re-arm out either.
        let elapsed = notified[stateKey].map { now >= $0.window } ?? true
        if elapsed { notified[stateKey] = AlertState(window: resetAt, level: .normal) }
        guard var state = notified[stateKey] else { return nil }

        let level = gauge.level
        guard level > state.level else { return nil }
        state.level = level
        notified[stateKey] = state

        return Crossing(
            account: entry.account.shortLabel,
            limit: label,
            percent: gauge.percent,
            level: level,
            resetAt: resetAt,
            // Stable across retries, so a duplicate post would replace the
            // notification rather than stack a second one.
            id: "\(stateKey)|\(Int(state.window.timeIntervalSince1970))|\(level.rawValue)"
        )
    }

    /// Posts one notification for everything a single refresh crossed.
    ///
    /// The worst crossing sets the headline — a critical alongside a warn reads
    /// as critical — and the rest are listed underneath rather than announced
    /// on their own.
    private func announce(_ crossings: [Crossing]) {
        guard !crossings.isEmpty else { return }
        // Worst first, so the headline and the top line agree.
        let ranked = crossings.sorted { ($0.level, $0.percent) > ($1.level, $1.percent) }
        let id = ranked.map(\.id).joined(separator: ",")

        guard ranked.count > 1 else {
            let only = ranked[0]
            Notifier.post(
                id: id,
                title: "\(only.account) — \(only.limit) usage at \(only.percent)%",
                body: "resets \(Fmt.resetAt(only.resetAt))"
            )
            return
        }

        let severity = ranked[0].level.severity
        // One account's own limits do not need repeating the label on every
        // line; several accounts do.
        let single = Set(ranked.map(\.account)).count == 1
        let title = single
            ? "\(ranked[0].account) — usage \(severity)"
            : "Claude usage \(severity) — \(ranked.count) limits"
        let body = ranked.map {
            (single ? "" : "\($0.account) · ")
                + "\($0.limit) \($0.percent)% · resets \(Fmt.resetAt($0.resetAt))"
        }.joined(separator: "\n")

        Notifier.post(id: id, title: title, body: body)
    }
}

/// One gauge's newly crossed threshold, awaiting announcement.
private struct Crossing {
    var account: String
    var limit: String
    var percent: Int
    var level: UsageLevel
    var resetAt: Date
    var id: String
}

/// One account/limit's alert progress within a single window: the worst level
/// already announced, which only ever rises until the window elapses.
struct AlertState: Codable, Equatable {
    var window: Date
    var level: UsageLevel

    init(window: Date, level: UsageLevel) {
        self.window = window
        self.level = level
    }

    /// A level this version does not recognise is read as `.normal` rather than
    /// failing the decode. The alert record is a single dictionary, so one bad
    /// entry written by a future version would otherwise discard *every*
    /// account's progress and re-announce thresholds the user has already been
    /// told about — the exact thing this file exists to prevent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        window = try c.decode(Date.self, forKey: .window)
        level = (try? c.decode(UsageLevel.self, forKey: .level)) ?? .normal
    }
}

/// Thin wrapper so notification failures (unsigned build, denied permission)
/// degrade to nothing rather than crashing.
enum Notifier {
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Banners carry the app icon on their left, which macOS reads from the
    /// bundle — `CFBundleIconFile` and `Contents/Resources/AppIcon.icns`, both
    /// written by `build-app.sh`. There is no per-notification override for it,
    /// and an attached image is a *second* thumbnail rather than a replacement,
    /// so nothing here sets one.

    static func post(id: String, title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: id, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Delivers a sample alert, reporting why if it cannot.
    ///
    /// Threshold alerts are rare and arrive unpredictably, and the delivery
    /// path has three ways to stay silent that look identical from inside the
    /// app: a build with no bundle identifier, a permission never granted, and
    /// a permission since revoked in System Settings. None of them surface
    /// until a limit is crossed — precisely when the user needed it to work.
    ///
    /// - Returns: nil when the notification was handed to macOS, otherwise a
    ///   sentence explaining what to fix.
    static func test() async -> String? {
        guard Bundle.main.bundleIdentifier != nil else {
            return "This build has no bundle identifier, so macOS will not deliver "
                 + "notifications. Run Burning Claude.app rather than the bare binary."
        }

        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .denied:
            return "Notifications are turned off for Burning Claude in "
                 + "System Settings › Notifications."
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if !granted { return "Permission to send notifications was declined." }
        default:
            break
        }

        // Deliberately not shaped like a threshold alert. This says only that
        // delivery works; quoting a percentage would be inventing a reading,
        // and a banner that looks like a real limit warning is worse than no
        // banner at all.
        let content = UNMutableNotificationContent()
        content.title = "Burning Claude — test"
        content.body = "Notifications are working. This is not a usage alert."
        content.sound = .default
        do {
            // A fresh identifier every time, so pressing the button twice shows
            // a second banner instead of quietly replacing the first.
            try await center.add(UNNotificationRequest(
                identifier: "test-\(UUID().uuidString)", content: content, trigger: nil
            ))
        } catch {
            return error.localizedDescription
        }
        return nil
    }
}
