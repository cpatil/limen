import Cocoa

// Minimal programmatic main menu. Without one, an app launched outside Xcode has no
// working Quit/Copy shortcuts.
private func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    let appName = ProcessInfo.processInfo.processName
    appMenu.addItem(withTitle: "About \(appName)",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Hide \(appName)",
                    action: #selector(NSApplication.hide(_:)),
                    keyEquivalent: "h")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Quit \(appName)",
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let windowMenuItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize",
                       action: #selector(NSWindow.performMiniaturize(_:)),
                       keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Close",
                       action: #selector(NSWindow.performClose(_:)),
                       keyEquivalent: "w")
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    return mainMenu
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.setActivationPolicy(.regular)
application.mainMenu = buildMainMenu()
application.delegate = appDelegate
application.run()
