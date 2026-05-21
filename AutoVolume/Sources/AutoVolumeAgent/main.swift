import Foundation
import Darwin
import AutoVolumeShared

let sessionFilePath = parsedSessionFilePath(arguments: CommandLine.arguments)
let launchAgentLabel = "com.autovolume.agent"
let store = JSONConfigStore()
let credentialStore = EncryptedFileCredentialStore()
let commandRunner = ProcessCommandRunner()
let connectivityTester = ConnectivityTester()
let mountStateProvider = FileSystemMountStateProvider(healthCheckTimeout: 3, validatesResponsiveness: true)
let engine = AgentEngine(
    mountState: mountStateProvider,
    credentialStore: credentialStore,
    commandRunner: commandRunner,
    mountPlanner: MountPlanner(),
    validatesAfterMount: true
)
let mountPlanner = MountPlanner()
var scheduler = CheckScheduler()
let alertStore = AlertStore()
var networkFailedVolumeIDs = Set<UUID>()

func runOnce() {
    guard appSessionIsActive() else {
        cleanupOrphanedLaunchAgent()
        exit(0)
    }

    let configs: [VolumeConfig]
    do {
        configs = try store.load()
    } catch {
        fputs("AutoVolumeAgent config error: \(error)\n", stderr)
        return
    }

    let now = Date()
    for config in configs where config.isEnabled {
        guard scheduler.isDue(volumeID: config.id, interval: config.checkIntervalSeconds, now: now) else {
            continue
        }

        do {
            let connectivity = try serverReachability(config)
            guard connectivity.isReachable else {
                networkFailedVolumeIDs.insert(config.id)
                scheduler.markChecked(volumeID: config.id, at: retryCheckedDate(interval: config.checkIntervalSeconds, retryInterval: 60, now: now))
                try? alertStore.record(volumeID: config.id, volumeName: config.name, message: connectivity.message ?? "Server is not reachable. AutoVolume will retry after the network returns.", date: now)
                continue
            }

            let status: VolumeStatus
            let wasMounted = mountStateProvider.isMounted(config: config)
            if networkFailedVolumeIDs.contains(config.id) {
                status = try engine.reconnect(config)
                if status == .mounted {
                    openMountedVolume(config)
                }
            } else {
                status = try engine.check(config)
                if !wasMounted, status == .mounted, mountPlanner.shouldOpenFinderAfterMount(for: config) {
                    openMountedVolume(config)
                }
            }
            scheduler.markChecked(volumeID: config.id, at: checkedDate(for: status, interval: config.checkIntervalSeconds, now: now))
            switch status {
            case .mounted:
                networkFailedVolumeIDs.remove(config.id)
                try? alertStore.resolve(volumeID: config.id)
            case .failed(let message):
                try? alertStore.record(volumeID: config.id, volumeName: config.name, message: message, date: now)
            case .unmounted, .checking:
                break
            }
        } catch {
            scheduler.markChecked(volumeID: config.id, at: checkedDate(for: error, interval: config.checkIntervalSeconds, now: now))
            let message = CommandResult.redacted(error.localizedDescription)
            try? alertStore.record(volumeID: config.id, volumeName: config.name, message: message, date: now)
            fputs("AutoVolumeAgent mount error for \(config.name): \(message)\n", stderr)
        }
    }
}

func serverReachability(_ config: VolumeConfig) throws -> ConnectivityCheckResult {
    let password = config.protocolType == .webdav ? try credentialStore.password(for: config.id) : nil
    let plan = try connectivityTester.testPlan(for: config, password: password)
    let result = try commandRunner.run(plan).redacting(secrets: [password])
    return connectivityTester.checkResult(for: config, result: result)
}

func openMountedVolume(_ config: VolumeConfig) {
    guard mountPlanner.shouldOpenFinderAfterMount(for: config) else { return }
    let browsePath = mountPlanner.resolvedBrowsePath(for: config)
    Thread.sleep(forTimeInterval: 0.6)
    cleanupFinderWindows(config, resolvedBrowsePath: browsePath)
    let plan = mountPlanner.finderRevealPlan(for: config, resolvedBrowsePath: browsePath)
    _ = try? commandRunner.run(plan)
}

func cleanupFinderWindows(_ config: VolumeConfig, resolvedBrowsePath: String) {
    let paths = mountPlanner.finderCleanupPaths(for: config, resolvedBrowsePath: resolvedBrowsePath)
    guard !paths.isEmpty else { return }
    let script = """
    tell application "Finder"
        repeat with windowPath in {\(paths.map { "\"\(appleScriptEscaped($0))\"" }.joined(separator: ", "))}
            repeat with finderWindow in windows
                try
                    if POSIX path of (target of finderWindow as alias) is (windowPath as text) then
                        close finderWindow
                    end if
                end try
            end repeat
        end repeat
    end tell
    """
    _ = try? commandRunner.run(CommandPlan(executable: "/usr/bin/osascript", arguments: ["-"], standardInput: script))
}

func appleScriptEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

func checkedDate(for status: VolumeStatus, interval: TimeInterval, now: Date) -> Date {
    switch status {
    case .mounted:
        return now
    case .unmounted, .checking, .failed:
        if case .failed(let message) = status, isNetworkFailure(message) {
            return retryCheckedDate(interval: interval, retryInterval: 60, now: now)
        }
        return now
    }
}

func checkedDate(for error: Error, interval: TimeInterval, now: Date) -> Date {
    if isNetworkFailure(error.localizedDescription) {
        return retryCheckedDate(interval: interval, retryInterval: 60, now: now)
    }
    return now
}

func retryCheckedDate(interval: TimeInterval, retryInterval: TimeInterval, now: Date) -> Date {
    return now.addingTimeInterval(retryInterval - interval)
}

func isNetworkFailure(_ message: String) -> Bool {
    let normalized = message.lowercased()
    return [
        "network is down",
        "network is unreachable",
        "no route to host",
        "host is down",
        "timed out",
        "timeout",
        "could not connect",
        "couldn't connect",
        "connection refused",
        "connection reset",
        "not responding",
        "server unavailable"
    ].contains { normalized.contains($0) }
}

func parsedSessionFilePath(arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "--session-file"),
          arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

func appSessionIsActive() -> Bool {
    guard let sessionFilePath else { return true }
    guard let rawPID = try? String(contentsOfFile: sessionFilePath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
        let pid = Int32(rawPID) else {
        return false
    }
    return kill(pid, 0) == 0 || errno == EPERM
}

func cleanupOrphanedLaunchAgent() {
    if let sessionFilePath {
        try? FileManager.default.removeItem(atPath: sessionFilePath)
    }
    if let launchAgentsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("LaunchAgents", isDirectory: true) {
        try? FileManager.default.removeItem(at: launchAgentsDirectory.appendingPathComponent("\(launchAgentLabel).plist"))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["bootout", "gui/\(getuid())/\(launchAgentLabel)"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
}

let timer = Timer(timeInterval: 60, repeats: true) { _ in
    runOnce()
}

RunLoop.main.add(timer, forMode: .default)
RunLoop.main.run()
