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

    // How much each row says. Everything remains available on hover either way.
    let detailItem = NSMenuItem(title: "Row Detail", action: nil, keyEquivalent: "")
    let detailMenu = NSMenu(title: "Row Detail")
    let chosenDetail = RowDetail.current.rawValue
    for (tag, title) in [(0, "Calm"), (1, "Detailed")] {
        let item = NSMenuItem(title: title,
                              action: #selector(AppDelegate.setRowDetail(_:)),
                              keyEquivalent: "")
        item.tag = tag
        item.target = target
        item.state = tag == chosenDetail ? .on : .off
        detailMenu.addItem(item)
    }
    detailItem.submenu = detailMenu
    viewMenu.addItem(detailItem)

    let resortItem = NSMenuItem(title: "Re-sort Now",
                               action: #selector(AppDelegate.resortNow(_:)),
                               keyEquivalent: "r")
    resortItem.target = target
    viewMenu.addItem(resortItem)
    viewMenu.addItem(NSMenuItem.separator())

    let hoverItem = NSMenuItem(title: "Magnify on Hover",
                               action: #selector(AppDelegate.toggleHover(_:)),
                               keyEquivalent: "")
    hoverItem.target = target
    hoverItem.state = RootView.hoverEnabled ? .on : .off
    viewMenu.addItem(hoverItem)

    viewMenu.addItem(NSMenuItem.separator())

    // Where the two sections sit. The divider between them is draggable already;
    // this is the arrangement it divides.
    let arrangeItem = NSMenuItem(title: "Arrange Sections", action: nil, keyEquivalent: "")
    let arrangeMenu = NSMenu(title: "Arrange Sections")
    let stacked = UserDefaults.standard.bool(forKey: RootView.stackedKey)
    for (tag, title) in [(0, "Side by Side"), (1, "Stacked")] {
        let item = NSMenuItem(title: title,
                              action: #selector(AppDelegate.setPanesStacked(_:)),
                              keyEquivalent: "")
        item.tag = tag
        item.target = target
        item.state = (tag == 1) == stacked ? .on : .off
        arrangeMenu.addItem(item)
    }
    arrangeMenu.addItem(NSMenuItem.separator())
    let swapItem = NSMenuItem(title: "Swap Storage and Network",
                              action: #selector(AppDelegate.swapPanes(_:)),
                              keyEquivalent: "")
    swapItem.target = target
    arrangeMenu.addItem(swapItem)
    arrangeItem.submenu = arrangeMenu
    viewMenu.addItem(arrangeItem)

    viewMenuItem.submenu = viewMenu
    mainMenu.addItem(viewMenuItem)

    let helpMenuItem = NSMenuItem()
    let helpMenu = NSMenu(title: "Help")
    let setupItem = NSMenuItem(title: "Setup and Tour…",
                               action: #selector(AppDelegate.showSetup(_:)),
                               keyEquivalent: "")
    setupItem.target = target
    helpMenu.addItem(setupItem)
    helpMenuItem.submenu = helpMenu

    // Things Limen does by itself when a card turns up. Off until asked for.
    let cardsMenuItem = NSMenuItem()
    let cardsMenu = NSMenu(title: "Cards")
    for job in CardWatch.Job.allCases {
        let item = NSMenuItem(title: job.title,
                              action: #selector(AppDelegate.toggleCardJob(_:)),
                              keyEquivalent: "")
        item.target = target
        item.representedObject = job.rawValue
        item.state = CardWatch.isOn(job) ? .on : .off
        item.toolTip = job.explanation
        cardsMenu.addItem(item)
    }
    cardsMenuItem.submenu = cardsMenu
    mainMenu.addItem(cardsMenuItem)

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
    mainMenu.addItem(helpMenuItem)

    return mainMenu
}

let application = NSApplication.shared

// Before anything is built or shown. A second copy that got as far as opening a
// window would already have read the transfer log it is about to overwrite.
guard SingleInstance.claim() else { exit(0) }

let appDelegate = AppDelegate()
application.setActivationPolicy(.regular)
application.mainMenu = buildMainMenu(target: appDelegate)
application.delegate = appDelegate
application.run()
