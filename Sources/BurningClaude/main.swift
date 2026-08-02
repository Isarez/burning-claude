import AppKit

@MainActor
private func launch() {
    let app = NSApplication.shared
    // `NSApplication.delegate` is unowned, so the delegate has to stay alive
    // for the process lifetime — this local does that, because `run()` does
    // not return until the app terminates.
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

// main.swift runs on the main thread, which is the main actor.
MainActor.assumeIsolated { launch() }
