import Foundation
import AutoVolumeShared

let store = JSONConfigStore()
let credentialStore = EncryptedFileCredentialStore()
let commandRunner = ProcessCommandRunner()
let connectivityTester = ConnectivityTester()
let mountStateProvider = FileSystemMountStateProvider(validatesResponsiveness: false)
let engine = AgentEngine(
    mountState: mountStateProvider,
    credentialStore: credentialStore,
    commandRunner: commandRunner,
    mountPlanner: MountPlanner()
)
let mountPlanner = MountPlanner()
var scheduler = CheckScheduler()
let alertStore = AlertStore()
var networkFailedVolumeIDs = Set<UUID>()

func runOnce() {
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
            guard try serverIsReachable(config) else {
                networkFailedVolumeIDs.insert(config.id)
                scheduler.markChecked(volumeID: config.id, at: retryCheckedDate(interval: config.checkIntervalSeconds, retryInterval: 60, now: now))
                try? alertStore.record(volumeID: config.id, volumeName: config.name, message: "Server is not reachable. AutoVolume will retry after the network returns.", date: now)
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
                if !wasMounted, status == .mounted {
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

func serverIsReachable(_ config: VolumeConfig) throws -> Bool {
    let password = config.protocolType == .webdav ? try credentialStore.password(for: config.id) : nil
    let plan = try connectivityTester.testPlan(for: config, password: password)
    let result = try commandRunner.run(plan).redacting(secrets: [password])
    return result.exitCode == 0
}

func openMountedVolume(_ config: VolumeConfig) {
    let browsePath = mountPlanner.browsePath(for: config)
    Thread.sleep(forTimeInterval: 0.6)
    let script = """
    tell application "Finder"
        activate
        make new Finder window to (POSIX file "\(appleScriptEscaped(browsePath))" as alias)
    end tell
    """
    let plan = CommandPlan(executable: "/usr/bin/osascript", arguments: ["-"], standardInput: script)
    _ = try? commandRunner.run(plan)
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

let timer = Timer(timeInterval: 15, repeats: true) { _ in
    runOnce()
}

RunLoop.main.add(timer, forMode: .default)
runOnce()
RunLoop.main.run()
