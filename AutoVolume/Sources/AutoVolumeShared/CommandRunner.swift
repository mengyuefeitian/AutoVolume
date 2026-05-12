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
}

public protocol CommandRunner {
    func run(_ plan: CommandPlan) throws -> CommandResult
}

public final class ProcessCommandRunner: CommandRunner {
    public init() {}

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
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
