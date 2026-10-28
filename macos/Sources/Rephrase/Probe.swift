import AppKit
import ApplicationServices

/// `open -n -a Rephrase --args --probe <bundle-id>` dumps that app's accessibility tree to
/// ~/Library/Logs/Rephrase-probe.txt. Shows roles, sizes and text lengths only, never text.
/// Used to work out how an app exposes (or hides) its text boxes.
enum Probe {
    static func run(bundleID: String) {
        // Gives you time to switch to the app and click into its text box.
        Thread.sleep(forTimeInterval: 8)
        defer { NSSound(named: "Glass")?.play(); Thread.sleep(forTimeInterval: 1) }

        let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Rephrase-probe.txt")
        var lines = ["probe \(bundleID) trusted=\(AXIsProcessTrusted()) at \(Date()) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")"]
        var sysFocused: CFTypeRef?
        let sysErr = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &sysFocused)
        lines.append("system focused element: err=\(sysErr.rawValue) \(sysFocused.map { describe($0 as! AXUIElement) } ?? "")")
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            lines.append("not running")
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.0)
        for flag in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            let err = AXUIElementSetAttributeValue(root, flag as CFString, kCFBooleanTrue)
            lines.append("set \(flag) -> \(err.rawValue)")
        }
        Thread.sleep(forTimeInterval: 1.0)

        var focused: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused)
        lines.append("app focused element: err=\(focusErr.rawValue) \(focused.map { describe($0 as! AXUIElement) } ?? "")")

        var count = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard count < 2500, depth < 30 else { return }
            count += 1
            lines.append(String(repeating: "  ", count: depth) + describe(el))
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
               let kids = children as? [AXUIElement] {
                kids.forEach { walk($0, depth: depth + 1) }
            }
        }
        // Windows only; the menu bar is noise.
        var windows: CFTypeRef?
        let winErr = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
        let wins = windows as? [AXUIElement] ?? []
        lines.append("windows: err=\(winErr.rawValue) count=\(wins.count)")
        wins.forEach { walk($0, depth: 0) }
        lines.append("nodes: \(count)")
        try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    private static func describe(_ el: AXUIElement) -> String {
        func attr(_ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
        }
        let role = attr(kAXRoleAttribute) as? String ?? "?"
        let subrole = attr(kAXSubroleAttribute) as? String
        var parts = [role + (subrole.map { "/\($0)" } ?? "")]
        if let v = attr(kAXValueAttribute) as? String { parts.append("valueLen=\(v.count)") }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        if settable.boolValue { parts.append("editable") }
        if (attr(kAXFocusedAttribute) as? Bool) == true { parts.append("FOCUSED") }
        if attr(kAXSelectedTextRangeAttribute) != nil { parts.append("hasSelRange") }
        if let size = attr(kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() {
            var s = CGSize.zero
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            parts.append("\(Int(s.width))x\(Int(s.height))")
        }
        // Labels help find the chat box ("Type message here...") but are cut short.
        for key in [kAXPlaceholderValueAttribute as String, kAXDescriptionAttribute as String] {
            if let s = attr(key) as? String, !s.isEmpty { parts.append("\(key)=\"\(s.prefix(30))\"") }
        }
        return parts.joined(separator: " ")
    }
}
