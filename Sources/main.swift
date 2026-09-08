import Cocoa

// Minimal programmatic main menu. Without one, an app launched outside Xcode has no
// working Quit/Copy shortcuts.
private func buildMainMenu(target: AppDelegate) -> NSMenu {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    let appName = ProcessInfo.processInfo.processName
    appMenu.addItem(withTitle: "About \(appName)",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    // The only thing in the app that touches the network, and only from here.
    // Explicit targets: a nil-target menu item is dispatched through the responder
    // chain, which does not resolve dependably when the app is not frontmost.
    let updateItem = NSMenuItem(title: "Check for Speed Catalogue Update…",
                                action: #selector(AppDelegate.checkForCatalogueUpdate(_:)),
                                keyEquivalent: "")
    updateItem.target = target
    appMenu.addItem(updateItem)
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

    let viewMenuItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
    let appearanceMenu = NSMenu(title: "Appearance")
    let chosen = UserDefaults.standard.integer(forKey: "Appearance")
    for (tag, title) in [(0, "Match System"), (1, "Light"), (2, "Dark")] {
        let item = NSMenuItem(title: title,
                              action: #selector(AppDelegate.setAppearance(_:)),
                              keyEquivalent: "")
        item.tag = tag
        item.target = target
        item.state = tag == chosen ? .on : .off
        appearanceMenu.addItem(item)
    }
    appearanceItem.submenu = appearanceMenu
    viewMenu.addItem(appearanceItem)

    // How large a transfer has to be before it is worth a log entry.
    let sizeItem = NSMenuItem(title: "Minimum Logged Transfer", action: nil, keyEquivalent: "")
    let sizeMenu = NSMenu(title: "Minimum Logged Transfer")
    let chosenSize = Int(TransferLog.minimumSize)
    for option in TransferLog.sizeOptions {
        let item = NSMenuItem(title: option.title,
                              action: #selector(AppDelegate.setMinimumLogged(_:)),
                              keyEquivalent: "")
        item.tag = Int(option.bytes)
        item.target = target
        item.state = Int(option.bytes) == chosenSize ? .on : .off
        sizeMenu.addItem(item)
    }
    sizeItem.submenu = sizeMenu
    viewMenu.addItem(sizeItem)
    viewMenuItem.submenu = viewMenu
    mainMenu.addItem(viewMenuItem)

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
application.mainMenu = buildMainMenu(target: appDelegate)
application.delegate = appDelegate
application.run()
