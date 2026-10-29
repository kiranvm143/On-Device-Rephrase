import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// The recent messages a reply is drafted from.
struct Conversation {
    enum Source { case accessibility, screen, selection }

    let text: String
    let source: Source

    var lineCount: Int { text.split(separator: "\n").count }

    var sourceLabel: String {
        switch source {
        case .accessibility: "read from the window"
        case .screen: "read from the screen"
        case .selection: "you selected"
        }
    }
}

enum ConversationError: LocalizedError {
    /// The app hides its messages from Accessibility and Screen Recording isn't allowed yet.
    case needsScreenAccess
    case nothingFound

    var errorDescription: String? {
        switch self {
        case .needsScreenAccess: "Rephrase needs permission to read the screen."
        case .nothingFound:
            "Couldn't find any messages above the text box. Select the messages you want to reply to, then press ⌃⌥R and choose Reply."
        }
    }
}

/// Reads the messages on screen above the text box you're typing in, so a reply can be drafted.
/// Accessibility first (Teams, Slack, Messages, browsers...). Apps that hide their chat from it,
/// like Zoom, are read from the window's pixels with Apple's on-device text recognition, which
/// needs Screen Recording permission. Nothing leaves this Mac and nothing is saved.
enum ConversationReader {
    /// Only the most recent part is kept: enough for a reply, and fits the on-device model.
    static let maxChars = 4000

    /// Chat apps: the ✨ icon also shows in their empty message box, and replying is the default there.
    static let chatApps: Set<String> = [
        "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap", "us.zoom.xos",
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.hnc.Discord",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.facebook.archon", "com.google.Chat",
    ]

    static func isChatApp(_ bundleID: String?) -> Bool { chatApps.contains(bundleID ?? "") }

    static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows macOS's Screen Recording prompt (first time) and opens its Settings page.
    static func requestScreenAccess() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// `input`: the message box's frame, `typingPoint`: where you clicked to type (for apps that
    /// hide the box). Both in Accessibility coordinates (top-left origin).
    static func read(pid: pid_t, input: CGRect?, typingPoint: CGPoint?) async throws -> Conversation {
        let start = Date()
        let ax = await Task.detached { readAccessibility(pid: pid, input: input, typingPoint: typingPoint) }.value
        if let ax, ax.count >= 40 {
            Log.write(String(format: "reply: read %d chars via accessibility in %.2fs", ax.count, Date().timeIntervalSince(start)))
            return Conversation(text: ax, source: .accessibility)
        }
        Log.write("reply: accessibility found \(ax?.count ?? 0) chars, trying screen text (allowed=\(hasScreenAccess))")
        guard hasScreenAccess else { throw ConversationError.needsScreenAccess }
        let text = try await readScreen(pid: pid, input: input, typingPoint: typingPoint)
        Log.write(String(format: "reply: read %d chars via screen text in %.2fs", text.count, Date().timeIntervalSince(start)))
        guard text.count >= 15 else { throw ConversationError.nothingFound }
        return Conversation(text: text, source: .screen)
    }

    /// The part of the window where messages are: above the text box, in its column.
    private static func messageArea(window: CGRect, input: CGRect?, typingPoint: CGPoint?) -> CGRect {
        if let input, input.width > 0 {
            let minX = max(window.minX, input.minX - 80)
            let maxX = min(window.maxX, input.maxX + 20)
            return CGRect(x: minX, y: window.minY, width: maxX - minX, height: max(0, input.minY - window.minY))
        }
        if let p = typingPoint, window.contains(p) {
            // Box position unknown (Zoom): the column around where you clicked to type.
            let minX = max(window.minX, p.x - 380)
            let maxX = min(window.maxX, p.x + 380)
            return CGRect(x: minX, y: window.minY, width: maxX - minX, height: max(0, p.y - 8 - window.minY))
        }
        return window
    }

    // MARK: - Accessibility

