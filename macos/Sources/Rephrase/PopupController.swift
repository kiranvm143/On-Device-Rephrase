import AppKit
import SwiftUI

/// A panel that can take keyboard input without activating Rephrase,
/// so the app you were typing in stays in front.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PopupModel: ObservableObject {
    enum State { case loading, done(String), failed(String), setup(EngineKind, EngineState), needsScreenAccess }

    @Published var mode: RewriteMode = .fix
    @Published private(set) var engine: EngineKind = RewriteEngine.shared.kind
    @Published private(set) var states: [RewriteMode: State] = [:]
    /// What's happening before the engine is asked, e.g. reading the conversation.
    @Published private(set) var busyText: String?
    /// The messages a reply is drafted from, read once per popup.
    @Published private(set) var conversation: Conversation?
    let captured: CapturedText

    init(captured: CapturedText) {
        self.captured = captured
    }

    /// Opened on an empty message box: there's nothing to rewrite, only a reply to draft.
    var replyOnly: Bool { captured.text.isEmpty }

    /// Your typed notes turn into the reply (selected messages are the conversation instead).
    var replyNotes: String { captured.isConversation ? "" : captured.text }

    var current: State { states[mode] ?? .loading }

    var result: String? {
        if case .done(let text) = current { return text }
        return nil
    }

    func select(_ newMode: RewriteMode) {
        if replyOnly && newMode != .reply { return }
        mode = newMode
        if case .done = states[newMode] { return }
        if case .loading = states[newMode] { return }
        states[newMode] = .loading
        let text = captured.text
        let engine = engine
        Task {
            do {
                let output: String
                if newMode == .reply {
                    let conversation = try await loadConversation()
                    output = try await RewriteEngine.shared.draftReply(to: conversation.text, notes: replyNotes, using: engine)
                } else {
                    output = try await RewriteEngine.shared.rewrite(text, mode: newMode, using: engine)
                }
                guard engine == self.engine else { return }   // you switched engines meanwhile
                states[newMode] = .done(output)
            } catch RewriteError.needsSetup(let kind, let state) {
                EngineSetup.shared.record(kind, state)
                states[newMode] = .setup(kind, state)
            } catch ConversationError.needsScreenAccess {
                states[newMode] = .needsScreenAccess
            } catch {
                states[newMode] = .failed(error.localizedDescription)
            }
        }
    }

    private func loadConversation() async throws -> Conversation {
        if let conversation { return conversation }
        let result: Conversation
        if captured.isConversation {
            result = Conversation(text: captured.text, source: .selection)
        } else {
            guard let pid = captured.app?.processIdentifier else { throw ConversationError.nothingFound }
            busyText = "Reading the conversation…"
            defer { busyText = nil }
            result = try await ConversationReader.read(pid: pid, input: captured.inputFrame, typingPoint: captured.typingPoint)
        }
        conversation = result
        return result
    }

    /// Switches engine from the popup's picker; remembered for next time.
    func switchEngine(_ kind: EngineKind) {
        guard kind != engine else { return }
        RewriteEngine.shared.kind = kind
        Log.write("engine: \(kind.rawValue) (from popup)")
        engine = kind
        retryAll()
    }

    /// Runs the current mode again: a fresh rewrite, or a new reply draft.
    /// After a screen-access prompt, reads the conversation again too.
    func retry() {
        if case .needsScreenAccess = current { conversation = nil }
        states[mode] = nil
        select(mode)
    }

    func retryAll() {
        states = [:]
        select(mode)
    }
}

@MainActor
final class PopupController {
    private var panel: KeyPanel?
    private var model: PopupModel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    static let size = NSSize(width: 580, height: 230)

    var isShowing: Bool { panel != nil }

    /// An engine finished setting up: retry in the open popup, or say so if it was closed.
    func engineReady(_ kind: EngineKind) {
        if let model, model.engine == kind {
            model.retryAll()
        } else if model == nil {
            showMessage("\(kind.shortName) is ready ✓ Click ✨ or press ⌃⌥R to use it.")
        }
    }

