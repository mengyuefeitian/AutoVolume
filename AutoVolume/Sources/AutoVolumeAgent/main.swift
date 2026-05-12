import Foundation
import AutoVolumeShared

let store = JSONConfigStore()
let engine = AgentEngine(
    mountState: FileSystemMountStateProvider(),
    credentialStore: KeychainCredentialStore(),
    commandRunner: ProcessCommandRunner(),
    mountPlanner: MountPlanner()
)
var scheduler = CheckScheduler()

func runOnce() {
    do {
        let configs = try store.load()
        let now = Date()
        for config in configs where config.isEnabled {
            guard scheduler.isDue(volumeID: config.id, interval: config.checkIntervalSeconds, now: now) else {
                continue
            }
            _ = try engine.check(config)
            scheduler.markChecked(volumeID: config.id, at: now)
        }
    } catch {
        fputs("AutoVolumeAgent error: \(error)\n", stderr)
    }
}

let timer = Timer(timeInterval: 15, repeats: true) { _ in
    runOnce()
}

RunLoop.main.add(timer, forMode: .default)
runOnce()
RunLoop.main.run()
