import AppKit

// `Rephrase --test "some text" [modes...] [apple|claude|chatgpt]` runs the engine from the terminal and exits.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--test" {
    let text = CommandLine.arguments[2]
    let extra = CommandLine.arguments.dropFirst(3)
    let picked = extra.compactMap(RewriteMode.init(rawValue:))
    let modes = picked.isEmpty ? RewriteMode.allCases : picked
    let engine = extra.compactMap(EngineKind.init(rawValue:)).first ?? RewriteEngine.shared.kind
    Task {
        for mode in modes {
            let start = Date()
            do {
                let out = try await RewriteEngine.shared.rewrite(text, mode: mode, using: engine)
                print(String(format: "[%@ %@ %.2fs] %@", engine.rawValue, mode.title, Date().timeIntervalSince(start), out))
            } catch {
                print("[\(engine.rawValue) \(mode.title)] error: \(error.localizedDescription)")
            }
        }
        exit(0)
    }
    dispatchMain()   // keep the main thread free: setup progress is reported on it
}

if let i = CommandLine.arguments.firstIndex(of: "--probe"), i + 1 < CommandLine.arguments.count {
    Probe.run(bundleID: CommandLine.arguments[i + 1])
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
