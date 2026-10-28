import AppKit
import Foundation

enum EngineState: Equatable, Sendable {
    case checking
    case ready
    case notInstalled
    case notSignedIn
    case notRunning            // Ollama installed but its server isn't up
    case needsModel(String)    // Ollama running but the model isn't downloaded
    case unavailable(String)   // Apple Intelligence off / unsupported

    var badge: String {
        switch self {
        case .checking: "…"
        case .ready: "✓"
        case .notInstalled: "not installed"
        case .notSignedIn: "sign in"
        case .notRunning: "not running"
        case .needsModel: "needs model"
        case .unavailable: "unavailable"
        }
    }
}

/// What the popup's setup panel says and which button it shows, per engine and state.
struct SetupCopy {
    let kind: EngineKind
    let state: EngineState

    var headline: String {
        switch (kind, state) {
        case (.claude, .notInstalled): "Claude needs Claude Code"
        case (.claude, _): "Sign in to Claude"
        case (.chatgpt, .notInstalled): "ChatGPT needs Codex"
        case (.chatgpt, _): "Sign in with ChatGPT"
        case (.ollama, .notInstalled): "Install Ollama"
        case (.ollama, .notRunning): "Ollama isn't running"
        case (.ollama, .needsModel(let m)): "Download the \(m) model"
        case (.apple, .unavailable(let why)): why
        default: "\(kind.shortName) isn't ready"
        }
    }

    var detail: String {
        switch (kind, state) {
        case (.claude, .notInstalled):
            "Rephrase uses your Claude account through Claude Code, Anthropic's official app. Installing takes about a minute."
        case (.claude, _):
            "Your browser will open to sign in with your Claude account. Rephrase never sees your password."
        case (.chatgpt, .notInstalled):
            "Rephrase uses your ChatGPT account through Codex, OpenAI's official app."
        case (.chatgpt, _):
            "Your browser will open to sign in with your ChatGPT account. Rephrase never sees your password."
        case (.ollama, .notInstalled):
            "Ollama runs AI models on this Mac: free, private and offline."
        case (.ollama, .notRunning):
            "Ollama is installed but not started."
        case (.ollama, .needsModel):
            "A one-time download of about 2 GB. After that it works offline."
        default:
            "Or pick another engine above."
        }
    }

    var actionTitle: String? {
        switch (kind, state) {
        case (.claude, .notInstalled): "Install Claude Code"
        case (.claude, .notSignedIn): "Sign in to Claude"
        case (.chatgpt, .notInstalled): "Install Codex"
        case (.chatgpt, .notSignedIn): "Sign in with ChatGPT"
        case (.ollama, .notInstalled): "Install Ollama"
        case (.ollama, .notRunning): "Start Ollama"
        case (.ollama, .needsModel): "Download model"
        case (.apple, .unavailable): "Open System Settings"
        default: nil
        }
    }
}

/// Checks whether each engine is ready, and installs / signs in / starts it from the popup,
/// so you never need a terminal. Logins happen in your browser via each vendor's own app.
@MainActor
final class EngineSetup: ObservableObject {
    static let shared = EngineSetup()

    @Published private(set) var states: [EngineKind: EngineState] = [:]
    /// What's happening right now ("Installing Claude Code…"), shown with a spinner.
    @Published private(set) var activity: String?
    /// 0…1 while downloading an Ollama model.
    @Published private(set) var progress: Double?
    @Published private(set) var lastError: String?

    /// Called when an engine becomes ready after setup (the popup retries, or a toast is shown).
    var onReady: ((EngineKind) -> Void)?

    func state(_ kind: EngineKind) -> EngineState { states[kind] ?? .checking }

    /// A rewrite just found out the engine isn't ready; remember it so the right button shows.
    func record(_ kind: EngineKind, _ state: EngineState) { states[kind] = state }

    func refreshAll() {
        for kind in EngineKind.allCases { Task { await refresh(kind) } }
    }

    @discardableResult
    func refresh(_ kind: EngineKind) async -> EngineState {
        let s: EngineState
        switch kind {
        case .apple: s = RewriteEngine.shared.appleUnavailableReason().map { .unavailable($0) } ?? .ready
        case .claude: s = await CLIEngine.claudeStatus()
        case .chatgpt: s = await CLIEngine.chatgptStatus()
        case .ollama: s = await Ollama.status()
        }
        states[kind] = s
        return s
    }

