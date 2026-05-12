import Foundation
import AutoVolumeShared

let store = JSONConfigStore()
let engine = AgentEngine(
    mountState: FileSystemMountStateProvider(),
    credentialStore: KeychainCredentialStore(),
    commandRunner: ProcessCommandRunner(),
    mountPlanner: MountPlanner()
)

func runOnce() {
    do {
        let configs = try store.load()
        for config in configs where config.isEnabled {
            _ = try engine.check(config)
        }
    } catch {
        fputs("AutoVolumeAgent error: \(error)\n", stderr)
    }
}

let timer = Timer(timeInterval: 60, repeats: true) { _ in
    runOnce()
}

RunLoop.main.add(timer, forMode: .default)
runOnce()
RunLoop.main.run()
