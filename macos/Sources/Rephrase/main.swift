import AppKit

// `Rephrase --test "some text" [modes...] [apple|claude|chatgpt|ollama]` runs the engine from the terminal and exits.
// With the `reply` mode, the text is the conversation and the output is a drafted reply
// (`--notes "what to say"` adds notes, like text typed in the message box).
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--test" {
    let text = CommandLine.arguments[2]
    let extra = CommandLine.arguments.dropFirst(3)
    let picked = extra.compactMap(RewriteMode.init(rawValue:))
    let modes = picked.isEmpty ? RewriteMode.rewrites : picked
    let engine = extra.compactMap(EngineKind.init(rawValue:)).first ?? RewriteEngine.shared.kind
    let notes = extra.firstIndex(of: "--notes").flatMap { extra.index(after: $0) < extra.endIndex ? extra[extra.index(after: $0)] : nil } ?? ""
    Task {
        for mode in modes {
            let start = Date()
            do {
                let out = mode == .reply
                    ? try await RewriteEngine.shared.draftReply(to: text, notes: notes, using: engine)
                    : try await RewriteEngine.shared.rewrite(text, mode: mode, using: engine)
                print(String(format: "[%@ %@ %.2fs] %@", engine.rawValue, mode.title, Date().timeIntervalSince(start), out))
            } catch {
                print("[\(engine.rawValue) \(mode.title)] error: \(error.localizedDescription)")
            }
        }
        exit(0)
    }
    dispatchMain()   // keep the main thread free: setup progress is reported on it
}

// `Rephrase --ocr-test <window.png> [message-box top, as a fraction of the height]` runs the screen-text
// reader on a screenshot (no permission needed) and prints what it would send as the conversation.
if let i = CommandLine.arguments.firstIndex(of: "--ocr-test"), i + 1 < CommandLine.arguments.count {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[i + 1]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print("can't read image"); exit(1) }
    let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let boxTop = i + 2 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 2]) ?? 1 : 1
    let area = CGRect(x: 0, y: 0, width: frame.width, height: frame.height * boxTop)
    Task {
        let start = Date()
        let text = (try? await ConversationReader.recognizeText(in: image, windowFrame: frame, area: area)) ?? "error"
        print(String(format: "[%.2fs]\n%@", Date().timeIntervalSince(start), text))
        exit(0)
    }
    dispatchMain()
}

if let i = CommandLine.arguments.firstIndex(of: "--probe"), i + 1 < CommandLine.arguments.count {
    Probe.run(bundleID: CommandLine.arguments[i + 1])
    exit(0)
}

// `open -n -a Rephrase --args --read-test <bundle-id or pid> <window title>` reads the conversation above the
// first text box in that app's window (left in the background) and writes it to
// ~/Library/Logs/Rephrase-read.txt, then closes the window. For testing the reader on a sample page.
if let i = CommandLine.arguments.firstIndex(of: "--read-test"), i + 2 < CommandLine.arguments.count {
    let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Rephrase-read.txt")
    let title = CommandLine.arguments[i + 2]
    let target = CommandLine.arguments[i + 1]   // a bundle ID, or a process ID
    guard let app = pid_t(target).flatMap(NSRunningApplication.init(processIdentifier:))
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: target).first else { exit(1) }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 1.5)
    let windows: [AXUIElement] = TextAccess.copyAttribute(appElement, kAXWindowsAttribute) ?? []
    guard let window = windows.first(where: { (TextAccess.copyAttribute($0, kAXTitleAttribute) as String?)?.contains(title) == true }) else {
        try? "no window titled \(title) among \(windows.count)".write(to: out, atomically: true, encoding: .utf8)
        exit(1)
    }
    let box = firstTextArea(in: window)
    Task {
        let start = Date()
        var report = "input=\(box.map { "\($0)" } ?? "none")\n"
        do {
            let c = try await ConversationReader.read(pid: app.processIdentifier, input: box, typingPoint: nil)
            report += String(format: "source=%@ lines=%d %.2fs\n", "\(c.source)", c.lineCount, Date().timeIntervalSince(start)) + c.text
        } catch {
            report += "error: \(error.localizedDescription)"
        }
        try? report.write(to: out, atomically: true, encoding: .utf8)
        if let close: AXUIElement = TextAccess.copyAttribute(window, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(close, kAXPressAction as CFString)
        }
        exit(0)
    }
    dispatchMain()
}

/// Test helper: the frame (AX coordinates) of the first multi-line text box in `window`.
func firstTextArea(in window: AXUIElement) -> CGRect? {
    func find(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 60 else { return nil }
        if let role: String = TextAccess.copyAttribute(el, kAXRoleAttribute), role == kAXTextAreaRole { return el }
        for child in (TextAccess.copyAttribute(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if let hit = find(child, depth: depth + 1) { return hit }
        }
        return nil
    }
    guard let box = find(window, depth: 0),
          let pos: AXValue = TextAccess.copyAttribute(box, kAXPositionAttribute),
          let size: AXValue = TextAccess.copyAttribute(box, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pos, .cgPoint, &p)
    AXValueGetValue(size, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
