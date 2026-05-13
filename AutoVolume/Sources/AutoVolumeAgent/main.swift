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
            scheduler.markChecked(volumeID: config.id, at: retryCheckedDate(interval: config.checkIntervalSeconds, now: now))
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
        return retryCheckedDate(interval: interval, now: now)
    }
}

func retryCheckedDate(interval: TimeInterval, now: Date) -> Date {
    let retryInterval = min(interval, 60)
    return now.addingTimeInterval(retryInterval - interval)
}

let timer = Timer(timeInterval: 15, repeats: true) { _ in
    runOnce()
}

RunLoop.main.add(timer, forMode: .default)
runOnce()
RunLoop.main.run()
