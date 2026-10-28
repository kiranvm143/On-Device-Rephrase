import CryptoKit
import Foundation

/// Keeps Rephrase's own copy of OpenAI's Codex CLI (used for the ChatGPT engine), so you don't
/// have to install anything. It's downloaded once from OpenAI's official GitHub releases, checked
/// against the SHA-256 that GitHub publishes for it, and stored in Application Support.
/// It signs in with the same ChatGPT account as any other Codex on this Mac (~/.codex).
enum CodexDownloader {
    static let managedPath = NSHomeDirectory() + "/Library/Application Support/Rephrase/bin/codex"

    static var isDownloaded: Bool { FileManager.default.isExecutableFile(atPath: managedPath) }

    /// True if you've signed in to ChatGPT with any Codex (the app, the CLI or ours).
    static var hasChatGPTSignIn: Bool {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        return FileManager.default.fileExists(atPath: home + "/auth.json")
    }

    /// Downloads Codex if needed and returns its path. `progress` gets 0…1 (or -1 while unpacking).
    static func ensure(progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        if let existing = CLIEngine.find("codex") { return existing }
        Log.write("codex: downloading private copy")

        // 1. Find the right file in OpenAI's latest release.
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/openai/codex/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        let release = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arch = ProcessInfo.processInfo.machineHardwareName == "arm64" ? "aarch64" : "x86_64"
        let name = "codex-\(arch)-apple-darwin.tar.gz"
        guard let asset = (release?["assets"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }),
              let urlString = asset["browser_download_url"] as? String, let url = URL(string: urlString),
              let digest = (asset["digest"] as? String)?.replacingOccurrences(of: "sha256:", with: "")
        else { throw RewriteError.failed("Couldn't find Codex for this Mac in OpenAI's latest release.") }

        // 2. Download with progress.
        let archive = try await download(url, progress: progress)
        defer { try? FileManager.default.removeItem(at: archive) }

        // 3. Verify it's exactly the file OpenAI published.
        guard try sha256(of: archive) == digest.lowercased() else {
            throw RewriteError.failed("The Codex download didn't match OpenAI's checksum, so it wasn't used.")
        }

        // 4. Unpack into Application Support/Rephrase/bin.
        progress(-1)
        let bin = (managedPath as NSString).deletingLastPathComponent
        let unpack = FileManager.default.temporaryDirectory.appendingPathComponent("rephrase-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unpack) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", unpack.path]
        try tar.run()
        tar.waitUntilExit()
        guard let file = try FileManager.default.contentsOfDirectory(atPath: unpack.path)
            .first(where: { $0.hasPrefix("codex") }) else {
            throw RewriteError.failed("The Codex download was empty.")
        }
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: managedPath)
        try FileManager.default.moveItem(atPath: unpack.appendingPathComponent(file).path, toPath: managedPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedPath)
        Log.write("codex: ready at \(managedPath)")
        return managedPath
    }

    private static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rephrase-codex-\(UUID().uuidString).tar.gz")
        // Holds the progress observer until the download finishes.
        final class Holder: @unchecked Sendable { var observation: NSKeyValueObservation? }
        let holder = Holder()
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                holder.observation = nil
                if let error { return continuation.resume(throwing: error) }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return continuation.resume(throwing: RewriteError.failed("Couldn't download Codex."))
                }
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            holder.observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}