    /// Runs the button shown for `kind`'s current state.
    func performAction(for kind: EngineKind) {
        guard activity == nil else { return }
        let state = state(kind)
        lastError = nil
        Task {
            switch (kind, state) {
            case (.claude, .notInstalled): await installClaude()
            case (.claude, _): await signIn(kind, args: ["auth", "login"], tool: "claude")
            case (.chatgpt, .notInstalled): await installCodex()
            case (.chatgpt, _): await signIn(kind, args: ["login"], tool: "codex")
            case (.ollama, .notInstalled): await installOllama()
            case (.ollama, .notRunning): await startOllama()
            case (.ollama, .needsModel): await pullModel()
            case (.apple, _):
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            default: break
            }
            activity = nil
            progress = nil
            if await refresh(kind) == .ready {
                Log.write("setup: \(kind.rawValue) ready")
                onReady?(kind)
            }
        }
    }

    // MARK: - Actions

    private func installClaude() async {
        activity = "Installing Claude Code… (about a minute)"
        // Anthropic's official installer; puts `claude` in ~/.local/bin.
        await runLogged("/bin/bash", ["-c", "curl -fsSL https://claude.ai/install.sh | bash"], timeout: 600)
        if CLIEngine.find("claude") == nil { lastError = "Couldn't install Claude Code. See claude.com/product/claude-code." }
    }

    private func installCodex() async {
        activity = "Installing Codex…"
        if let npm = CLIEngine.find("npm") {
            await runLogged(npm, ["install", "-g", "@openai/codex"], timeout: 600)
        } else if let brew = CLIEngine.find("brew") {
            await runLogged(brew, ["install", "--cask", "codex"], timeout: 900)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/openai/codex#installation")!)
            lastError = "Install Codex from the page that just opened, then click Check again."
            return
        }
        if CLIEngine.find("codex") == nil { lastError = "Couldn't install Codex automatically." }
    }

    private func installOllama() async {
        if let brew = CLIEngine.find("brew") {
            activity = "Installing Ollama… (a few minutes)"
            await runLogged(brew, ["install", "--cask", "ollama-app"], timeout: 1200)
            if Ollama.isInstalled { await startOllama(); return }
        }
        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
        lastError = "Download and open Ollama from the page that just opened, then click Check again."
    }

    private func startOllama() async {
        activity = "Starting Ollama…"
        let app = ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"]
            .first { FileManager.default.fileExists(atPath: $0) }
        if let app {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: config)
        } else if let ollama = CLIEngine.find("ollama") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ollama)
            p.arguments = ["serve"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
        for _ in 0..<30 {   // wait up to 15 s for the server
            if (try? await Ollama.installedModels()) != nil { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        lastError = "Ollama didn't start. Open the Ollama app, then click Check again."
    }

    private func pullModel() async {
        activity = "Downloading \(Ollama.model)…"
        progress = 0
        do {
            try await Ollama.pull { [weak self] fraction, status in
                Task { @MainActor in
                    guard let self else { return }
                    if fraction >= 0 {
                        self.progress = fraction
                        self.activity = "Downloading \(Ollama.model)… \(Int(fraction * 100))%"
                    } else if !status.isEmpty {
                        self.activity = status.prefix(1).uppercased() + status.dropFirst() + "…"
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Sign-in opens your browser. If the tool insists on a terminal, fall back to opening one.
    private func signIn(_ kind: EngineKind, args: [String], tool: String) async {
        guard let path = CLIEngine.find(tool) else { return }
        activity = "Finish signing in in your browser…"
        let started = Date()
        let result = try? await CLIEngine.run(path, args, stdin: nil, timeout: 300)
        if let (_, err, status) = result, status != 0, Date().timeIntervalSince(started) < 10 {
            Log.write("setup: \(tool) sign-in needs a terminal (\(err.prefix(120)))")
            openInTerminal("\"\(path)\" \(args.joined(separator: " "))")
            activity = "Finish signing in in the Terminal window that opened, then click Check again."
            for _ in 0..<150 {   // keep checking for up to 5 minutes
                try? await Task.sleep(for: .seconds(2))
                if await refresh(kind) == .ready { return }
            }
        }
    }

    /// Opens Terminal running `command` (a .command file needs no Automation permission).
    private func openInTerminal(_ command: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rephrase-signin.command")
        try? "#!/bin/zsh -l\n\(command)\necho\necho 'Done. You can close this window.'\n"
            .write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }

    private func runLogged(_ path: String, _ args: [String], timeout: Double) async {
        do {
            let (_, err, status) = try await CLIEngine.run(path, args, stdin: nil, timeout: timeout)
            Log.write("setup: \((path as NSString).lastPathComponent) \(args.first ?? "") exit=\(status)")
            if status != 0 { lastError = String(err.split(separator: "\n").last ?? "failed").prefix(200).description }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
