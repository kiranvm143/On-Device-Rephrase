import AppKit
import ApplicationServices

struct CapturedText {
    let text: String
    /// True when nothing was selected and we took the whole text field instead.
    let wholeField: Bool
    /// Where to show the popup, in Cocoa screen coordinates (origin bottom-left).
    let anchor: NSRect
    let app: NSRunningApplication?
    /// We pressed ⌘A to capture, so closing without replacing should deselect again.
    var weSelectedAll = false
    /// Came from a text box you can type in. Otherwise it's text you selected elsewhere,
    /// such as messages to reply to, and can't be replaced in place.
    var editable = true
    /// The message box's frame in Accessibility coordinates (top-left origin), if known.
    var inputFrame: CGRect?
    /// Where you clicked to type, for apps that hide their text box (Accessibility coordinates).
    var typingPoint: CGPoint?

    /// Selected messages (not your own draft): Reply uses them as the conversation.
    var isConversation: Bool { !editable && !text.isEmpty }
}

/// Reads the selected text in whatever app is in front, and writes the rewrite back.
/// Uses the Accessibility API first and falls back to ⌘C / ⌘V.
enum TextAccess {
    private static var enabledPIDs: Set<pid_t> = []

    /// Electron apps (Slack, VS Code, ...) and Chrome only expose text to AX after this is set.
    private static func enableAccessibility(for app: NSRunningApplication?) {
        guard let pid = app?.processIdentifier, !enabledPIDs.contains(pid) else { return }
        enabledPIDs.insert(pid)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static var enhancedPIDs: Set<pid_t> = []

    /// Finds the focused element, trying harder for apps (Teams, Zoom, ...) that don't answer
    /// the system-wide query until an assistive app asks them directly.
    private static func focusedElement(in app: NSRunningApplication?) -> (AXUIElement?, String) {
        var ref: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &ref)
        if err == .success, let ref { return ((ref as! AXUIElement), "system") }

        guard let pid = app?.processIdentifier else { return (nil, "no front app") }
        let appElement = AXUIElementCreateApplication(pid)
        err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &ref)
        if err == .success, let ref { return ((ref as! AXUIElement), "app") }

