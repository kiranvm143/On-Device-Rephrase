import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let popup = PopupController()
    private var accessItem: NSMenuItem!
    private var screenItem: NSMenuItem!
    private var badgeItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private lazy var badge = BadgeController { [weak self] in self?.trigger() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "Rephrase")

        let menu = NSMenu()
        menu.addItem(withTitle: "Rephrase or Reply  (⌃⌥R)", action: #selector(trigger), keyEquivalent: "").target = self
        badgeItem = menu.addItem(withTitle: "Show Icon in Text Boxes", action: #selector(toggleBadge), keyEquivalent: "")
        badgeItem.target = self
        menu.addItem(withTitle: "Reset Icon Positions", action: #selector(resetBadgePositions), keyEquivalent: "").target = self
        loginItem = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(.separator())
        accessItem = menu.addItem(withTitle: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessItem.target = self
        screenItem = menu.addItem(withTitle: "", action: #selector(openScreenSettings), keyEquivalent: "")
        screenItem.target = self
        let engineMenu = NSMenu()
        for kind in EngineKind.allCases {
            let item = engineMenu.addItem(withTitle: kind.title, action: #selector(chooseEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
        }
        engineMenu.delegate = self
        menu.addItem(withTitle: "Engine", action: nil, keyEquivalent: "").submenu = engineMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Rephrase", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
        refreshAccessItem()

        // Asks macOS to show the Accessibility prompt the first time.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        hotKey = HotKey(keyCode: 15 /* R */, modifiers: [.control, .option]) { [weak self] in
            self?.trigger()
        }
        Log.write("launch: trusted=\(AXIsProcessTrusted()) hotkeyRegistered=\(hotKey?.isRegistered ?? false) path=\(Bundle.main.bundlePath)")

        RewriteEngine.shared.prewarm()

        badge.shouldShow = { [weak self] in self?.popup.isShowing == false }
        badge.start()

        EngineSetup.shared.onReady = { [weak self] kind in self?.popup.engineReady(kind) }

        LoginItem.enableOnFirstRun()

        // `--demo`: show the popup with sample text, without touching other apps.
        // `--demo <dir>` also saves PNGs of the Fix and Professional views into <dir>.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo") {
            let frame = NSScreen.main?.visibleFrame ?? .zero
            popup.show(for: CapturedText(
                text: "hey can u send me the report by tommorow, i has a client call and we needs it",
                wholeField: false,
                anchor: NSRect(x: frame.midX - 230, y: frame.midY + 140, width: 1, height: 20),
                app: nil))
            if i + 1 < args.count {
                let dir = URL(fileURLWithPath: args[i + 1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    self.popup.snapshot(to: dir.appendingPathComponent("popup-fix.png"))
                    self.popup.select(.professional)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.popup.snapshot(to: dir.appendingPathComponent("popup-professional.png"))
                        self.showReplyDemo(saveTo: dir)
                    }
                }
            }
        }
    }

    /// `--demo`: a reply drafted from a sample conversation, as if you had selected it.
    private func showReplyDemo(saveTo dir: URL) {
        let frame = NSScreen.main?.visibleFrame ?? .zero
        var captured = CapturedText(
            text: """
                  Priya Shah  10:02 AM
                  Hi! Are we still on for the design review tomorrow?
                  Priya Shah  10:03 AM
                  Also, could you share the latest mockups before then?
                  """,
            wholeField: false,
            anchor: NSRect(x: frame.midX - 230, y: frame.midY + 140, width: 1, height: 20),
            app: nil)
        captured.editable = false
        popup.show(for: captured, startWith: .reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.popup.snapshot(to: dir.appendingPathComponent("popup-reply.png"))
        }
    }

    @objc private func toggleBadge() {
        badge.isEnabled.toggle()
    }

    @objc private func resetBadgePositions() {
        badge.resetPositions()
    }

    @objc private func toggleLoginItem() {
        LoginItem.set(!LoginItem.isEnabled)
    }

    @objc private func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = EngineKind(rawValue: raw) else { return }
        RewriteEngine.shared.kind = kind
        Log.write("engine: \(kind.rawValue)")
    }

    @objc func trigger() {
        badge.hide()
        let front = NSWorkspace.shared.frontmostApplication
        Log.write("hotkey: front=\(front?.bundleIdentifier ?? "?") trusted=\(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else {
            popup.showMessage("Rephrase needs Accessibility permission. Turn it on in the Settings window that just opened, then press ⌃⌥R again.")
            openAccessibilitySettings()
            return
        }
        // Text to rewrite; or else an empty message box to draft a reply into.
        let chatApp = ConversationReader.isChatApp(front?.bundleIdentifier)
        guard var captured = TextAccess.captureSelection(selectAllIfEmpty: badge.isTypingInFrontApp)
                ?? TextAccess.replyTarget(chatApp: chatApp) else {
            Log.write("capture: nothing found")
            popup.showMessage("No text found. Select some text (or click into a text box) and press ⌃⌥R again.")
            return
        }
        captured.typingPoint = badge.typingPoint
        Log.write("capture: ok chars=\(captured.text.count) wholeField=\(captured.wholeField) editable=\(captured.editable) chatApp=\(chatApp)")
        // Messages selected in a chat app: you most likely want to answer them.
        popup.show(for: captured, startWith: captured.isConversation && chatApp ? .reply : .fix)
    }

    @objc private func openScreenSettings() {
        ConversationReader.requestScreenAccess()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func refreshAccessItem() {
        badgeItem.state = badge.isEnabled ? .on : .off
        loginItem.state = LoginItem.isEnabled ? .on : .off
        loginItem.isEnabled = LoginItem.isInstalledCopy
        accessItem.title = AXIsProcessTrusted()
            ? "Accessibility: allowed ✓"
            : "Accessibility: not allowed — click to open Settings"
        // Only needed for replies in apps that hide their messages (Zoom), so it's optional.
        screenItem.title = ConversationReader.hasScreenAccess
            ? "Screen reading for replies: allowed ✓"
            : "Screen reading for replies (Zoom): off — click to allow"
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshAccessItem()
        let current = RewriteEngine.shared.kind.rawValue
        for item in menu.items where item.action == #selector(chooseEngine(_:)) {
            item.state = (item.representedObject as? String) == current ? .on : .off
        }
    }
}