    func show(for captured: CapturedText, startWith mode: RewriteMode = .fix) {
        close()

        let model = PopupModel(captured: captured)
        self.model = model

        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PopupView(
            model: model,
            onReplace: { [weak self] in self?.replace() },
            onCopy: { [weak self] in self?.copy() },
            onClose: { [weak self] in self?.cancel() }
        ))
        panel.setFrameOrigin(origin(below: captured.anchor))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }

        model.select(captured.text.isEmpty ? .reply : mode)
        EngineSetup.shared.refreshAll()   // status badges in the engine picker
    }

    /// A short message near the mouse that closes itself, used when there's nothing to rewrite.
    func showMessage(_ message: String) {
        close()
        let size = NSSize(width: 340, height: 64)
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView:
            Text(message)
                .font(.system(size: 12))
                .padding(12)
                .frame(width: size.width, height: size.height, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        )
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12))
        panel.orderFrontRegardless()
        self.panel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.close()
        }
    }

    /// Writes the popup as a PNG (used by `--demo <path>`; needs no Screen Recording permission).
    func snapshot(to url: URL) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func select(_ mode: RewriteMode) { model?.select(mode) }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    /// Closes without replacing; undoes the ⌘A we may have pressed to capture the text.
    private func cancel() {
        let selectedAll = model?.captured.weSelectedAll == true
        close()
        if selectedAll {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { TextAccess.deselect() }
        }
    }

    private func replace() {
        guard let model, let text = model.result else { NSSound.beep(); return }
        let captured = model.captured
        if model.mode == .reply && captured.isConversation {
            // The selection is someone's messages, not a text box: hand the draft over instead.
            // (Rewrites still paste: some editors, like Google Docs, don't report that they're editable.)
            copy()
            showMessage("Reply copied. Click the message box and press ⌘V.")
            return
        }
        close()
        TextAccess.replace(captured, with: text)
    }

    private func copy() {
        guard let text = model?.result else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        cancel()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let modes = RewriteMode.allCases
        switch event.keyCode {
        case 53: cancel(); return true                        // esc
        case 36, 76:                                         // return / enter
            switch model.current {
            case .setup(let kind, _): EngineSetup.shared.performAction(for: kind)   // Enter runs the setup button
            case .needsScreenAccess: ConversationReader.requestScreenAccess()
            default: replace()
            }
            return true
        case 48 where model.replyOnly:
            return true
        case 48:                                             // tab / shift-tab cycles modes
            let i = modes.firstIndex(of: model.mode)!
            let step = event.modifierFlags.contains(.shift) ? modes.count - 1 : 1
            model.select(modes[(i + step) % modes.count])
            return true
        default: break
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copy(); return true
        }
        if let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...modes.count).contains(n) {
            model.select(modes[n - 1]); return true
        }
        if event.charactersIgnoringModifiers == "r" { model.retry(); return true }
        return false
    }

    /// Below the selection if it fits, otherwise above; always kept on screen.
    private func origin(below anchor: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var x = anchor.minX
        var y = anchor.minY - Self.size.height - 6
        if y < visible.minY { y = anchor.maxY + 6 }
        x = min(max(x, visible.minX + 8), visible.maxX - Self.size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - Self.size.height - 8)
        return NSPoint(x: x, y: y)
    }
}

private struct PopupView: View {
    @ObservedObject var model: PopupModel
    @ObservedObject private var setup = EngineSetup.shared
    let onReplace: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void

    private var isReply: Bool { model.mode == .reply }

    private var hint: String {
        if isReply {
            return model.captured.isConversation ? "↩ copy · r new draft · esc close" : "↩ insert · ⌘C copy · r new draft · esc close"
        }
        return "↩ replace · ⌘C copy · 1–6 / tab switch · esc close"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(RewriteMode.allCases.enumerated()), id: \.element) { index, mode in
                    if mode == .reply { Divider().frame(height: 14) }
                    Button { model.select(mode) } label: {
                        Text(mode.title)
                            .font(.system(size: 12, weight: model.mode == mode ? .semibold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(model.mode == mode ? Color.accentColor.opacity(0.18) : Color.clear,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.replyOnly && mode != .reply)
                    .opacity(model.replyOnly && mode != .reply ? 0.35 : 1)
                    .help(mode == .reply ? "Draft a reply to the conversation on screen (press \(index + 1))" : "Press \(index + 1)")
                }
                Spacer()
                EnginePicker(model: model)
            }

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text(hint)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if !(isReply && model.captured.isConversation) {   // there, the main button already copies
                    Button("Copy", action: onCopy).disabled(model.result == nil)
                }
                Button(isReply ? (model.captured.isConversation ? "Copy Reply" : "Insert") : "Replace", action: onReplace)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.result == nil)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: PopupController.size.width, height: PopupController.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }

