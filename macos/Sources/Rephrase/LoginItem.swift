import Foundation
import ServiceManagement

/// Starts Rephrase when you log in, via macOS's Login Items (System Settings → General → Login Items).
enum LoginItem {
    private static let configuredKey = "loginItemConfigured"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Only the copy installed in Applications should register, never a build folder copy.
    static var isInstalledCopy: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
            || path.hasPrefix("/Applications/")
    }

    /// Turns it on the first time the installed app runs; after that your menu choice wins.
    static func enableOnFirstRun() {
        guard isInstalledCopy, !UserDefaults.standard.bool(forKey: configuredKey) else { return }
        UserDefaults.standard.set(true, forKey: configuredKey)
        set(true)
    }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("login item: \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        Log.write("login item: status=\(SMAppService.mainApp.status.rawValue) (1 = enabled)")
    }
}
