import AppKit
import ApplicationServices

/// Shows a small Rephrase icon in the corner of whichever text box you're typing in.
/// Clicking it opens the rewrite popup. Polls the focused element a few times a second.
@MainActor
final class BadgeController {
    static let defaultsKey = "showBadge"
    static let size: CGFloat = 22

    /// Apps where the icon would be noise or where text is sensitive.
    private static let excludedApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
        "com.apple.loginwindow", "com.apple.SecurityAgent",
    ]

    /// Apps that hide their text boxes from Accessibility entirely. Here the icon follows your
    /// typing instead, and capture uses ⌘A. Kept to a list so terminals etc. never get ⌘A.
    private static let typingFallbackApps: Set<String> = ["us.zoom.xos"]

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            if !newValue { hide() }
        }
    }

    /// Asked before showing, so the icon stays hidden while the popup is open.
    var shouldShow: () -> Bool = { true }

    private let panel: NSPanel
    private var timer: Timer?
    private var visible = false

    // Dragging: the icon's offset from its default spot is remembered per app.
    private static let offsetsKey = "badgeOffsets"
    private var isDragging = false
    private var lastDefaultOrigin: NSPoint?
    private var lastAppID: String?

    init(onClick: @escaping () -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = BadgeView(onClick: onClick)
        panel.contentView = view
        view.onDragBegan = { [weak self] in self?.isDragging = true }
        view.onDragEnded = { [weak self] origin in self?.dragEnded(at: origin) }

        // Keep AX calls snappy even if an app is busy (default timeout is ~6 s).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)

        // Only *when* you type and *where* you click are recorded, never which keys.
        // Used for apps like Zoom that hide their text boxes from Accessibility.
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection([.command, .control])
            guard mods.isEmpty, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.lastTyped = (Date(), pid) }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.lastClick = (Date(), point) }
        }
    }

    private var lastTyped: (date: Date, pid: pid_t)?
    private var lastClick: (date: Date, point: NSPoint)?

    /// Where you clicked before typing in the front app (Accessibility coordinates), used to find
    /// the chat above a message box the app hides. Nil if you haven't typed there recently.
    var typingPoint: CGPoint? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let lastTyped, lastTyped.pid == front.processIdentifier,
              Date().timeIntervalSince(lastTyped.date) < 300,
              let lastClick, lastClick.date < lastTyped.date else { return nil }
        return TextAccess.flip(lastClick.point)
    }

    /// You've typed in the front app recently and haven't clicked elsewhere since.
    var isTypingInFrontApp: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              Self.typingFallbackApps.contains(front.bundleIdentifier ?? ""),
              let lastTyped, Date().timeIntervalSince(lastTyped.date) < 30,
              lastTyped.pid == front.processIdentifier else { return false }
        return lastClick.map { lastTyped.date > $0.date } ?? true
    }

    private func offset(for appID: String) -> CGVector {
        let all = UserDefaults.standard.dictionary(forKey: Self.offsetsKey) as? [String: [Double]] ?? [:]
        guard let v = all[appID], v.count == 2 else { return .zero }
        return CGVector(dx: v[0], dy: v[1])
    }

    private func dragEnded(at origin: NSPoint) {
        isDragging = false
        guard let base = lastDefaultOrigin, let appID = lastAppID else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.offsetsKey) as? [String: [Double]] ?? [:]
        all[appID] = [origin.x - base.x, origin.y - base.y]
        UserDefaults.standard.set(all, forKey: Self.offsetsKey)
        Log.write("badge: moved for \(appID) by \(Int(origin.x - base.x)),\(Int(origin.y - base.y))")
    }

    /// Puts the icon back in its default spot in every app.
    func resetPositions() {
        UserDefaults.standard.removeObject(forKey: Self.offsetsKey)
    }

    func hide() {
        guard visible else { return }
        panel.orderOut(nil)
        visible = false
    }

    private var lastLogged = ""

    /// Logs only when the badge's situation changes, so the log stays readable.
    private func note(_ state: String) {
        guard state != lastLogged else { return }
        lastLogged = state
        Log.write("badge: \(state)")
    }

    private func tick() {
        guard !isDragging else { return }
        let app = NSWorkspace.shared.frontmostApplication
        let appID = app?.bundleIdentifier ?? "?"
        guard isEnabled else { note("disabled in menu"); return hide() }
        guard shouldShow() else { return hide() }
        guard AXIsProcessTrusted() else { note("not trusted"); return hide() }
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !Self.excludedApps.contains(appID)
        else { note("skipped app \(appID)"); return hide() }

        // In chat apps the icon shows in an empty message box too, for drafting a reply.
        let (frame, reason, hidden) = TextAccess.focusedTextField(allowEmpty: ConversationReader.isChatApp(appID))
        let s = Self.size
        let origin: NSPoint
        if let field = frame {
            note("\(appID): showing at \(Int(field.maxX)),\(Int(field.minY)) (\(reason))")
            origin = field.height < 34
                // Single-line field: just outside its right edge, vertically centred.
                ? NSPoint(x: field.maxX + 4, y: field.midY - s / 2)
                // Multi-line box: inside the bottom-right corner, like Grammarly.
                : NSPoint(x: field.maxX - s - 6, y: field.minY + 6)
        } else if hidden, isTypingInFrontApp, let click = lastClick {
            // The app hides its text box: put the icon just above where you clicked to type.
            note("\(appID): showing near click (\(reason), typing detected)")
            origin = NSPoint(x: click.point.x - s / 2, y: click.point.y + 14)
        } else {
            note("\(appID): \(reason)")
            return hide()
        }

        lastDefaultOrigin = origin
        lastAppID = appID
        let moved = offset(for: appID)
        let finalOrigin = NSPoint(x: origin.x + moved.dx, y: origin.y + moved.dy)
        if panel.frame.origin != finalOrigin { panel.setFrameOrigin(finalOrigin) }
        if !visible {
            panel.orderFrontRegardless()
            visible = true
        }
    }
}

