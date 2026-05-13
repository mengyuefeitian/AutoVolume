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
            let plistURL = launchAgentsDirectory.appendingPathComponent("\(label).plist")
            try plist(agentPath: agentURL.path).write(to: plistURL, atomically: true, encoding: .utf8)
            restartAgent(plistURL: plistURL)
        } catch {
            fputs("AutoVolume LaunchAgent install error: \(error)\n", stderr)
        }
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
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
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
        _ = runLaunchctl(arguments: ["bootout", domain, plistURL.path])
        _ = runLaunchctl(arguments: ["bootstrap", domain, plistURL.path])
        _ = runLaunchctl(arguments: ["enable", "\(domain)/\(label)"])
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

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