        // Last resort: the flag VoiceOver sets. Makes WebKit/Qt-based apps build their AX tree.
        // Only set for apps that need it, since it can slow window animations in some apps.
        if !enhancedPIDs.contains(pid) {
            enhancedPIDs.insert(pid)
            let setErr = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            Log.write("focus: enabled AXEnhancedUserInterface for \(app?.bundleIdentifier ?? "?") result=\(setErr.rawValue)")
            err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &ref)
            if err == .success, let ref { return ((ref as! AXUIElement), "app+enhanced") }
        }
        return (nil, "AX error \(err.rawValue)")
    }

    /// Frame (Cocoa coordinates) of the focused editable text box, if it has some text in it
    /// (or even when empty, with `allowEmpty`). Password fields are never reported.
    /// The reason string explains why there's no frame (or what was found), for the log.
    /// `hidden` is true when the app hides what's focused (Zoom chat, ...), so a text box may still be there.
    static func focusedTextField(allowEmpty: Bool = false) -> (frame: NSRect?, reason: String, hidden: Bool) {
        let (frame, reason) = findFocusedTextField(allowEmpty: allowEmpty)
        let hidden = frame == nil
            && (reason.hasPrefix("no focused element") || Self.opaqueRoles.contains { reason.contains("focused \($0) ") })
        return (frame, reason, hidden)
    }

    /// Roles that are just containers: if one of these has focus, the real text box may be invisible to AX.
    private static let opaqueRoles = ["AXGroup", "AXWebArea", "AXUnknown", "AXScrollArea", "AXWindow", "AXSplitGroup", "AXStaticText"]

    /// The focused text box you can type in (possibly empty), or why there isn't one.
    private static func focusedEditable(in app: NSRunningApplication?) -> (element: AXUIElement?, role: String, reason: String) {
        let (found, via) = focusedElement(in: app)
        guard var focused = found else { return (nil, "", "no focused element (\(via))") }

        // Web views: the focus may sit on a child inside a contenteditable box.
        var role: String = copyAttribute(focused, kAXRoleAttribute) ?? "?"
        if ![kAXTextFieldRole, kAXTextAreaRole].contains(role),
           let editable: AXUIElement = copyAttribute(focused, "AXEditableAncestor") {
            focused = editable
            role = copyAttribute(focused, kAXRoleAttribute) ?? "?"
        }

        let subrole: String = copyAttribute(focused, kAXSubroleAttribute) ?? ""
        guard subrole != (kAXSecureTextFieldSubrole as String) else { return (nil, role, "password field") }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        guard textRoles.contains(role) || settable.boolValue else { return (nil, role, "focused \(role) is not a text box") }
        return (focused, role, "via \(via)")
    }

    private static func findFocusedTextField(allowEmpty: Bool) -> (NSRect?, String) {
        let app = NSWorkspace.shared.frontmostApplication
        enableAccessibility(for: app)
        let (found, role, reason) = focusedEditable(in: app)
        guard let focused = found else { return (nil, reason) }

        let length: Int = copyAttribute(focused, kAXNumberOfCharactersAttribute)
            ?? (copyAttribute(focused, kAXValueAttribute) as String?)?.count ?? 0
        guard length > 0 || allowEmpty else { return (nil, "\(role) is empty") }
        guard let frame = frame(of: focused) else { return (nil, "\(role) has no position") }
        guard frame.width >= 40, frame.height >= 14 else { return (nil, "\(role) too small \(frame.size)") }
        return (frame, "\(role) \(length) chars \(reason)")
    }

    /// An empty message box to draft a reply into: the focused text box, or in chat apps that
    /// hide theirs (Zoom), wherever the caret is. Nil when there's nowhere sensible to reply.
    static func replyTarget(chatApp: Bool) -> CapturedText? {
        let app = NSWorkspace.shared.frontmostApplication
        enableAccessibility(for: app)
        if let focused = focusedEditable(in: app).element {
            var captured = CapturedText(text: "", wholeField: false,
                                        anchor: elementBounds(focused) ?? mouseAnchor(), app: app)
            captured.inputFrame = axFrame(of: focused)
            return captured
        }
        return chatApp ? CapturedText(text: "", wholeField: false, anchor: mouseAnchor(), app: app) : nil
    }

    /// `selectAllIfEmpty`: when the app hides its text box and nothing is selected, press ⌘A first.
    /// Only safe when we know you were just typing in that app (so focus is in a text box).
    static func captureSelection(selectAllIfEmpty: Bool = false) -> CapturedText? {
        let app = NSWorkspace.shared.frontmostApplication
        enableAccessibility(for: app)

        let focused = focusedElement(in: app).0
        let anchor = focused.flatMap(selectionBounds) ?? focused.flatMap(elementBounds) ?? mouseAnchor()
        let input = focusedEditable(in: app).element
        let inputFrame = input.flatMap(axFrame)

        func captured(_ text: String, wholeField: Bool, editable: Bool) -> CapturedText {
            var c = CapturedText(text: text, wholeField: wholeField, anchor: anchor, app: app)
            c.editable = editable
            c.inputFrame = inputFrame
            return c
        }

        if let focused {
            let role: String? = copyAttribute(focused, kAXRoleAttribute)
            let selected: String? = copyAttribute(focused, kAXSelectedTextAttribute)
            Log.write("capture: focusedRole=\(role ?? "?") axSelectedChars=\(selected.map { String($0.count) } ?? "unsupported") editable=\(input != nil)")
            if let selected {
                if !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return captured(selected, wholeField: false, editable: input != nil)
                }
                // AX reports an empty selection: use the whole field.
                if let value: String = copyAttribute(focused, kAXValueAttribute),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return captured(value, wholeField: true, editable: input != nil)
                }
                return nil
            }
        }

        // The app doesn't expose its selection over AX (Google Docs, some web/Electron views).
        if focused == nil { Log.write("capture: no focused element via AX") }
        let copied = copyViaClipboard()
        Log.write("capture: clipboard fallback chars=\(copied.map { String($0.count) } ?? "none")")
        if let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Zoom hides its box, so a selection there is most likely your draft.
            return captured(copied, wholeField: false, editable: input != nil || selectAllIfEmpty)
        }

        guard selectAllIfEmpty else { return nil }
        sendKey(0 /* A */, command: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let all = copyViaClipboard()
        Log.write("capture: select-all fallback chars=\(all.map { String($0.count) } ?? "none")")
        guard let all, !all.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            deselect()
            return nil
        }
        var result = captured(all, wholeField: true, editable: true)
        result.weSelectedAll = true
        return result
    }

    /// Moves the caret to the end so a selection we made doesn't get typed over.
    static func deselect() {
        sendKey(124 /* → */, command: false)
    }

    static func replace(_ captured: CapturedText, with newText: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(newText, forType: .string)
        // Tells clipboard managers to ignore this temporary entry.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        captured.app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if captured.wholeField { sendKey(0 /* A */, command: true) }
            sendKey(9 /* V */, command: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { restore(saved, to: pasteboard) }
        }
    }

    // MARK: - Accessibility helpers

    static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func selectionBounds(_ element: AXUIElement) -> NSRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return flip(rect)
    }

    private static func frame(of element: AXUIElement) -> NSRect? {
        axFrame(of: element).map(flip)
    }

    /// The element's frame as AX reports it (top-left origin).
    private static func axFrame(of element: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = copyAttribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = copyAttribute(element, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private static func elementBounds(_ element: AXUIElement) -> NSRect? {
        guard let f = frame(of: element) else { return nil }
        // Anchor to the bottom-left of the field, not the whole (possibly huge) element.
        return NSRect(x: f.minX, y: f.minY, width: min(f.width, 200), height: min(f.height, 24))
    }

    private static func mouseAnchor() -> NSRect {
        let p = NSEvent.mouseLocation
        return NSRect(x: p.x, y: p.y - 10, width: 1, height: 20)
    }

    /// AX uses top-left origin on the primary screen; Cocoa uses bottom-left.
    static func flip(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }

    private static func flip(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Clipboard + key events

    private static func copyViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount
        sendKey(8 /* C */, command: true)

        let deadline = Date().addingTimeInterval(0.35)
        while pasteboard.changeCount == before && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let copied = pasteboard.changeCount != before ? pasteboard.string(forType: .string) : nil
        restore(saved, to: pasteboard)
        return copied
    }

    private static func sendKey(_ keyCode: CGKeyCode, command: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = command ? .maskCommand : []
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { entry[type] = item.data(forType: type) }
            return entry
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
