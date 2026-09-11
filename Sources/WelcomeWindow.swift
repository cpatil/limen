import Cocoa

/// The setup and tour window.
///
/// One window, a handful of pages, and every page that asks you to do something also
/// checks whether it is done. The "Check again" buttons matter more than the prose:
/// they turn "I followed the instructions, I think" into a plain yes or no.
final class SetupWindowController: NSWindowController {

    /// What a page found when it looked. "Unknown" is a first-class answer: a green
    /// tick for a check that could not run claims something that was never verified.
    enum Finding {
        case good(String)
        case problem(String)
        case unknown(String)

        var text: String {
            switch self {
            case .good(let t), .problem(let t), .unknown(let t): return t
            }
        }
        var mark: String {
            switch self {
            case .good: return "✓  "
            case .problem: return "!  "
            case .unknown: return "–  "
            }
        }
        var colour: NSColor {
            switch self {
            case .good: return .systemGreen
            case .problem: return .systemOrange
            case .unknown: return .secondaryLabelColor
            }
        }
        /// Only a solved problem should stop offering its fix.
        var settled: Bool { if case .good = self { return true }; return false }
    }

    private struct Page {
        let title: String
        let body: String
        /// Shown under the body when there is something to report about the machine.
        var status: (() -> Finding)?
        /// A button that does the thing the page is about.
        var action: (title: String, run: (SetupWindowController) -> Void)?
    }