/// The round icon. Handles the click itself so it works without the panel becoming key.
/// Quick click opens the popup; press-and-hold (or just drag) moves it.
private final class BadgeView: NSView {
    private let onClick: () -> Void
    var onDragBegan: () -> Void = {}
    var onDragEnded: (NSPoint) -> Void = { _ in }
    private var hovering = false { didSet { needsDisplay = true } }
    private var lifted = false { didSet { needsDisplay = true } }

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: BadgeController.size, height: BadgeController.size))
        toolTip = "Rephrase (⌃⌥R) — click to rewrite or draft a reply, hold and drag to move"
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        let downAt = Date()
        var dragging = false

        // Track the mouse until release: a hold (0.3 s) or any real movement turns it into a drag.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true),
              next.type != .leftMouseUp {
            let p = NSEvent.mouseLocation
            let movedFar = hypot(p.x - start.x, p.y - start.y) > 6
            let heldLong = Date().timeIntervalSince(downAt) >= 0.3
            if !dragging, movedFar || (heldLong && hypot(p.x - start.x, p.y - start.y) > 1) {
                dragging = true
                lifted = true
                onDragBegan()
            }
            if dragging {
                window.setFrameOrigin(NSPoint(x: startOrigin.x + p.x - start.x, y: startOrigin.y + p.y - start.y))
            }
        }

        if dragging {
            lifted = false
            onDragEnded(window.frame.origin)
        } else if Date().timeIntervalSince(downAt) < 0.5 {
            onClick()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        let alpha: CGFloat = lifted ? 0.6 : (hovering ? 1 : 0.88)
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
        circle.fill()

        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let icon = NSImage(systemSymbolName: "wand.and.sparkles", accessibilityDescription: "Rephrase")?
            .withSymbolConfiguration(config) {
            let r = NSRect(x: (bounds.width - icon.size.width) / 2, y: (bounds.height - icon.size.height) / 2,
                           width: icon.size.width, height: icon.size.height)
            icon.draw(in: r)
        }
    }
}