    private static let skippedRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXToolbar",
        "AXMenuBar", "AXMenu", "AXScrollBar", "AXImage", "AXSlider", "AXIncrementor",
    ]

    private struct Node {
        var role = ""
        var frame: CGRect?
        var value: String?
        var children: [AXUIElement] = []
    }

    private static func node(_ el: AXUIElement) -> Node {
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXValueAttribute, kAXChildrenAttribute]
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [AnyObject], values.count == names.count else { return Node() }
        var n = Node()
        n.role = values[0] as? String ?? ""
        var pos = CGPoint.zero, size = CGSize.zero
        if CFGetTypeID(values[1]) == AXValueGetTypeID(), CFGetTypeID(values[2]) == AXValueGetTypeID(),
           AXValueGetValue(values[1] as! AXValue, .cgPoint, &pos), AXValueGetValue(values[2] as! AXValue, .cgSize, &size) {
            n.frame = CGRect(origin: pos, size: size)
        }
        n.value = values[3] as? String
        n.children = values[4] as? [AXUIElement] ?? []
        return n
    }

    private static func readAccessibility(pid: pid_t, input: CGRect?, typingPoint: CGPoint?) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        // The window holding the message box, else the focused one.
        let windows: [AXUIElement] = TextAccess.copyAttribute(app, kAXWindowsAttribute) ?? []
        let holding = input.flatMap { box in
            windows.first { node($0).frame?.contains(CGPoint(x: box.midX, y: box.midY)) == true }
        }
        guard let window = holding ?? TextAccess.copyAttribute(app, kAXFocusedWindowAttribute)
                ?? TextAccess.copyAttribute(app, kAXMainWindowAttribute),
              let windowFrame = node(window).frame else { return nil }
        let area = messageArea(window: windowFrame, input: input, typingPoint: typingPoint)

        // Walk from the bottom up (newest messages first) and stop once there's enough text.
        var found: [(text: String, frame: CGRect)] = []
        var chars = 0, visited = 0
        let deadline = Date().addingTimeInterval(1.5)

        func visit(_ el: AXUIElement, depth: Int) {
            guard depth < 80, visited < 6000, chars < maxChars, Date() < deadline else { return }
            visited += 1
            let n = node(el)
            if let f = n.frame, f.width > 0, f.height > 0, !f.intersects(area) { return }   // other panes, off screen
            guard !skippedRoles.contains(n.role) else { return }
            if n.role == kAXStaticTextRole || n.role == kAXTextAreaRole || n.role == kAXTextFieldRole {
                var editable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &editable)
                // Skip the message box itself (your draft); keep read-only text inside the message area.
                // Text scrolled out of view is reported as a 1-pixel strip at the list's edge: skip it too.
                if !editable.boolValue, let text = n.value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                   let f = n.frame, f.height >= 4, f.midY > area.minY, f.midY < area.maxY {
                    found.append((text, f))
                    chars += text.count
                    return
                }
                if editable.boolValue { return }
            }
            for child in n.children.reversed() { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        return joinLines(found.reversed())
    }

    // MARK: - Screen text (Vision)

    private static func readScreen(pid: pid_t, input: CGRect?, typingPoint: CGPoint?) async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        // The app's front-most normal window (the window list is ordered front to back).
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let frontID = infos.first {
            ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }?[kCGWindowNumber as String] as? Int
        guard let window = content.windows.first(where: { Int($0.windowID) == frontID })
                ?? content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
        else { throw ConversationError.nothingFound }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let frame = window.frame
        return try await recognizeText(in: image, windowFrame: frame,
                                       area: messageArea(window: frame, input: input, typingPoint: typingPoint))
    }

    /// Text in `area` of a window image, top to bottom. Frames are in screen points (top-left origin).
    static func recognizeText(in image: CGImage, windowFrame frame: CGRect, area: CGRect) async throws -> String {
        try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let pieces: [(text: String, frame: CGRect)] = (request.results ?? []).compactMap { obs in
                guard let best = obs.topCandidates(1).first, best.confidence > 0.3 else { return nil }
                let b = obs.boundingBox   // normalised, bottom-left origin
                let f = CGRect(x: frame.minX + b.minX * frame.width, y: frame.minY + (1 - b.maxY) * frame.height,
                               width: b.width * frame.width, height: b.height * frame.height)
                guard f.midY < area.maxY, f.maxX > area.minX, f.minX < area.maxX else { return nil }
                return (best.string, f)
            }
            // Top to bottom, then left to right within a row.
            let sorted = pieces.sorted { abs($0.frame.midY - $1.frame.midY) < min($0.frame.height, $1.frame.height) / 2
                ? $0.frame.minX < $1.frame.minX : $0.frame.midY < $1.frame.midY }
            return joinLines(sorted) ?? ""
        }.value
    }

    /// Joins pieces on the same row with spaces and rows with newlines, keeping the newest `maxChars`.
    private static func joinLines<S: Sequence>(_ pieces: S) -> String? where S.Element == (text: String, frame: CGRect) {
        var text = ""
        var lastFrame: CGRect?
        for (piece, frame) in pieces {
            if let last = lastFrame {
                // Same row and close together (a name and its time); far apart is another pane.
                let sameRow = abs(frame.midY - last.midY) < min(frame.height, last.height) / 2
                    && frame.minX >= last.minX && frame.minX - last.maxX < 60
                text += sameRow ? "  " : "\n"
            }
            text += piece.replacingOccurrences(of: "\n\n", with: "\n")
            lastFrame = frame
        }
        guard !text.isEmpty else { return nil }
        if text.count > maxChars {
            text = String(text.suffix(maxChars))
            if let firstBreak = text.firstIndex(of: "\n") { text = String(text[text.index(after: firstBreak)...]) }
        }
        return text
    }
}
