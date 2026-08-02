import AppKit

/// The application menu.
///
/// A menu bar extra shows no menu bar of its own, which makes it tempting to
/// skip this entirely — the previous version did. That silently breaks every
/// standard keyboard shortcut: `NSApplication` dispatches key equivalents
/// through `mainMenu`, so with no menu there is no target for ⌘V and **paste
/// does nothing at all**. Pasting is the only way to get a session key into
/// this app, so the menu is load-bearing even though nobody ever sees it.
enum MainMenu {

    static func install() {
        let main = NSMenu()
        main.addItem(submenu: appMenu())
        main.addItem(submenu: editMenu())
        main.addItem(submenu: windowMenu())
        NSApp.mainMenu = main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Burning Claude")
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(AppDelegate.openSettingsFromMenu),
            keyEquivalent: ","
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide Burning Claude",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Burning Claude",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    /// The whole reason this file exists. These selectors resolve against the
    /// first responder — the focused text field — so they must be wired up even
    /// though the menu is never drawn.
    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(
            withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        )
        menu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        return menu
    }
}

private extension NSMenu {
    /// Top-level menus are an item whose only job is to carry the submenu.
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        addItem(item)
    }
}
