import Foundation

/// Talks to Ollama's local server (free models running on this Mac). No account needed.
enum Ollama {
    static let baseURL = URL(string: "http://localhost:11434")!
    private static let modelKey = "ollamaModel"

    /// A small model that rewrites well and fits comfortably in 8–16 GB of memory.
    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "llama3.2" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
            || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Applications/Ollama.app")
            || CLIEngine.find("ollama") != nil
    }

    static func status() async -> EngineState {
        guard let names = try? await installedModels() else {
            return isInstalled ? .notRunning : .notInstalled
        }
        // "llama3.2" matches "llama3.2:latest".
        let wanted = model.contains(":") ? model : model + ":latest"
        return names.contains(wanted) || names.contains(model) ? .ready : .needsModel(model)
    }

    static func installedModels() async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 2
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    static func chat(system: String, user: String, temperature: Double) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "options": ["temperature": temperature],
        ])
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw RewriteError.needsSetup(.ollama, isInstalled ? .notRunning : .notInstalled)
        }
        if (response as? HTTPURLResponse)?.statusCode == 404 {
            throw RewriteError.needsSetup(.ollama, .needsModel(model))
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = (json?["message"] as? [String: Any])?["content"] as? String else {
            throw RewriteError.failed("Ollama returned an unexpected reply: \((json?["error"] as? String) ?? "no content")")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Downloads `model`, reporting progress from 0 to 1.
    static func pull(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        for try await line in bytes.lines {
            guard let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = json["error"] as? String { throw RewriteError.failed("Ollama: \(error)") }
            let status = json["status"] as? String ?? ""
            if let total = json["total"] as? Double, total > 0, let done = json["completed"] as? Double {
                progress(done / total, status)
            } else {
                progress(-1, status)
            }
        }
    }
}
