import Foundation

public final class AgentEngine {
    private let mountState: MountStateProvider
    private let credentialStore: CredentialStore
    private let commandRunner: CommandRunner
    private let mountPlanner: MountPlanner
    private let mountExposure: MountExposure
    private let validatesAfterMount: Bool
    private let mountTable: SystemMountTable?

    public init(
        mountState: MountStateProvider,
        credentialStore: CredentialStore,
        commandRunner: CommandRunner,
        mountPlanner: MountPlanner,
        mountExposure: MountExposure = MountExposure(),
        validatesAfterMount: Bool = false,
        mountTable: SystemMountTable? = nil
    ) {
        self.mountState = mountState
        self.credentialStore = credentialStore
        self.commandRunner = commandRunner
        self.mountPlanner = mountPlanner
        self.mountExposure = mountExposure
        self.validatesAfterMount = validatesAfterMount
        self.mountTable = mountTable
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
        try prepareMountPoint(for: config)
        let result = try runMount(config: config, password: password)
        if result.exitCode == 0 {
            try mountExposure.expose(config: config, planner: mountPlanner)
            guard !validatesAfterMount || mountState.isMounted(config: config) else {
                return try retryAfterStaleMount(config: config, password: password)
            }
            return .mounted
        }
        guard result.stderr.isEmpty else {
            // Raw command stderr, not a fixed sentence — nothing to key.
            return .failed(message: result.stderr)
        }
        return mountCommandFailedStatus(exitCode: result.exitCode)
    }

    /// A dead mount that still occupies the mount point makes the directory impossible to create
    /// ("The file “video” couldn’t be saved in the folder “Volumes”"). Without this the agent failed the
    /// same way on every check — 73 times in an hour in issue #2 — until the Mac was rebooted. Clear
    /// whatever is mounted there and try once more; if it is still unusable the error surfaces.
    ///
    /// Only a mount sitting at exactly the path that could not be prepared is cleared. The same share
    /// mounted somewhere else (say by Finder) is the user's, and an unrelated error such as a permission
    /// problem must never force-eject it.
    private func prepareMountPoint(for config: VolumeConfig) throws {
        do {
            try mountExposure.prepare(config: config, planner: mountPlanner)
        } catch {
            let mountPoint = mountPlanner.effectiveMountPoint(for: config)
            let table = (mountTable ?? SystemMountTable()).snapshot()
            guard table.hasMount(atPath: mountPoint) else { throw error }
            _ = try? commandRunner.run(mountPlanner.unmountPlan(mountPoint: mountPoint))
            _ = try? commandRunner.run(mountPlanner.forceUnmountPlan(mountPoint: mountPoint))
            try mountExposure.prepare(config: config, planner: mountPlanner)
        }
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
            guard result.stderr.isEmpty else {
                return .failed(message: result.stderr)
            }
            return mountCommandFailedStatus(exitCode: result.exitCode)
        }
        try mountExposure.expose(config: config, planner: mountPlanner)
        guard mountState.isMounted(config: config) else {
            return .failed(
                message: L10n.t(.errorAgentMountUnresponsive, args: [], in: .en),
                key: L10nKey.errorAgentMountUnresponsive.rawValue
            )
        }
        return .mounted
    }

    private func mountCommandFailedStatus(exitCode: Int32) -> VolumeStatus {
        let args = [String(exitCode)]
        return .failed(
            message: L10n.t(.errorAgentMountCommandFailed, args: args, in: .en),
            key: L10nKey.errorAgentMountCommandFailed.rawValue,
            args: args
        )
    }

    private func isOccupiedMountPointError(_ result: CommandResult) -> Bool {
        let message = "\(result.stdout)\n\(result.stderr)".lowercased()
        return message.contains("file exists") || message.contains("resource busy") || message.contains("already mounted")
    }
}
