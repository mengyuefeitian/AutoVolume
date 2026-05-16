import Darwin
import Foundation

enum LaunchAgentInstaller {
    private static let label = "com.autovolume.agent"

    static func installAndStart(bundle: Bundle = .main) {
        guard let agentURL = bundle.url(forResource: "AutoVolumeAgent", withExtension: nil) else {
            return
        }

        let fileManager = FileManager.default
        guard let launchAgentsDirectory = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("LaunchAgents", isDirectory: true) else {
            return
        }

        do {
            try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(getpid())\n".write(to: sessionURL, atomically: true, encoding: .utf8)
            let plistURL = launchAgentsDirectory.appendingPathComponent("\(label).plist")
            try plist(agentPath: agentURL.path).write(to: plistURL, atomically: true, encoding: .utf8)
            restartAgent(plistURL: plistURL)
        } catch {
            fputs("AutoVolume LaunchAgent install error: \(error)\n", stderr)
        }
    }

    static func stop() {
        let domain = "gui/\(getuid())"
        guard let launchAgentsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("LaunchAgents", isDirectory: true) else {
            return
        }
        let plistURL = launchAgentsDirectory.appendingPathComponent("\(label).plist")
        try? FileManager.default.removeItem(at: sessionURL)
        _ = runLaunchctl(arguments: ["bootout", "\(domain)/\(label)"])
        _ = runLaunchctl(arguments: ["bootout", domain, plistURL.path])
        _ = runLaunchctl(arguments: ["kill", "TERM", "\(domain)/\(label)"])
        terminateResidualAgents()
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func plist(agentPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscaped(agentPath))</string>
                <string>--session-file</string>
                <string>\(xmlEscaped(sessionURL.path))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/tmp/autovolume-agent.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/autovolume-agent.err</string>
        </dict>
        </plist>
        """
    }

    private static func restartAgent(plistURL: URL) {
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(arguments: ["bootout", "\(domain)/\(label)"])
        _ = runLaunchctl(arguments: ["bootout", domain, plistURL.path])
        _ = runLaunchctl(arguments: ["bootstrap", domain, plistURL.path])
        _ = runLaunchctl(arguments: ["enable", "\(domain)/\(label)"])
    }

    private static var sessionURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AutoVolume", isDirectory: true)
            .appendingPathComponent("agent.session")
    }

    private static func runLaunchctl(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func terminateResidualAgents() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "/AutoVolume.app/Contents/Resources/AutoVolumeAgent"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
