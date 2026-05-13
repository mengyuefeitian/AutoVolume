import Foundation

public final class AgentEngine {
    private let mountState: MountStateProvider
    private let credentialStore: CredentialStore
    private let commandRunner: CommandRunner
    private let mountPlanner: MountPlanner

    public init(
        mountState: MountStateProvider,
        credentialStore: CredentialStore,
        commandRunner: CommandRunner,
        mountPlanner: MountPlanner
    ) {
        self.mountState = mountState
        self.credentialStore = credentialStore
        self.commandRunner = commandRunner
        self.mountPlanner = mountPlanner
    }

    public func check(_ config: VolumeConfig) throws -> VolumeStatus {
        guard config.isEnabled else { return .unmounted }
        if mountState.isMounted(config: config) { return .mounted }

        let password = try credentialStore.password(for: config.id)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: config.mountPoint),
            withIntermediateDirectories: true
        )
        let result = try commandRunner.run(try mountPlanner.mountPlan(for: config, password: password, suppressesUserInterface: true))
        if result.exitCode == 0 {
            return .mounted
        }
        let message = result.stderr.isEmpty ? "Mount command failed with exit code \(result.exitCode)." : result.stderr
        return .failed(message: message)
    }
}
