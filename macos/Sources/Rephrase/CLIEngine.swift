import Foundation

/// Runs the user's own Claude Code or Codex CLI. Rephrase never sees or stores a login:
/// the CLI uses whatever account you signed into it with (`claude` → /login, `codex login`).
enum CLIEngine {
    static func claude(instructions: String, prompt: String) async throws -> String {
        guard let path = find("claude") else {
            throw RewriteError.unavailable("Claude Code isn't installed. Install it from claude.com/code, run `claude` once in Terminal and sign in.")
        }
        let args = [
            "-p", "--model", "haiku",
            "--system-prompt", instructions,
            "--tools", "",                 // text in, text out: no file or shell access
            "--safe-mode",                 // ignore CLAUDE.md, plugins, hooks, MCP servers
            "--no-session-persistence",
        ]
        let (out, err, status) = try await run(path, args, stdin: prompt)
        if status != 0 || out.isEmpty {
            if (err + out).localizedCaseInsensitiveContains("auth") || (err + out).localizedCaseInsensitiveContains("login") {
                throw RewriteError.unavailable("Claude Code isn't signed in. Run `claude` in Terminal and sign in, then try again.")
            }
            throw RewriteError.failed("Claude Code failed: \(firstLine(err.isEmpty ? out : err))")
        }
        return out
    }

    static func chatgpt(instructions: String, prompt: String) async throws -> String {
        guard let path = find("codex") else {
            throw RewriteError.unavailable("Codex CLI isn't installed. Install it (npm i -g @openai/codex or brew install codex), then run `codex login`.")
        }
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("rephrase-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outFile) }
        let args = [
            "exec", "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--color", "never",
            "-c", "model_reasoning_effort=low",
            "--output-last-message", outFile.path,
            instructions + "\n\n" + prompt,
        ]
        let (out, err, status) = try await run(path, args, stdin: nil)
        let answer = (try? String(contentsOf: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status != 0 || answer.isEmpty {
            if (err + out).localizedCaseInsensitiveContains("login") || (err + out).localizedCaseInsensitiveContains("auth") {
                throw RewriteError.unavailable("Codex isn't signed in. Run `codex login` in Terminal and sign in with ChatGPT.")
            }
            throw RewriteError.failed("Codex failed: \(firstLine(err.isEmpty ? out : err))")
        }
        return answer
    }

    // MARK: - Process helpers

    /// Apps opened from Finder don't get your shell's PATH, so ask a login shell once.
    private static let shellPath: String = {
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
        for dir in shellPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String], stdin: String?) async throws -> (String, String, Int32) {
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

            // Give up after 60 s so the popup never hangs forever.
            let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)

            p.terminationHandler = { proc in
                timeout.cancel()
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (out.trimmingCharacters(in: .whitespacesAndNewlines), err, proc.terminationStatus))
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
