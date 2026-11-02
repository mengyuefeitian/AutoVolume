import Foundation

public struct CommandPlan: Equatable {
    public var executable: String
    public var arguments: [String]
    public var standardInput: String?

    public init(executable: String, arguments: [String], standardInput: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
    }
}

public struct CommandResult: Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public func redacting(secrets: [String?]) -> CommandResult {
        CommandResult(
            exitCode: exitCode,
            stdout: Self.redacted(stdout, secrets: secrets),
            stderr: Self.redacted(stderr, secrets: secrets)
        )
    }

    public static func redacted(_ value: String, secrets: [String?] = []) -> String {
        var redactedValue = value
        for secret in secrets.compactMap({ $0 }).filter({ !$0.isEmpty }) {
            redactedValue = redactedValue.replacingOccurrences(of: secret, with: "<redacted>")
        }
        redactedValue = redactedValue.replacingOccurrences(
            of: #"//([^/\s:@]+):([^@\s]+)@"#,
            with: #"//$1:<redacted>@"#,
            options: .regularExpression
        )
        redactedValue = redactedValue.replacingOccurrences(
            of: #"://([^/\s:@]+):([^@\s]+)@"#,
            with: #"://$1:<redacted>@"#,
            options: .regularExpression
        )
        return redactedValue
    }
}

public protocol CommandRunner {
    func run(_ plan: CommandPlan) throws -> CommandResult
}

public final class ProcessCommandRunner: CommandRunner {
    /// Exit code reported for a command that was killed at its timeout (the `timeout(1)` convention).
    public static let timedOutExitCode: Int32 = 124

    private let timeout: TimeInterval?

    /// With a `timeout`, a command that has not finished by then is killed and reported as failed. The
    /// agent sets one: a mount, unmount or diskutil call against a hard NFS mount whose server is away
    /// can block forever, and an unbounded call would freeze every volume's checks behind it.
    public init(timeout: TimeInterval? = nil) {
        self.timeout = timeout
    }

    public func run(_ plan: CommandPlan) throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if plan.standardInput != nil {
            process.standardInput = stdin
        }
        try process.run()
        if let standardInput = plan.standardInput {
            stdin.fileHandleForWriting.write(Data(standardInput.utf8))
            try? stdin.fileHandleForWriting.close()
        }

        guard let timeout else {
            process.waitUntilExit()
            return CommandResult(
                exitCode: process.terminationStatus,
                stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        }

        // Bounded wait. The process is polled rather than joined, for two reasons: the run loop keeps
        // turning while we wait (the agent depends on that, see main.swift), and if the process cannot be
        // killed (stuck in the kernel on a dead NFS server) we give up on it instead of hanging with it.
        let out = TimedCommand.Collector(reading: stdout.fileHandleForReading)
        let err = TimedCommand.Collector(reading: stderr.fileHandleForReading)
        let deadline = Date().addingTimeInterval(timeout)
        var signalled = false
        while process.isRunning {
            let now = Date()
            if now >= deadline + Self.killGrace { break }
            if now >= deadline, !signalled {
                signalled = true
                process.terminate()
            } else if now >= deadline + Self.killGrace / 2, signalled {
                kill(process.processIdentifier, SIGKILL)
            }
            if Thread.isMainThread {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let outData = out.wait(upTo: 1)
        let errData = err.wait(upTo: 1)
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        // A command that finished by itself just as the deadline passed is a success, not a timeout:
        // only a process that was ended by our signal (or that never ended) counts.
        let killedByUs = signalled && (process.isRunning || process.terminationReason == .uncaughtSignal)
        if killedByUs {
            let name = (plan.executable as NSString).lastPathComponent
            return CommandResult(exitCode: Self.timedOutExitCode, stdout: String(data: outData, encoding: .utf8) ?? "", stderr: "\(name) timed out after \(Int(timeout)) seconds")
        }
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// How long a command that ignored SIGTERM gets before it is abandoned.
    private static let killGrace: TimeInterval = 2
}