    @ViewBuilder private var content: some View {
        switch model.current {
        case .loading:
            HStack(spacing: 8) {
                // A one-time setup (like ChatGPT's download) shows its own progress here.
                if let activity = setup.activity {
                    if let p = setup.progress {
                        ProgressView(value: p).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(activity).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text(model.busyText ?? (isReply ? "\(model.engine.shortName): drafting a reply…" : model.engine.busyLabel))
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .setup(let kind, let state):
            SetupPanel(kind: kind, reported: state)
        case .needsScreenAccess:
            ScreenAccessPanel(appName: model.captured.app?.localizedName ?? "This app", onCheckAgain: model.retry)
        case .done(let text) where isReply:
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 14))
                if let conversation = model.conversation {
                    Text("Reply to \(conversation.lineCount) lines \(conversation.sourceLabel)"
                         + (model.replyNotes.isEmpty ? "" : ", using your notes"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        case .done(let text):
            if model.mode == .fix {
                if text.trimmingCharacters(in: .whitespacesAndNewlines)
                    == model.captured.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    Label("Looks good — no changes needed.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Text(WordDiff.attributed(from: model.captured.text, to: text)).font(.system(size: 14))
                }
            } else {
                Text(text).font(.system(size: 14))
            }
        }
    }
}

/// Top-right menu to switch engine, with a status badge for each one that isn't ready.
private struct EnginePicker: View {
    @ObservedObject var model: PopupModel
    @ObservedObject private var setup = EngineSetup.shared

    var body: some View {
        Menu {
            ForEach(EngineKind.allCases, id: \.self) { kind in
                Button {
                    model.switchEngine(kind)
                } label: {
                    let state = setup.state(kind)
                    Text("\(kind == model.engine ? "✓ " : "    ")\(kind.title)\(state == .ready ? "" : "  — \(state.badge)")")
                }
            }
        } label: {
            Text(model.engine.shortName).font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which AI rewrites your text")
    }
}

/// Shown instead of a result when the chosen engine needs installing, signing in, starting or a model.
private struct SetupPanel: View {
    let kind: EngineKind
    let reported: EngineState
    @ObservedObject private var setup = EngineSetup.shared

    var body: some View {
        // Prefer the live state (it updates as setup progresses) over what the rewrite reported.
        let live = setup.state(kind)
        let state = live == .checking || live == .ready ? reported : live
        let copy = SetupCopy(kind: kind, state: state)
        VStack(alignment: .leading, spacing: 8) {
            Text(copy.headline).font(.system(size: 14, weight: .semibold))
            Text(copy.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let activity = setup.activity {
                    if let p = setup.progress {
                        ProgressView(value: p).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(activity).font(.system(size: 12))
                } else if let title = copy.actionTitle {
                    Button(title) { setup.performAction(for: kind) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                Button("Check again") {
                    Task { if await setup.refresh(kind) == .ready { setup.onReady?(kind) } }
                }
                .controlSize(.regular)
            }
            if let error = setup.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }
}

/// Shown when an app hides its messages from Accessibility and screen reading isn't allowed yet.
private struct ScreenAccessPanel: View {
    let appName: String
    let onCheckAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow screen reading to draft replies in \(appName)").font(.system(size: 14, weight: .semibold))
            Text("""
                 \(appName) doesn't share its messages with Accessibility, so Rephrase reads the text visible in its \
                 window instead, on this Mac with Apple's text recognition. Nothing is saved. Turn Rephrase on under \
                 Screen & System Audio Recording, then press ⌃⌥R again.
                 """)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Allow Screen Reading…") { ConversationReader.requestScreenAccess() }
                    .buttonStyle(.borderedProminent)
                Button("Check again", action: onCheckAgain)
                Button("Reopen Rephrase") { relaunch() }
                    .help("macOS sometimes only applies the permission after Rephrase restarts")
            }
            .controlSize(.regular)
        }
    }

    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
