import Cocoa

/// Carries a closure for a button, since NSButton takes a selector and these are
/// built from data rather than wired up one by one.
final class ButtonAction: NSObject {
    static let shared = ButtonAction()
    private var actions: [ObjectIdentifier: () -> Void] = [:]

    func attach(_ run: @escaping () -> Void, to button: NSButton) {
        actions[ObjectIdentifier(button)] = run
    }

    @objc func fire(_ sender: NSButton) {
        actions[ObjectIdentifier(sender)]?()
    }
}

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

    /// One instruction, and where possible the button that carries it out.
    ///
    /// Prose was telling people to go and do four things in order - open the app, let
    /// it be refused, find a pane in System Settings, scroll to a section - and a
    /// paragraph is the wrong shape for that. A numbered list says how many steps
    /// there are and where you have got to, and any step the app can perform itself
    /// should be a button rather than a description of one.
    struct Step {
        let text: String
        var button: (title: String, run: () -> Void)?
    }

    private struct Page {
        let title: String
        let body: String
        /// Numbered instructions, shown under the body.
        var steps: [Step] = []
        /// Shown under the steps when there is something to report about the machine.
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
    private let stepsStack = NSStackView()

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
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

    /// Five pages, not eight.
    ///
    /// Three of them check something that looks exactly like the app being broken - a
    /// copy left in Downloads, a quarantine flag, a permission never granted - and can
    /// fix it. One says what the app is, one explains the mark, and that is the lot.
    /// The pages this replaced described how to sort a list and drag a row, which is
    /// a manual rather than a setup, and is discoverable by doing it.
    private func buildPages() {
        pages = [
            Page(title: "What Bottleneck shows you",
                 body: "Read and write rates per device, and a session history with a "
                     + "reading of what limited each transfer.\n\n"
                     + "It makes no network connections. The speed catalogue it "
                     + "compares against ships inside the app."),

            Page(title: "Where Bottleneck is installed",
                 body: "macOS restricts an app still sitting in Downloads, and refuses "
                     + "one running from a disk image.",
                 status: {
                     switch Setup.installState {
                     case .installed:
                         return .good("Installed in Applications.")
                     case .translocated:
                         return .problem("Running from a read-only or quarantined copy. "
                                         + "Settings will not stick until it is moved.")
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
                 body: "Bottleneck is signed ad-hoc, not notarised, so a downloaded "
                     + "copy is refused by macOS. A build from source is not.",
                 steps: [
                    Step(text: "Open Bottleneck and let macOS refuse it."),
                    Step(text: "Go to Privacy & Security, then Security.",
                         button: ("Open Privacy & Security", { Setup.openSecuritySettings() })),
                    Step(text: "Press \u{201C}Open Anyway\u{201D}. It is withdrawn after a "
                             + "while - if it is missing, open the app again."),
                    Step(text: "Or clear the flag in Terminal. Control-click \u{25B8} Open "
                             + "no longer works.",
                         button: ("Copy Terminal command", {
                             NSPasteboard.general.clearContents()
                             NSPasteboard.general.setString(
                                "xattr -dr com.apple.quarantine Bottleneck.app",
                                forType: .string)
                         })),
                 ],
                 status: {
                     Setup.isQuarantined
                         ? .problem("This copy is still quarantined.")
                         : .good("No quarantine flag on this copy.")
                 }),

            Page(title: "Removable volumes (optional)",
                 body: "Only one feature needs this: stopping Spotlight indexing a "
                     + "card, which writes a marker file to it. Everything else works "
                     + "without it.",
                 steps: [
                    Step(text: "Attach a card. With nothing attached there is nothing "
                             + "to ask about."),
                    Step(text: "Answer Allow to the macOS prompt.",
                         button: ("Ask macOS Now", {
                             SetupWindowController.askForRemovableAccess()
                         })),
                    Step(text: "Refused before? macOS will not ask twice.",
                         button: ("Open Privacy Settings", {
                             Setup.openRemovablePrivacySettings()
                         })),
                    Step(text: "Granted while running? Restart Bottleneck."),
                 ],
                 status: {
                     switch Setup.removableAccess {
                     case .granted:
                         return .good("Bottleneck can read the attached card.")
                     case .denied:
                         return .problem("Access refused. Grant it, then restart.")
                     case .untested:
                         return .unknown("Nothing removable attached, so this could "
                                         + "not be checked.")
                     }
                 }),

            Page(title: "Measured, and worked out",
                 body: "Most of this window is measured: bytes moved, how full a volume "
                     + "is, the rate a link negotiated.\n\n"
                     + "The rest is worked out by comparing those against a catalogue "
                     + "of what hardware normally does. It carries \u{2248} and is drawn "
                     + "in violet. A match is not a proof.",
                 steps: [
                    Step(text: "Hover a row: the card says what each conclusion was "
                             + "drawn from."),
                    Step(text: "Click a row to keep that card open."),
                    Step(text: "The key lists every color, and every reading that is "
                             + "not a measurement.",
                         button: ("Open Color Key", { LegendWindow.show(.colors) })),
                 ]),
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

        stepsStack.orientation = .vertical
        stepsStack.alignment = .leading
        stepsStack.spacing = 10

        for view in [titleLabel, bodyLabel, statusLabel, actionButton,
                     recheckButton, backButton, nextButton, stepLabel, stepsStack] {
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

            stepsStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stepsStack.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            stepsStack.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 14),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: stepsStack.bottomAnchor, constant: 16),

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

        rebuildSteps(page.steps)

        if let action = page.action {
            actionButton.title = action.title
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
        recheckButton.isHidden = page.status == nil
        refreshStatus()
    }

    /// Triggers macOS's own permission prompt by attempting the thing it guards, and
    /// says plainly what came back - including the case where nothing is attached, in
    /// which case macOS has nothing to ask about and stays silent.
    static func askForRemovableAccess() {
        let alert = NSAlert()
        switch Setup.requestRemovableAccess() {
        case .granted:
            alert.messageText = "Access granted"
            alert.informativeText = "Bottleneck can read the attached removable volume."
        case .denied:
            alert.messageText = "macOS refused"
            alert.informativeText = "Either the prompt was answered with Don\u{2019}t "
                + "Allow, or it was answered that way before. macOS will not ask twice: "
                + "turn Bottleneck on under Privacy & Security \u{25B8} Files and "
                + "Folders \u{25B8} Removable Volumes, then restart Bottleneck."
        case .untested:
            alert.messageText = "Nothing attached to ask about"
            alert.informativeText = "Insert a card or plug in a removable drive, then "
                + "press Ask macOS Now again. The prompt only appears when there is a "
                + "volume for it to be about."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// One row per step: a numbered chip, the instruction, and the button that does
    /// it where there is one.
    private func rebuildSteps(_ steps: [Step]) {
        for view in stepsStack.arrangedSubviews {
            stepsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        stepsStack.isHidden = steps.isEmpty
        for (number, step) in steps.enumerated() {
            stepsStack.addArrangedSubview(SetupWindowController.stepRow(number: number + 1,
                                                                        step: step))
        }
    }

    private static func stepRow(number: Int, step: Step) -> NSView {
        let chip = NSTextField(labelWithString: "\(number)")
        chip.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        chip.alignment = .center
        chip.textColor = .white
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        chip.layer?.cornerRadius = 9
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.widthAnchor.constraint(equalToConstant: 18).isActive = true
        chip.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(wrappingLabelWithString: step.text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [chip, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8

        guard let button = step.button else { return row }
        // The button sits under its own step rather than beside it: at this width a
        // button on the same line pushed the text into two or three ragged lines.
        let action = NSButton(title: button.title, target: nil, action: nil)
        action.bezelStyle = .rounded
        action.controlSize = .small
        action.target = ButtonAction.shared
        action.action = #selector(ButtonAction.fire(_:))
        ButtonAction.shared.attach(button.run, to: action)

        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let buttonRow = NSStackView(views: [indent, action])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 0

        let group = NSStackView(views: [row, buttonRow])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        return group
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
