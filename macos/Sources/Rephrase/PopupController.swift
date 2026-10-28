import AppKit
import SwiftUI

/// A panel that can take keyboard input without activating Rephrase,
/// so the app you were typing in stays in front.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PopupModel: ObservableObject {
    enum State { case loading, done(String), failed(String), setup(EngineKind, EngineState) }

    @Published var mode: RewriteMode = .fix
    @Published private(set) var engine: EngineKind = RewriteEngine.shared.kind
    @Published private(set) var states: [RewriteMode: State] = [:]
    let captured: CapturedText

    init(captured: CapturedText) {
        self.captured = captured
    }

    var current: State { states[mode] ?? .loading }

    var result: String? {
        if case .done(let text) = current { return text }
        return nil
    }

    func select(_ newMode: RewriteMode) {
        mode = newMode
        if case .done = states[newMode] { return }
        if case .loading = states[newMode] { return }
        states[newMode] = .loading
        let text = captured.text
        let engine = engine
        Task {
            do {
                let output = try await RewriteEngine.shared.rewrite(text, mode: newMode, using: engine)
                guard engine == self.engine else { return }   // you switched engines meanwhile
                states[newMode] = .done(output)
            } catch RewriteError.needsSetup(let kind, let state) {
                EngineSetup.shared.record(kind, state)
                states[newMode] = .setup(kind, state)
            } catch {
                states[newMode] = .failed(error.localizedDescription)
            }
        }
    }

    /// Switches engine from the popup's picker; remembered for next time.
    func switchEngine(_ kind: EngineKind) {
        guard kind != engine else { return }
        RewriteEngine.shared.kind = kind
        Log.write("engine: \(kind.rawValue) (from popup)")
        engine = kind
        retryAll()
    }

    func retry() {
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

    static let size = NSSize(width: 540, height: 230)

    var isShowing: Bool { panel != nil }

    /// An engine finished setting up: retry in the open popup, or say so if it was closed.
    func engineReady(_ kind: EngineKind) {
        if let model, model.engine == kind {
            model.retryAll()
        } else if model == nil {
            showMessage("\(kind.shortName) is ready ✓ Click ✨ or press ⌃⌥R to use it.")
        }
    }

    func show(for captured: CapturedText) {
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

        model.select(.fix)
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
            if case .setup(let kind, _) = model.current {
                EngineSetup.shared.performAction(for: kind)   // Enter runs the setup button
            } else {
                replace()
            }
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
    let onReplace: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(RewriteMode.allCases.enumerated()), id: \.element) { index, mode in
                    Button { model.select(mode) } label: {
                        Text(mode.title)
                            .font(.system(size: 12, weight: model.mode == mode ? .semibold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(model.mode == mode ? Color.accentColor.opacity(0.18) : Color.clear,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Press \(index + 1)")
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
                Text("↩ replace · ⌘C copy · 1–5 / tab switch · esc close")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", action: onCopy).disabled(model.result == nil)
                Button("Replace", action: onReplace)
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
                ProgressView().controlSize(.small)
                Text(RewriteEngine.shared.kind.busyLabel).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .setup(let kind, let state):
            SetupPanel(kind: kind, reported: state)
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
