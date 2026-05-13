import Foundation
import AutoVolumeShared

let store = JSONConfigStore()
let engine = AgentEngine(
    mountState: FileSystemMountStateProvider(),
    credentialStore: KeychainCredentialStore(allowsAuthenticationUI: false),
    commandRunner: ProcessCommandRunner(),
    mountPlanner: MountPlanner()
)
var scheduler = CheckScheduler()
let alertStore = AlertStore()

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
            let status = try engine.check(config)
            scheduler.markChecked(volumeID: config.id, at: checkedDate(for: status, interval: config.checkIntervalSeconds, now: now))
            switch status {
            case .mounted:
                try? alertStore.resolve(volumeID: config.id)
            case .failed(let message):
                try? alertStore.record(volumeID: config.id, volumeName: config.name, message: message, date: now)
            case .unmounted, .checking:
                break
            }
        } catch {
            scheduler.markChecked(volumeID: config.id, at: checkedDate(for: error, interval: config.checkIntervalSeconds, now: now))
            try? alertStore.record(volumeID: config.id, volumeName: config.name, message: error.localizedDescription, date: now)
            fputs("AutoVolumeAgent mount error for \(config.name): \(error)\n", stderr)
        }
    }
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
