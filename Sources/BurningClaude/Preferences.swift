import Foundation

/// User settings, backed by `UserDefaults`.
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let notifyEnabled = "notifyEnabled"
        static let warnThreshold = "warnThreshold"
        static let criticalThreshold = "criticalThreshold"
        static let trackedRoots = "trackedRoots"
        static let barLength = "barLength"
        static let sessionAccounts = "sessionAccounts"

        /// Replaced by `trackedRoots`. Read once, to migrate, then deleted.
        static let legacyExtraRoots = "extraRoots"
        static let legacyExcludedRoots = "excludedRoots"
    }

    /// The bundle identifier this app shipped under before it was renamed, and
    /// therefore the `UserDefaults` domain the settings used to live in.
    private static let legacyBundleID = "com.local.claudetokenmeter"

    private init() {
        adoptLegacyDomain()
        defaults.register(defaults: [
            Key.refreshInterval: 300.0,
            Key.notifyEnabled: true,
            Key.warnThreshold: 0.75,
            Key.criticalThreshold: 0.90,
            Key.barLength: 28.0,
        ])
        migrateAwayFromAutoDiscovery()
    }

    /// Carries settings across the change of bundle identifier.
    ///
    /// The identifier had to change: macOS keys an app's notification record by
    /// it, that record is written the first time authorization is requested,
    /// and it never picks up an icon added to the bundle afterwards — which is
    /// why banners drew a blank white square no matter what the bundle
    /// contained. A new identifier gets a new record, and the icon with it.
    ///
    /// `UserDefaults` is keyed by the same identifier, so the settings would
    /// otherwise have been left behind in a domain nothing reads. Copied rather
    /// than moved, and only into an empty domain, so this cannot overwrite
    /// newer settings and the old values survive a rollback.
    private func adoptLegacyDomain() {
        guard defaults.object(forKey: Key.trackedRoots) == nil,
              defaults.object(forKey: Key.sessionAccounts) == nil,
              let legacy = UserDefaults(suiteName: Self.legacyBundleID)
        else { return }

        for key in [Key.refreshInterval, Key.notifyEnabled, Key.warnThreshold,
                    Key.criticalThreshold, Key.trackedRoots, Key.barLength,
                    Key.sessionAccounts] {
            guard let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
        }
    }

    /// The app used to track every config directory it could find and make you
    /// remove the ones you did not want. That is backwards: the cost of a wrong
    /// guess is a menu bar reporting some idle account's numbers, and there is
    /// no guess that is right for everyone. Nothing is tracked now until it is
    /// added, so a fresh install starts empty and asks you to sign in.
    ///
    /// Existing installs are not migrated across: their tracked set was the
    /// product of auto-discovery, not a choice, so carrying it over would
    /// preserve exactly what this change is undoing.
    private func migrateAwayFromAutoDiscovery() {
        guard defaults.object(forKey: Key.legacyExtraRoots) != nil
                || defaults.object(forKey: Key.legacyExcludedRoots) != nil
        else { return }
        defaults.removeObject(forKey: Key.legacyExtraRoots)
        defaults.removeObject(forKey: Key.legacyExcludedRoots)
    }

    /// Seconds between automatic refreshes.
    var refreshInterval: TimeInterval {
        get { defaults.double(forKey: Key.refreshInterval) }
        set { defaults.set(newValue, forKey: Key.refreshInterval) }
    }

    var notifyEnabled: Bool {
        get { defaults.bool(forKey: Key.notifyEnabled) }
        set { defaults.set(newValue, forKey: Key.notifyEnabled) }
    }

    /// Fraction of the calibrated ceiling at which the bar turns amber.
    var warnThreshold: Double {
        get { defaults.double(forKey: Key.warnThreshold) }
        set { defaults.set(newValue, forKey: Key.warnThreshold) }
    }

    /// Fraction at which the bar turns red and a critical alert fires.
    var criticalThreshold: Double {
        get { defaults.double(forKey: Key.criticalThreshold) }
        set { defaults.set(newValue, forKey: Key.criticalThreshold) }
    }

    /// Length in points of each meter bar drawn in the menu bar.
    var barLength: Double {
        get { min(max(defaults.double(forKey: Key.barLength), 8), 80) }
        set { defaults.set(min(max(newValue, 8), 80), forKey: Key.barLength) }
    }

    /// Config directories the user has explicitly chosen to track.
    ///
    /// An allow-list, not a block-list: a directory that merely exists on this
    /// Mac is a *suggestion* in Settings, nothing more. `~/.claude` gets no
    /// special treatment — it is added, or it is not.
    var trackedRoots: [ConfigRoot] {
        get {
            guard let data = defaults.data(forKey: Key.trackedRoots) else { return [] }
            return (try? Storage.decoder.decode([ConfigRoot].self, from: data)) ?? []
        }
        set {
            guard let data = try? Storage.encoder.encode(newValue) else { return }
            defaults.set(data, forKey: Key.trackedRoots)
        }
    }

    /// Accounts read from claude.ai with a session key. Only the metadata is
    /// here — the key itself is in the keychain, keyed by `keychainAccount`.
    var sessionAccounts: [SessionAccount] {
        get {
            guard let data = defaults.data(forKey: Key.sessionAccounts) else { return [] }
            return (try? Storage.decoder.decode([SessionAccount].self, from: data)) ?? []
        }
        set {
            guard let data = try? Storage.encoder.encode(newValue) else { return }
            defaults.set(data, forKey: Key.sessionAccounts)
        }
    }

    /// Every config directory the app reads. Empty until the user adds one.
    var allRoots: [ConfigRoot] {
        var seen = Set<String>()
        return trackedRoots.filter { seen.insert($0.path).inserted }
    }
}
