import Foundation

public final class AgentEngine {
    private let mountState: MountStateProvider
    private let credentialStore: CredentialStore
    private let commandRunner: CommandRunner
    private let mountPlanner: MountPlanner
    private let mountExposure: MountExposure

    public init(
        mountState: MountStateProvider,
        credentialStore: CredentialStore,
        commandRunner: CommandRunner,
        mountPlanner: MountPlanner,
        mountExposure: MountExposure = MountExposure()
    ) {
        self.mountState = mountState
        self.credentialStore = credentialStore
        self.commandRunner = commandRunner
        self.mountPlanner = mountPlanner
        self.mountExposure = mountExposure
    }

    public func check(_ config: VolumeConfig) throws -> VolumeStatus {
        guard config.isEnabled else { return .unmounted }
        if mountState.isMounted(config: config) { return .mounted }

        let password = try credentialStore.password(for: config.id)
        try mountExposure.prepare(config: config, planner: mountPlanner)
        let result = try commandRunner
            .run(try mountPlanner.mountPlan(for: config, password: password, suppressesUserInterface: true))
            .redacting(secrets: [password])
        if result.exitCode == 0 {
            try mountExposure.expose(config: config, planner: mountPlanner)
            return .mounted
        }
        let message = result.stderr.isEmpty ? "Mount command failed with exit code \(result.exitCode)." : result.stderr
        return .failed(message: message)
    }
}
