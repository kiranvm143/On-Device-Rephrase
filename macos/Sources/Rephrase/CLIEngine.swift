import Foundation

/// Runs the user's own Claude Code or Codex CLI. Rephrase never sees or stores a login:
/// the CLI uses whatever account you signed into it with (the popup's Sign in button runs
/// `claude auth login` / `codex login`, which sign in through your browser).
enum CLIEngine {
    static func claude(instructions: String, prompt: String) async throws -> String {
        guard let path = find("claude") else { throw RewriteError.needsSetup(.claude, .notInstalled) }
        let args = [
            "-p", "--model", "haiku",
            "--system-prompt", instructions,
            "--tools", "",                 // text in, text out: no file or shell access
            "--safe-mode",                 // ignore CLAUDE.md, plugins, hooks, MCP servers
            "--no-session-persistence",
        ]
        let (out, err, status) = try await run(path, args, stdin: prompt)
        if status != 0 || out.isEmpty {
            if looksLikeAuthError(err + out) { throw RewriteError.needsSetup(.claude, .notSignedIn) }
            throw RewriteError.failed("Claude Code failed: \(firstLine(err.isEmpty ? out : err))")
        }
        return out
    }

    static func chatgpt(instructions: String, prompt: String) async throws -> String {
        // No Codex yet? Fetch Rephrase's own copy (one time), showing progress in the popup.
        let path = try await ensureCodex()
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("rephrase-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outFile) }
        let args = [
            "exec", "--skip-git-repo-check",
            "--ephemeral",                 // don't keep these rewrites in your Codex history
            "--sandbox", "read-only",
            "--color", "never",
            "-c", "model_reasoning_effort=low",
            "--output-last-message", outFile.path,
            "-",                           // prompt from stdin
        ]
        let (out, err, status) = try await run(path, args, stdin: instructions + "\n\n" + prompt)
        let answer = (try? String(contentsOf: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status != 0 || answer.isEmpty {
            if looksLikeAuthError(err + out) { throw RewriteError.needsSetup(.chatgpt, .notSignedIn) }
            throw RewriteError.failed("Codex failed: \(firstLine(err.isEmpty ? out : err))")
        }
        return answer
    }

    // MARK: - Status checks (used by the popup's engine menu and setup panel)

    static func claudeStatus() async -> EngineState {
        guard let path = find("claude") else { return .notInstalled }
        guard let (out, _, _) = try? await run(path, ["auth", "status", "--json"], stdin: nil, timeout: 15),
              let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .notSignedIn }
        return (json["loggedIn"] as? Bool) == true ? .ready : .notSignedIn
    }

    static func chatgptStatus() async -> EngineState {
        // Without Codex yet, a ChatGPT sign-in from any Codex on this Mac is enough: our copy downloads on first use.
        guard let path = find("codex") else { return CodexDownloader.hasChatGPTSignIn ? .ready : .notSignedIn }
        guard let (_, _, status) = try? await run(path, ["login", "status"], stdin: nil, timeout: 15) else { return .notSignedIn }
        return status == 0 ? .ready : .notSignedIn
    }

    /// Codex's path, downloading Rephrase's own copy first if there's none on this Mac.
    static func ensureCodex() async throws -> String {
        if let path = find("codex") { return path }
        await EngineSetup.shared.begin("Setting up ChatGPT… (one-time download)")
        do {
            let path = try await CodexDownloader.ensure { fraction in
                Task { @MainActor in
                    if fraction < 0 {
                        EngineSetup.shared.update("Setting up ChatGPT… unpacking", progress: nil)
                    } else {
                        EngineSetup.shared.update("Setting up ChatGPT… \(Int(fraction * 100))% (one-time download)",
                                                  progress: fraction)
                    }
                }
            }
            await EngineSetup.shared.end()
            return path
        } catch {
            await EngineSetup.shared.end()
            Log.write("codex: download failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Process helpers

    /// Apps opened from Finder don't get your shell's PATH, so ask a login shell once.
    static let shellPath: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "echo $PATH"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let home = NSHomeDirectory()
        let extras = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                      "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"]
        return ([path] + extras + ["/usr/bin", "/bin"]).filter { !$0.isEmpty }.joined(separator: ":")
    }()

    static func find(_ name: String) -> String? {
        let ownBin = (CodexDownloader.managedPath as NSString).deletingLastPathComponent
        let dirs = shellPath.split(separator: ":").map(String.init) + [npmGlobalBin, ownBin].compactMap { $0 }
        for dir in dirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Where `npm install -g` puts commands (e.g. codex), which may not be on your PATH.
    private static let npmGlobalBin: String? = {
        guard let npm = shellPath.split(separator: ":").map({ "\($0)/npm" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: npm)
        p.arguments = ["prefix", "-g"]
        p.environment = ["PATH": shellPath, "HOME": NSHomeDirectory()]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let prefix = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return prefix.isEmpty ? nil : prefix + "/bin"
    }()

    static func looksLikeAuthError(_ text: String) -> Bool {
        ["auth", "login", "log in", "sign in", "401", "unauthorized"].contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// Runs a program and collects its output. Gives up after `timeout` seconds so nothing hangs forever.
    static func run(_ path: String, _ args: [String], stdin: String?,
                    timeout seconds: Double = 60) async throws -> (String, String, Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = shellPath
            p.environment = env
            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.standardInput = inPipe

            // Read as output arrives, so a chatty installer can't fill the pipe and stall.
            let outBuf = OutputBuffer(), errBuf = OutputBuffer()
            outPipe.fileHandleForReading.readabilityHandler = { outBuf.append($0.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { errBuf.append($0.availableData) }

            let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)

            p.terminationHandler = { proc in
                timeout.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outBuf.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBuf.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: (outBuf.string.trimmingCharacters(in: .whitespacesAndNewlines),
                                                errBuf.string, proc.terminationStatus))
            }
            do {
                try p.run()
                if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inPipe.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: RewriteError.failed("Couldn't start \(path): \(error.localizedDescription)"))
            }
        }
    }

    private static func firstLine(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? "unknown error").prefix(200).description
    }
}

/// Collects a pipe's output from the background thread that reads it.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
