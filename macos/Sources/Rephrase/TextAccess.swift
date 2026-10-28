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

    /// Frame (Cocoa coordinates) of the focused editable text box, if it has some text in it.
    /// Password fields are never reported.
    /// The reason string explains why there's no frame (or what was found), for the log.
    /// `hidden` is true when the app hides what's focused (Zoom chat, ...), so a text box may still be there.
    static func focusedTextField() -> (frame: NSRect?, reason: String, hidden: Bool) {
        let (frame, reason) = findFocusedTextField()
        let hidden = frame == nil
            && (reason.hasPrefix("no focused element") || Self.opaqueRoles.contains { reason.contains("focused \($0) ") })
        return (frame, reason, hidden)
    }

    /// Roles that are just containers: if one of these has focus, the real text box may be invisible to AX.
    private static let opaqueRoles = ["AXGroup", "AXWebArea", "AXUnknown", "AXScrollArea", "AXWindow", "AXSplitGroup", "AXStaticText"]

    private static func findFocusedTextField() -> (NSRect?, String) {
        let app = NSWorkspace.shared.frontmostApplication
        enableAccessibility(for: app)
        let (found, via) = focusedElement(in: app)
        guard var focused = found else { return (nil, "no focused element (\(via))") }

        // Web views: the focus may sit on a child inside a contenteditable box.
        var role: String = copyAttribute(focused, kAXRoleAttribute) ?? "?"
        if ![kAXTextFieldRole, kAXTextAreaRole].contains(role),
           let editable: AXUIElement = copyAttribute(focused, "AXEditableAncestor") {
            focused = editable
            role = copyAttribute(focused, kAXRoleAttribute) ?? "?"
        }

        let subrole: String = copyAttribute(focused, kAXSubroleAttribute) ?? ""
        guard subrole != (kAXSecureTextFieldSubrole as String) else { return (nil, "password field") }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        guard textRoles.contains(role) || settable.boolValue else { return (nil, "focused \(role) is not a text box") }

        let length: Int = copyAttribute(focused, kAXNumberOfCharactersAttribute)
            ?? (copyAttribute(focused, kAXValueAttribute) as String?)?.count ?? 0
        guard length > 0 else { return (nil, "\(role) is empty") }
        guard let frame = frame(of: focused) else { return (nil, "\(role) has no position") }
        guard frame.width >= 40, frame.height >= 14 else { return (nil, "\(role) too small \(frame.size)") }
        return (frame, "\(role) \(length) chars via \(via)")
    }

    /// `selectAllIfEmpty`: when the app hides its text box and nothing is selected, press ⌘A first.
    /// Only safe when we know you were just typing in that app (so focus is in a text box).
    static func captureSelection(selectAllIfEmpty: Bool = false) -> CapturedText? {
        let app = NSWorkspace.shared.frontmostApplication
        enableAccessibility(for: app)

        let focused = focusedElement(in: app).0
        let anchor = focused.flatMap(selectionBounds) ?? focused.flatMap(elementBounds) ?? mouseAnchor()

        if let focused {
            let role: String? = copyAttribute(focused, kAXRoleAttribute)
            let selected: String? = copyAttribute(focused, kAXSelectedTextAttribute)
            Log.write("capture: focusedRole=\(role ?? "?") axSelectedChars=\(selected.map { String($0.count) } ?? "unsupported")")
            if let selected {
                if !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return CapturedText(text: selected, wholeField: false, anchor: anchor, app: app)
                }
                // AX reports an empty selection: use the whole field.
                if let value: String = copyAttribute(focused, kAXValueAttribute),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return CapturedText(text: value, wholeField: true, anchor: anchor, app: app)
                }
                return nil
            }
        }

        // The app doesn't expose its selection over AX (Google Docs, some web/Electron views).
        if focused == nil { Log.write("capture: no focused element via AX") }
        let copied = copyViaClipboard()
        Log.write("capture: clipboard fallback chars=\(copied.map { String($0.count) } ?? "none")")
        if let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CapturedText(text: copied, wholeField: false, anchor: anchor, app: app)
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
        var captured = CapturedText(text: all, wholeField: true, anchor: anchor, app: app)
        captured.weSelectedAll = true
        return captured
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

    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
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
        guard let posValue: AXValue = copyAttribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = copyAttribute(element, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return flip(CGRect(origin: pos, size: size))
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
