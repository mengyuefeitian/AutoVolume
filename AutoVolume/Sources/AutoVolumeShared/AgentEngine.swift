import Foundation

public final class AgentEngine {
    private let mountState: MountStateProvider
    private let credentialStore: CredentialStore
    private let commandRunner: CommandRunner
    private let mountPlanner: MountPlanner
    private let mountExposure: MountExposure
    private let validatesAfterMount: Bool

    public init(
        mountState: MountStateProvider,
        credentialStore: CredentialStore,
        commandRunner: CommandRunner,
        mountPlanner: MountPlanner,
        mountExposure: MountExposure = MountExposure(),
        validatesAfterMount: Bool = false
    ) {
        self.mountState = mountState
        self.credentialStore = credentialStore
        self.commandRunner = commandRunner
        self.mountPlanner = mountPlanner
        self.mountExposure = mountExposure
        self.validatesAfterMount = validatesAfterMount
    }

    public func check(_ config: VolumeConfig) throws -> VolumeStatus {
        guard config.isEnabled else { return .unmounted }
        if mountState.isMounted(config: config) { return .mounted }

        return try mount(config)
    }

    public func reconnect(_ config: VolumeConfig) throws -> VolumeStatus {
        guard config.isEnabled else { return .unmounted }
        let mountPoint = mountPlanner.unmountTarget(for: config)
        _ = try? commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
        _ = try? commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
        return try mount(config)
    }

    private func mount(_ config: VolumeConfig) throws -> VolumeStatus {
        let password = try credentialStore.password(for: config.id)
        try mountExposure.prepare(config: config, planner: mountPlanner)
        let result = try runMount(config: config, password: password)
        if result.exitCode == 0 {
            try mountExposure.expose(config: config, planner: mountPlanner)
            guard !validatesAfterMount || mountState.isMounted(config: config) else {
                return try retryAfterStaleMount(config: config, password: password)
            }
            return .mounted
        }
        let message = result.stderr.isEmpty ? "Mount command failed with exit code \(result.exitCode)." : result.stderr
        return .failed(message: message)
    }

    private func runMount(config: VolumeConfig, password: String?) throws -> CommandResult {
        let plan = try mountPlanner.mountPlan(for: config, password: password, suppressesUserInterface: true)
        let result = try commandRunner.run(plan).redacting(secrets: [password])
        guard result.exitCode != 0, isOccupiedMountPointError(result) else {
            return result
        }

        let mountPoint = mountPlanner.effectiveMountPoint(for: config)
        _ = try? commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
        _ = try? commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
        return try commandRunner.run(plan).redacting(secrets: [password])
    }

    private func retryAfterStaleMount(config: VolumeConfig, password: String?) throws -> VolumeStatus {
        let mountPoint = mountPlanner.unmountTarget(for: config)
        _ = try? commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
        _ = try? commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
        let result = try runMount(config: config, password: password)
        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? "Mount command failed with exit code \(result.exitCode)." : result.stderr
            return .failed(message: message)
        }
        try mountExposure.expose(config: config, planner: mountPlanner)
        guard mountState.isMounted(config: config) else {
            return .failed(message: "Mount command succeeded, but the mounted volume did not respond. AutoVolume will retry on the next check.")
        }
        return .mounted
    }

    private func isOccupiedMountPointError(_ result: CommandResult) -> Bool {
        let message = "\(result.stdout)\n\(result.stderr)".lowercased()
        return message.contains("file exists") || message.contains("resource busy") || message.contains("already mounted")
    }
}