    private var pages: [Page] = []
    private var index = 0

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let recheckButton = NSButton(title: "Check again", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let stepLabel = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 380),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Bottleneck Setup"
        window.center()
        self.init(window: window)
        buildPages()
        buildLayout()
        show(page: 0)
    }

    // ---- content ---------------------------------------------------------

    private func buildPages() {
        pages = [
            Page(title: "What Bottleneck shows you",
                 body: "Live read and write rates for every storage device and network "
                     + "interface, and a log of finished transfers with a note about "
                     + "what limited each one.\n\n"
                     + "It makes no network connections of any kind. The speed "
                     + "catalogue it compares against ships inside the app and is only "
                     + "updated when you ask it to."),

            Page(title: "Where Bottleneck is installed",
                 body: "macOS restricts an app that is still sitting in Downloads, and "
                     + "refuses one running from a disk image outright. Moving it to "
                     + "Applications avoids both.",
                 status: {
                     switch Setup.installState {
                     case .installed:
                         return .good("Installed in Applications.")
                     case .translocated:
                         return .problem("Running from a read-only or quarantined copy. "
                                         + "Settings and permissions will not stick "
                                         + "until this is moved.")
                     case .elsewhere(let where_):
                         return .unknown("Running from \(where_). This works, but "
                                         + "Applications is the safer home.")
                     }
                 },
                 action: ("Move to Applications and Restart", { controller in
                     if let problem = Setup.installToApplications() {
                         controller.report("Could not move it: \(problem)")
                     }
                 })),

            Page(title: "Gatekeeper",
                 body: "Bottleneck is signed ad-hoc rather than notarised, so a downloaded "
                     + "copy carries a quarantine flag and macOS will refuse to open "
                     + "it. Building from source avoids this entirely.\n\n"
                     + "Without the Terminal: double-click the app, let macOS block "
                     + "it, then open System Settings \u{25B8} Privacy & Security, "
                     + "scroll to Security, and press Open Anyway beside Bottleneck. "
                     + "The button only appears after a blocked attempt, and not "
                     + "indefinitely afterwards. Control-clicking the app and choosing "
                     + "Open no longer works: macOS Sequoia removed that route.\n\n"
                     + "Or in the Terminal, which clears the flag outright:\n"
                     + "    xattr -dr com.apple.quarantine Bottleneck.app",
                 status: {
                     Setup.isQuarantined
                         ? .problem("This copy is still quarantined.")
                         : .good("No quarantine flag on this copy.")
                 },
                 action: ("Open Privacy & Security", { _ in
                     Setup.openSecuritySettings()
                 })),

            Page(title: "Removable volumes (optional)",
                 body: "Everything Bottleneck measures works without any permission at all.\n\n"
                     + "One feature needs this one: turning off Spotlight indexing for "
                     + "a card, which writes a small marker file to it. macOS asks "
                     + "before an app may touch a removable volume. If you grant it "
                     + "while Bottleneck is running, restart Bottleneck afterwards - some "
                     + "privileges only reach a freshly launched process.",
                 status: {
                     switch Setup.removableAccess {
                     case .granted:
                         return .good("Bottleneck can read the card that is attached.")
                     case .denied:
                         return .problem("Access is being refused. Grant it below, "
                                         + "then restart Bottleneck.")
                     case .untested:
                         return .unknown("No card or removable drive attached, so this "
                                         + "could not be checked. Attach one and press "
                                         + "Check again, or grant it in advance below.")
                     }
                 },
                 action: ("Open Privacy Settings", { _ in
                     Setup.openRemovablePrivacySettings()
                 })),

            Page(title: "Reading a row",
                 body: "Each row is one device.\n\n"
                     + "The badges name what it is - the card in a reader, then the "
                     + "link it is reached over. The bar under the chart is how much of "
                     + "that link is in use, or of the device's own best where the link "
                     + "cannot be trusted.\n\n"
                     + "Hover anything to enlarge it. The card that appears carries the "
                     + "full text of whatever the row had to shorten."),

            Page(title: "Measured, and worked out",
                 body: "Two kinds of statement share this window, and they are not "
                     + "equally certain.\n\n"
                     + "Most of it is measured: bytes moved, how full a volume is, the "
                     + "rate a link negotiated, which processes hold a file open.\n\n"
                     + "The rest is worked out by comparing those measurements against "
                     + "a catalogue of what hardware normally does - what kind of card "
                     + "is in the reader, what held a transfer back, what would help. "
                     + "Those carry a \u{2248} and are drawn in violet. Hovering a row "
                     + "brings up its card, which says what each one was concluded "
                     + "from; clicking a row keeps that card open until you close it. "
                     + "A match is not a proof, and the mark is there so you can weigh "
                     + "it yourself.\n\n"
                     + "Color key in the toolbar opens the key itself - what each "
                     + "color means, and which statements are not measurements."),

            Page(title: "Arranging the lists",
                 body: "Each section sorts on its own, from the popup in its heading.\n\n"
                     + "Active first is worked out once and then held, so rows do not "
                     + "swap places while you are reading them. The ⟳ beside the popup "
                     + "asks for it to be reconsidered.\n\n"
                     + "Drag a row by the handle on its left to put the lists in "
                     + "whatever order you like. That order is remembered."),

            Page(title: "The transfer log",
                 body: "Finished copies are collected under the device that made them, "
                     + "with what was measured and what might explain it.\n\n"
                     + "Click a heading to fold it away. Right-click for options, "
                     + "including forgetting one device or clearing the log.\n\n"
                     + "The log lives in your Application Support folder and never "
                     + "leaves the machine."),
        ]
    }

    // ---- layout ----------------------------------------------------------

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        titleLabel.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        bodyLabel.font = NSFont.systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        stepLabel.font = NSFont.systemFont(ofSize: 11)
        stepLabel.textColor = .tertiaryLabelColor

        for button in [actionButton, recheckButton, backButton, nextButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        actionButton.action = #selector(runAction)
        recheckButton.action = #selector(refreshStatus)
        backButton.action = #selector(goBack)
        nextButton.action = #selector(goNext)
        nextButton.keyEquivalent = "\r"

        for view in [titleLabel, bodyLabel, statusLabel, actionButton,
                     recheckButton, backButton, nextButton, stepLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        let margin: CGFloat = 28
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),

            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 18),

            actionButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            actionButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            recheckButton.leadingAnchor.constraint(equalTo: actionButton.trailingAnchor, constant: 10),
            recheckButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),

            stepLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stepLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
            nextButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            nextButton.bottomAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 4),
            backButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -10),
            backButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
        ])
    }

    // ---- paging ----------------------------------------------------------

    /// Jumps to one page. Exposed so a page can be rendered on its own and checked
    /// for fit without clicking through the window.
    func goToPageForRendering(_ number: Int) { show(page: number) }

    private func show(page number: Int) {
        index = min(max(0, number), pages.count - 1)
        let page = pages[index]
        titleLabel.stringValue = page.title
        bodyLabel.stringValue = page.body
        stepLabel.stringValue = "Step \(index + 1) of \(pages.count)"
        backButton.isHidden = index == 0
        nextButton.title = index == pages.count - 1 ? "Done" : "Next"

        if let action = page.action {
            actionButton.title = action.title
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
        recheckButton.isHidden = page.status == nil
        refreshStatus()
    }

    @objc private func refreshStatus() {
        guard let status = pages[index].status else {
            statusLabel.stringValue = ""
            return
        }
        let finding = status()
        statusLabel.stringValue = finding.mark + finding.text
        statusLabel.textColor = finding.colour
        actionButton.isEnabled = !finding.settled
    }

    @objc private func runAction() { pages[index].action?.run(self) }

    @objc private func goBack() { show(page: index - 1) }

    @objc private func goNext() {
        if index == pages.count - 1 {
            Setup.markSeen()
            window?.close()
        } else {
            show(page: index + 1)
        }
    }

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshStatus()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
