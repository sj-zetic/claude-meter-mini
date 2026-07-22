import Foundation
import ServiceManagement

// SMAppService is primary; if registration fails (e.g. running outside a proper
// bundle, or ad-hoc signing rejected), fall back to a LaunchAgent plist.
enum LaunchAtLogin {
    private static let agentLabel = "com.seongjun.claudeusage"
    private static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    @discardableResult
    static func toggle() -> Bool {
        isEnabled ? disable() : enable()
    }

    private static func enable() -> Bool {
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            return writeLaunchAgent()
        }
    }

    private static func disable() -> Bool {
        try? SMAppService.mainApp.unregister()
        if FileManager.default.fileExists(atPath: agentPlistURL.path) {
            runLaunchctl(["bootout", "gui/\(getuid())", agentPlistURL.path])
            try? FileManager.default.removeItem(at: agentPlistURL)
        }
        return true
    }

    private static func writeLaunchAgent() -> Bool {
        let executable = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                            format: .xml, options: 0) else {
            return false
        }
        let dir = agentPlistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: agentPlistURL, options: .atomic)
        } catch {
            return false
        }
        runLaunchctl(["bootstrap", "gui/\(getuid())", agentPlistURL.path])
        return true
    }

    private static func runLaunchctl(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
