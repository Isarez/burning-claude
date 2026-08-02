import AppKit
import SwiftUI
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem!
    private var statusView: StatusBarView!
    private var popover: NSPopover!
    private var store: UsageStore!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        // Invisible, but it is what makes ⌘V reach a text field. See MainMenu.
        MainMenu.install()

        store = UsageStore()
        // Set before authorization is requested, and before launch finishes, or
        // the first notifications of the session are presented without it.
        //
        // Guarded like every other call into the notification centre: without a
        // bundle identifier `current()` does not degrade, it raises — so the
        // bare binary aborted here, before reaching either the BC_TEST_NOTIFICATION
        // hook below or the message in `Notifier.test` that tells you to run the
        // app bundle instead.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            Notifier.requestAuthorization()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePopover)
        button.target = self

        statusView = StatusBarView(frame: button.bounds)
        statusView.autoresizingMask = [.width, .height]
        button.addSubview(statusView)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(store: store) { [weak self] signIn in
                self?.openSettings(signIn: signIn)
            }
        )

        // Redraw whenever any published figure changes.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        updateStatusItem()

        // Fires the same banner the Settings button sends, for checking how a
        // notification actually renders without clicking through the menu bar:
        //   BC_TEST_NOTIFICATION=1 build/BurningClaude.app/Contents/MacOS/BurningClaude
        if ProcessInfo.processInfo.environment["BC_TEST_NOTIFICATION"] != nil {
            Task {
                let outcome = await Notifier.test() ?? "sent"
                FileHandle.standardError.write("test notification: \(outcome)\n".data(using: .utf8)!)
            }
        }
    }

    private func updateStatusItem() {
        let meters = store.menuBarMeters
        let barLength = CGFloat(Preferences.shared.barLength)

        statusView.meters = meters
        statusView.barLength = barLength
        // The item has to be resized explicitly: its width depends on how many
        // accounts are being shown and how long the bars are.
        statusItem.length = StatusBarView.width(meters: meters, barLength: barLength)
        statusItem.button?.toolTip = tooltip
    }

    private var tooltip: String {
        guard !store.accounts.isEmpty else {
            return "Burning Claude — not signed in\nClick to add an account"
        }
        var lines: [String] = []
        // The flame is tinted by the combined figure, so with more than one
        // account there is nothing on screen that explains its colour.
        if store.accounts.count > 1, let combined = statusView.summaryFraction {
            lines.append("All accounts: \(Int((combined * 100).rounded()))% used")
        }
        for entry in store.accounts {
            if store.accounts.count > 1 {
                lines.append("\(entry.account.shortLabel.prefix(1).uppercased())  \(entry.account.email)")
            } else {
                lines.append(entry.account.email)
            }
            lines.append("   " + gaugeLine("5-hour", entry.fiveHour))
            lines.append("   " + gaugeLine("7-day", entry.weekly))
        }
        return lines.joined(separator: "\n")
    }

    private func gaugeLine(_ label: String, _ gauge: Gauge) -> String {
        guard gauge.isCalibrated, let resetAt = gauge.resetAt else {
            return "\(label): \(gauge.source.label)"
        }
        return "\(label): \(gauge.percent)% · resets \(Fmt.resetAt(resetAt))"
    }

    @objc func openSettingsFromMenu() { openSettings(signIn: false) }

    /// Opens Settings in a real window rather than as a sheet inside the
    /// popover.
    ///
    /// It used to be a sheet, which was wrong twice over. A `.transient`
    /// popover closes as soon as the app is no longer frontmost, so it could
    /// vanish out from under its own modal sheet — and a sheet in a popover has
    /// no title bar, so there is nothing to close, move or minimise. A window
    /// also becomes key properly, which is what lets a text field accept a
    /// paste.
    private func openSettings(signIn: Bool) {
        popover.performClose(nil)

        let window = settingsWindow ?? {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.title = "Burning Claude Settings"
            // An accessory app's windows are released on close by default,
            // which would leave this reference dangling on the second open.
            created.isReleasedWhenClosed = false
            created.center()
            settingsWindow = created
            return created
        }()

        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                store: store,
                presentSessionKeySheet: signIn,
                onDone: { [weak window] in window?.performClose(nil) }
            )
        )
        // Accessory apps are not activated by a status item click, and a window
        // in a background app cannot become key — so no keystrokes, including
        // ⌘V, would reach the session key field.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows banners even when Burning Claude is frontmost.
    ///
    /// macOS suppresses notifications for the active app unless the app says
    /// otherwise, which is usually the right call — but it made the Test
    /// Notification button look broken. Pressing it means the Settings window
    /// is frontmost, so the one banner the user explicitly asked for was the
    /// one guaranteed not to appear, while real threshold alerts (which arrive
    /// with the app in the background) came through fine.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            Task { await store.refresh() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
