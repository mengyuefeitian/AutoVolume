# AutoVolume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first AutoVolume（智卷） macOS MVP: a menu bar configuration app plus a user LaunchAgent that checks and remounts SMB, WebDAV, AFP, and NFS volumes.

**Architecture:** Create a Swift Package with three products: `AutoVolumeApp`, `AutoVolumeAgent`, and `AutoVolumeShared`. Shared owns models, storage, credentials, command execution, mount state, and scheduling logic. The app writes configuration and displays status; the agent reads configuration, checks mounted state, and reconnects missing volumes.

**Tech Stack:** Swift 5.10+, SwiftPM, SwiftUI, AppKit, Foundation, Security Keychain APIs, XCTest, macOS user LaunchAgent plist.

---

## File Structure

- `AutoVolume/Package.swift`: SwiftPM package definition.
- `AutoVolume/Sources/AutoVolumeShared/Models.swift`: volume protocol, config, status, and error category models.
- `AutoVolume/Sources/AutoVolumeShared/ConfigStore.swift`: JSON configuration persistence.
- `AutoVolume/Sources/AutoVolumeShared/CredentialStore.swift`: credential abstraction plus Keychain implementation.
- `AutoVolume/Sources/AutoVolumeShared/CommandRunner.swift`: process execution abstraction.
- `AutoVolume/Sources/AutoVolumeShared/MountPlanning.swift`: protocol-specific mount and unmount command planning.
- `AutoVolume/Sources/AutoVolumeShared/MountState.swift`: mounted-volume detection abstraction and implementation.
- `AutoVolume/Sources/AutoVolumeShared/AgentEngine.swift`: check/reconnect decision logic.
- `AutoVolume/Sources/AutoVolumeAgent/main.swift`: background agent entrypoint.
- `AutoVolume/Sources/AutoVolumeApp/AutoVolumeApp.swift`: menu bar app entrypoint.
- `AutoVolume/Sources/AutoVolumeApp/ContentView.swift`: glass-style volume list and controls.
- `AutoVolume/Sources/AutoVolumeApp/VolumeEditorView.swift`: add/edit form.
- `AutoVolume/Sources/AutoVolumeApp/AppViewModel.swift`: UI state and config actions.
- `AutoVolume/Resources/com.autovolume.agent.plist`: LaunchAgent template.
- `AutoVolume/Tests/AutoVolumeSharedTests/*.swift`: shared logic tests.
- `AutoVolume/Tests/AutoVolumeAppTests/*.swift`: app view model tests.

## Task 1: Scaffold Swift Package

**Files:**
- Create: `AutoVolume/Package.swift`
- Create: `AutoVolume/Sources/AutoVolumeShared/Models.swift`
- Create: `AutoVolume/Sources/AutoVolumeAgent/main.swift`
- Create: `AutoVolume/Sources/AutoVolumeApp/AutoVolumeApp.swift`
- Create: `AutoVolume/Tests/AutoVolumeSharedTests/ModelsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AutoVolume/Tests/AutoVolumeSharedTests/ModelsTests.swift`:

```swift
import XCTest
@testable import AutoVolumeShared

final class ModelsTests: XCTestCase {
    func testVolumeConfigRoundTripsThroughJSON() throws {
        let config = VolumeConfig(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Design NAS",
            protocolType: .smb,
            server: "files.example.com",
            remotePath: "design",
            username: "xiaoan",
            mountPoint: "/Volumes/Design",
            checkIntervalSeconds: 300,
            isEnabled: true
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VolumeConfig.self, from: data)

        XCTAssertEqual(decoded, config)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
cd AutoVolume
swift test --filter ModelsTests/testVolumeConfigRoundTripsThroughJSON
```

Expected: FAIL because `Package.swift` or `AutoVolumeShared` does not exist.

- [ ] **Step 3: Create the package and minimal models**

Create `AutoVolume/Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AutoVolume",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AutoVolumeShared", targets: ["AutoVolumeShared"]),
        .executable(name: "AutoVolumeAgent", targets: ["AutoVolumeAgent"]),
        .executable(name: "AutoVolumeApp", targets: ["AutoVolumeApp"])
    ],
    targets: [
        .target(name: "AutoVolumeShared"),
        .executableTarget(name: "AutoVolumeAgent", dependencies: ["AutoVolumeShared"]),
        .executableTarget(name: "AutoVolumeApp", dependencies: ["AutoVolumeShared"]),
        .testTarget(name: "AutoVolumeSharedTests", dependencies: ["AutoVolumeShared"]),
        .testTarget(name: "AutoVolumeAppTests", dependencies: ["AutoVolumeApp", "AutoVolumeShared"])
    ]
)
```

Create `AutoVolume/Sources/AutoVolumeShared/Models.swift`:

```swift
import Foundation

public enum VolumeProtocol: String, Codable, CaseIterable, Identifiable {
    case smb
    case webdav
    case afp
    case nfs

    public var id: String { rawValue }
}

public struct VolumeConfig: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var protocolType: VolumeProtocol
    public var server: String
    public var remotePath: String
    public var username: String?
    public var mountPoint: String
    public var checkIntervalSeconds: TimeInterval
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        protocolType: VolumeProtocol,
        server: String,
        remotePath: String,
        username: String?,
        mountPoint: String,
        checkIntervalSeconds: TimeInterval,
        isEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.protocolType = protocolType
        self.server = server
        self.remotePath = remotePath
        self.username = username
        self.mountPoint = mountPoint
        self.checkIntervalSeconds = checkIntervalSeconds
        self.isEnabled = isEnabled
    }
}

public enum VolumeStatus: Codable, Equatable {
    case mounted
    case unmounted
    case checking
    case failed(message: String)
}

public enum MountErrorCategory: String, Codable, Equatable {
    case authenticationFailed
    case networkUnavailable
    case invalidMountPoint
    case commandFailed
    case unknown
}
```

Create `AutoVolume/Sources/AutoVolumeAgent/main.swift`:

```swift
import Foundation
import AutoVolumeShared

print("AutoVolumeAgent ready")
RunLoop.main.run()
```

Create `AutoVolume/Sources/AutoVolumeApp/AutoVolumeApp.swift`:

```swift
import SwiftUI
import AutoVolumeShared

@main
struct AutoVolumeApp: App {
    var body: some Scene {
        MenuBarExtra("AutoVolume", systemImage: "externaldrive.connected.to.line.below") {
            Text("AutoVolume")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
cd AutoVolume
swift test --filter ModelsTests/testVolumeConfigRoundTripsThroughJSON
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AutoVolume/Package.swift AutoVolume/Sources AutoVolume/Tests
git commit -m "feat: scaffold AutoVolume package"
```

## Task 2: Configuration Storage

**Files:**
- Create: `AutoVolume/Sources/AutoVolumeShared/ConfigStore.swift`
- Create: `AutoVolume/Tests/AutoVolumeSharedTests/ConfigStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AutoVolume/Tests/AutoVolumeSharedTests/ConfigStoreTests.swift`:

```swift
import XCTest
@testable import AutoVolumeShared

final class ConfigStoreTests: XCTestCase {
    func testSaveAndLoadVolumes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONConfigStore(directory: directory)
        let volume = VolumeConfig(
            name: "NAS",
            protocolType: .smb,
            server: "nas.local",
            remotePath: "team",
            username: "mei",
            mountPoint: "/Volumes/Team",
            checkIntervalSeconds: 120,
            isEnabled: true
        )

        try store.save([volume])
        let loaded = try store.load()

        XCTAssertEqual(loaded, [volume])
    }

    func testLoadReturnsEmptyArrayWhenConfigDoesNotExist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONConfigStore(directory: directory)

        XCTAssertEqual(try store.load(), [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd AutoVolume
swift test --filter ConfigStoreTests
```

Expected: FAIL because `JSONConfigStore` does not exist.

- [ ] **Step 3: Implement JSON config store**

Create `AutoVolume/Sources/AutoVolumeShared/ConfigStore.swift`:

```swift
import Foundation

public protocol ConfigStore {
    func load() throws -> [VolumeConfig]
    func save(_ configs: [VolumeConfig]) throws
}

public final class JSONConfigStore: ConfigStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL = JSONConfigStore.defaultDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoVolume", isDirectory: true)
    }

    public var fileURL: URL {
        directory.appendingPathComponent("volumes.json")
    }

    public func load() throws -> [VolumeConfig] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([VolumeConfig].self, from: data)
    }

    public func save(_ configs: [VolumeConfig]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(configs)
        try data.write(to: fileURL, options: [.atomic])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
cd AutoVolume
swift test --filter ConfigStoreTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AutoVolume/Sources/AutoVolumeShared/ConfigStore.swift AutoVolume/Tests/AutoVolumeSharedTests/ConfigStoreTests.swift
git commit -m "feat: add volume config storage"
```

## Task 3: Credential Store

**Files:**
- Create: `AutoVolume/Sources/AutoVolumeShared/CredentialStore.swift`
- Create: `AutoVolume/Tests/AutoVolumeSharedTests/CredentialStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AutoVolume/Tests/AutoVolumeSharedTests/CredentialStoreTests.swift`:

```swift
import XCTest
@testable import AutoVolumeShared

final class CredentialStoreTests: XCTestCase {
    func testInMemoryCredentialStoreSavesReadsAndDeletesPassword() throws {
        let store = InMemoryCredentialStore()
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        try store.savePassword("secret", for: id)
        XCTAssertEqual(try store.password(for: id), "secret")

        try store.deletePassword(for: id)
        XCTAssertNil(try store.password(for: id))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd AutoVolume
swift test --filter CredentialStoreTests
```

Expected: FAIL because `InMemoryCredentialStore` does not exist.

- [ ] **Step 3: Implement credential store protocol, in-memory store, and Keychain store**

Create `AutoVolume/Sources/AutoVolumeShared/CredentialStore.swift`:

```swift
import Foundation
import Security

public protocol CredentialStore {
    func password(for volumeID: UUID) throws -> String?
    func savePassword(_ password: String, for volumeID: UUID) throws
    func deletePassword(for volumeID: UUID) throws
}

public enum CredentialStoreError: Error, Equatable {
    case keychainFailure(OSStatus)
    case invalidPasswordData
}

public final class InMemoryCredentialStore: CredentialStore {
    private var values: [UUID: String] = [:]

    public init() {}

    public func password(for volumeID: UUID) throws -> String? {
        values[volumeID]
    }

    public func savePassword(_ password: String, for volumeID: UUID) throws {
        values[volumeID] = password
    }

    public func deletePassword(for volumeID: UUID) throws {
        values.removeValue(forKey: volumeID)
    }
}

public final class KeychainCredentialStore: CredentialStore {
    private let service = "com.autovolume.credentials"

    public init() {}

    public func password(for volumeID: UUID) throws -> String? {
        var query = baseQuery(for: volumeID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychainFailure(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidPasswordData
        }
        return password
    }

    public func savePassword(_ password: String, for volumeID: UUID) throws {
        try deletePassword(for: volumeID)
        var item = baseQuery(for: volumeID)
        item[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.keychainFailure(status) }
    }

    public func deletePassword(for volumeID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: volumeID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(status)
        }
    }

    private func baseQuery(for volumeID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: volumeID.uuidString
        ]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cd AutoVolume
swift test --filter CredentialStoreTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AutoVolume/Sources/AutoVolumeShared/CredentialStore.swift AutoVolume/Tests/AutoVolumeSharedTests/CredentialStoreTests.swift
git commit -m "feat: add credential storage"
```

## Task 4: Command Planning and Execution

**Files:**
- Create: `AutoVolume/Sources/AutoVolumeShared/CommandRunner.swift`
- Create: `AutoVolume/Sources/AutoVolumeShared/MountPlanning.swift`
- Create: `AutoVolume/Tests/AutoVolumeSharedTests/MountPlanningTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AutoVolume/Tests/AutoVolumeSharedTests/MountPlanningTests.swift`:

```swift
import XCTest
@testable import AutoVolumeShared

final class MountPlanningTests: XCTestCase {
    func testSMBPlanUsesOpenWithSMBURL() throws {
        let config = VolumeConfig(name: "Team", protocolType: .smb, server: "nas.local", remotePath: "team", username: "mei", mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)

        let plan = try MountPlanner().mountPlan(for: config, password: "secret")

        XCTAssertEqual(plan.executable, "/usr/bin/open")
        XCTAssertEqual(plan.arguments, ["smb://mei@nas.local/team"])
    }

    func testNFSPlanUsesMountNFS() throws {
        let config = VolumeConfig(name: "Exports", protocolType: .nfs, server: "nas.local", remotePath: "/exports/team", username: nil, mountPoint: "/Volumes/Exports", checkIntervalSeconds: 60, isEnabled: true)

        let plan = try MountPlanner().mountPlan(for: config, password: nil)

        XCTAssertEqual(plan.executable, "/sbin/mount_nfs")
        XCTAssertEqual(plan.arguments, ["nas.local:/exports/team", "/Volumes/Exports"])
    }

    func testUnmountPlanUsesDiskutil() {
        let plan = MountPlanner().unmountPlan(mountPoint: "/Volumes/Team")

        XCTAssertEqual(plan.executable, "/usr/sbin/diskutil")
        XCTAssertEqual(plan.arguments, ["unmount", "/Volumes/Team"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd AutoVolume
swift test --filter MountPlanningTests
```

Expected: FAIL because `MountPlanner` does not exist.

- [ ] **Step 3: Implement command runner and mount planner**

Create `AutoVolume/Sources/AutoVolumeShared/CommandRunner.swift`:

```swift
import Foundation

public struct CommandPlan: Equatable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct CommandResult: Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
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
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
```

Create `AutoVolume/Sources/AutoVolumeShared/MountPlanning.swift`:

```swift
import Foundation

public enum MountPlanningError: Error, Equatable {
    case invalidURL
}

public struct MountPlanner {
    public init() {}

    public func mountPlan(for config: VolumeConfig, password: String?) throws -> CommandPlan {
        switch config.protocolType {
        case .smb:
            return CommandPlan(executable: "/usr/bin/open", arguments: [try urlString(scheme: "smb", config: config)])
        case .webdav:
            return CommandPlan(executable: "/usr/bin/open", arguments: [try urlString(scheme: "webdav", config: config)])
        case .afp:
            return CommandPlan(executable: "/usr/bin/open", arguments: [try urlString(scheme: "afp", config: config)])
        case .nfs:
            return CommandPlan(executable: "/sbin/mount_nfs", arguments: ["\(config.server):\(config.remotePath)", config.mountPoint])
        }
    }

    public func unmountPlan(mountPoint: String) -> CommandPlan {
        CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["unmount", mountPoint])
    }

    private func urlString(scheme: String, config: VolumeConfig) throws -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = config.server
        components.path = "/" + config.remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let username = config.username, !username.isEmpty {
            components.user = username
        }
        guard let value = components.url?.absoluteString else { throw MountPlanningError.invalidURL }
        return value
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
cd AutoVolume
swift test --filter MountPlanningTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AutoVolume/Sources/AutoVolumeShared/CommandRunner.swift AutoVolume/Sources/AutoVolumeShared/MountPlanning.swift AutoVolume/Tests/AutoVolumeSharedTests/MountPlanningTests.swift
git commit -m "feat: add mount command planning"
```

## Task 5: Mount State and Agent Decision Logic

**Files:**
- Create: `AutoVolume/Sources/AutoVolumeShared/MountState.swift`
- Create: `AutoVolume/Sources/AutoVolumeShared/AgentEngine.swift`
- Create: `AutoVolume/Tests/AutoVolumeSharedTests/AgentEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AutoVolume/Tests/AutoVolumeSharedTests/AgentEngineTests.swift`:

```swift
import XCTest
@testable import AutoVolumeShared

final class AgentEngineTests: XCTestCase {
    func testDisabledVolumeIsSkipped() throws {
        let config = VolumeConfig(name: "Off", protocolType: .smb, server: "nas.local", remotePath: "off", username: nil, mountPoint: "/Volumes/Off", checkIntervalSeconds: 60, isEnabled: false)
        let engine = AgentEngine(mountState: FakeMountStateProvider(isMounted: false), credentialStore: InMemoryCredentialStore(), commandRunner: RecordingCommandRunner(), mountPlanner: MountPlanner())

        let status = try engine.check(config)

        XCTAssertEqual(status, .unmounted)
    }

    func testMountedVolumeStaysMountedWithoutCommand() throws {
        let config = VolumeConfig(name: "Team", protocolType: .smb, server: "nas.local", remotePath: "team", username: nil, mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)
        let runner = RecordingCommandRunner()
        let engine = AgentEngine(mountState: FakeMountStateProvider(isMounted: true), credentialStore: InMemoryCredentialStore(), commandRunner: runner, mountPlanner: MountPlanner())

        let status = try engine.check(config)

        XCTAssertEqual(status, .mounted)
        XCTAssertEqual(runner.plans, [])
    }

    func testUnmountedVolumeRunsMountCommand() throws {
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let config = VolumeConfig(id: id, name: "Team", protocolType: .smb, server: "nas.local", remotePath: "team", username: "mei", mountPoint: "/Volumes/Team", checkIntervalSeconds: 60, isEnabled: true)
        let credentials = InMemoryCredentialStore()
        try credentials.savePassword("secret", for: id)
        let runner = RecordingCommandRunner(result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        let engine = AgentEngine(mountState: FakeMountStateProvider(isMounted: false), credentialStore: credentials, commandRunner: runner, mountPlanner: MountPlanner())

        let status = try engine.check(config)

        XCTAssertEqual(status, .mounted)
        XCTAssertEqual(runner.plans.first?.executable, "/usr/bin/open")
    }
}

private struct FakeMountStateProvider: MountStateProvider {
    let isMounted: Bool
    func isMounted(config: VolumeConfig) -> Bool { isMounted }
}

private final class RecordingCommandRunner: CommandRunner {
    var plans: [CommandPlan] = []
    let result: CommandResult

    init(result: CommandResult = CommandResult(exitCode: 0, stdout: "", stderr: "")) {
        self.result = result
    }

    func run(_ plan: CommandPlan) throws -> CommandResult {
        plans.append(plan)
        return result
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd AutoVolume
swift test --filter AgentEngineTests
```

Expected: FAIL because `AgentEngine` and `MountStateProvider` do not exist.

- [ ] **Step 3: Implement mount state and agent engine**

Create `AutoVolume/Sources/AutoVolumeShared/MountState.swift`:

```swift
import Foundation

public protocol MountStateProvider {
    func isMounted(config: VolumeConfig) -> Bool
}

public final class FileSystemMountStateProvider: MountStateProvider {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func isMounted(config: VolumeConfig) -> Bool {
        let mountURL = URL(fileURLWithPath: config.mountPoint)
        guard fileManager.fileExists(atPath: mountURL.path) else { return false }
        guard let mountedURLs = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) else {
            return false
        }
        return mountedURLs.contains { $0.standardizedFileURL.path == mountURL.standardizedFileURL.path }
    }
}
```

Create `AutoVolume/Sources/AutoVolumeShared/AgentEngine.swift`:

```swift
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
        let result = try commandRunner.run(try mountPlanner.mountPlan(for: config, password: password))
        if result.exitCode == 0 {
            return .mounted
        }
        let message = result.stderr.isEmpty ? "Mount command failed with exit code \(result.exitCode)." : result.stderr
        return .failed(message: message)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
cd AutoVolume
swift test --filter AgentEngineTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AutoVolume/Sources/AutoVolumeShared/MountState.swift AutoVolume/Sources/AutoVolumeShared/AgentEngine.swift AutoVolume/Tests/AutoVolumeSharedTests/AgentEngineTests.swift
git commit -m "feat: add agent mount decisions"
```

## Task 6: Agent Entrypoint and LaunchAgent Template

**Files:**
- Modify: `AutoVolume/Sources/AutoVolumeAgent/main.swift`
- Create: `AutoVolume/Resources/com.autovolume.agent.plist`

- [ ] **Step 1: Build the agent before modification**

Run:

```bash
cd AutoVolume
swift build --product AutoVolumeAgent
```

Expected: PASS and product builds.

- [ ] **Step 2: Implement polling entrypoint**

Replace `AutoVolume/Sources/AutoVolumeAgent/main.swift` with:

```swift
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
```

Create `AutoVolume/Resources/com.autovolume.agent.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.autovolume.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/AutoVolume.app/Contents/Resources/AutoVolumeAgent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 3: Build the agent after modification**

Run:

```bash
cd AutoVolume
swift build --product AutoVolumeAgent
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add AutoVolume/Sources/AutoVolumeAgent/main.swift AutoVolume/Resources/com.autovolume.agent.plist
git commit -m "feat: add AutoVolume agent entrypoint"
```

## Task 7: App View Model

**Files:**
- Create: `AutoVolume/Sources/AutoVolumeApp/AppViewModel.swift`
- Create: `AutoVolume/Tests/AutoVolumeAppTests/AppViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AutoVolume/Tests/AutoVolumeAppTests/AppViewModelTests.swift`:

```swift
import XCTest
@testable import AutoVolumeApp
@testable import AutoVolumeShared

final class AppViewModelTests: XCTestCase {
    func testAddVolumePersistsConfigAndPassword() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configStore = JSONConfigStore(directory: directory)
        let credentialStore = InMemoryCredentialStore()
        let viewModel = AppViewModel(configStore: configStore, credentialStore: credentialStore)
        let config = VolumeConfig(name: "Media", protocolType: .webdav, server: "dav.example.com", remotePath: "media", username: "mei", mountPoint: "/Volumes/Media", checkIntervalSeconds: 300, isEnabled: true)

        try viewModel.add(config, password: "secret")

        XCTAssertEqual(try configStore.load(), [config])
        XCTAssertEqual(try credentialStore.password(for: config.id), "secret")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd AutoVolume
swift test --filter AppViewModelTests
```

Expected: FAIL because `AppViewModel` does not exist or is not public enough for tests.

- [ ] **Step 3: Implement the view model**

Create `AutoVolume/Sources/AutoVolumeApp/AppViewModel.swift`:

```swift
import Foundation
import Observation
import AutoVolumeShared

@Observable
public final class AppViewModel {
    public private(set) var volumes: [VolumeConfig] = []
    public var selectedVolumeID: VolumeConfig.ID?

    private let configStore: ConfigStore
    private let credentialStore: CredentialStore

    public init(configStore: ConfigStore = JSONConfigStore(), credentialStore: CredentialStore = KeychainCredentialStore()) {
        self.configStore = configStore
        self.credentialStore = credentialStore
        self.volumes = (try? configStore.load()) ?? []
    }

    public func add(_ config: VolumeConfig, password: String?) throws {
        volumes.append(config)
        try persist()
        if let password, !password.isEmpty {
            try credentialStore.savePassword(password, for: config.id)
        }
    }

    public func delete(_ config: VolumeConfig) throws {
        volumes.removeAll { $0.id == config.id }
        try persist()
        try credentialStore.deletePassword(for: config.id)
    }

    private func persist() throws {
        try configStore.save(volumes)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cd AutoVolume
swift test --filter AppViewModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AutoVolume/Sources/AutoVolumeApp/AppViewModel.swift AutoVolume/Tests/AutoVolumeAppTests/AppViewModelTests.swift
git commit -m "feat: add app configuration view model"
```

## Task 8: Menu Bar UI

**Files:**
- Modify: `AutoVolume/Sources/AutoVolumeApp/AutoVolumeApp.swift`
- Create: `AutoVolume/Sources/AutoVolumeApp/ContentView.swift`
- Create: `AutoVolume/Sources/AutoVolumeApp/VolumeEditorView.swift`

- [ ] **Step 1: Build current app**

Run:

```bash
cd AutoVolume
swift build --product AutoVolumeApp
```

Expected: PASS.

- [ ] **Step 2: Implement UI files**

Replace `AutoVolume/Sources/AutoVolumeApp/AutoVolumeApp.swift` with:

```swift
import SwiftUI
import AutoVolumeShared

@main
struct AutoVolumeApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra("AutoVolume", systemImage: "externaldrive.connected.to.line.below") {
            ContentView(viewModel: viewModel)
                .frame(width: 520, height: 420)
        }
        .menuBarExtraStyle(.window)
    }
}
```

Create `AutoVolume/Sources/AutoVolumeApp/ContentView.swift`:

```swift
import SwiftUI
import AutoVolumeShared

struct ContentView: View {
    @Bindable var viewModel: AppViewModel
    @State private var isPresentingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("AutoVolume 智卷", systemImage: "externaldrive.connected.to.line.below")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                Spacer()
                Button {
                    isPresentingEditor = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .keyboardShortcut("n")
            }

            if viewModel.volumes.isEmpty {
                ContentUnavailableView("No Volumes", systemImage: "externaldrive.badge.plus", description: Text("Add a network volume to keep it connected."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.volumes) { volume in
                    HStack {
                        Image(systemName: "externaldrive")
                        VStack(alignment: .leading) {
                            Text(volume.name).font(.headline)
                            Text("\(volume.protocolType.rawValue.uppercased()) · \(volume.server)/\(volume.remotePath)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(volume.checkIntervalSeconds / 60))m")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(22)
        .background(.regularMaterial)
        .sheet(isPresented: $isPresentingEditor) {
            VolumeEditorView(viewModel: viewModel)
        }
    }
}
```

Create `AutoVolume/Sources/AutoVolumeApp/VolumeEditorView.swift`:

```swift
import SwiftUI
import AutoVolumeShared

struct VolumeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: AppViewModel

    @State private var name = ""
    @State private var protocolType = VolumeProtocol.smb
    @State private var server = ""
    @State private var remotePath = ""
    @State private var username = ""
    @State private var password = ""
    @State private var mountPoint = "/Volumes/"
    @State private var intervalMinutes = 5.0

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Protocol", selection: $protocolType) {
                ForEach(VolumeProtocol.allCases) { item in
                    Text(item.rawValue.uppercased()).tag(item)
                }
            }
            TextField("Server", text: $server)
            TextField("Remote Path", text: $remotePath)
            TextField("Username", text: $username)
            SecureField("Password", text: $password)
            TextField("Mount Point", text: $mountPoint)
            Slider(value: $intervalMinutes, in: 1...60, step: 1) {
                Text("Check Interval")
            }
            Text("Every \(Int(intervalMinutes)) minutes")

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    let config = VolumeConfig(
                        name: name,
                        protocolType: protocolType,
                        server: server,
                        remotePath: remotePath,
                        username: username.isEmpty ? nil : username,
                        mountPoint: mountPoint,
                        checkIntervalSeconds: intervalMinutes * 60,
                        isEnabled: true
                    )
                    try? viewModel.add(config, password: password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
```

- [ ] **Step 3: Build app**

Run:

```bash
cd AutoVolume
swift build --product AutoVolumeApp
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add AutoVolume/Sources/AutoVolumeApp
git commit -m "feat: add AutoVolume menu bar UI"
```

## Task 9: Full Verification

**Files:**
- Modify only if verification exposes compile or test failures.

- [ ] **Step 1: Run full test suite**

Run:

```bash
cd AutoVolume
swift test
```

Expected: PASS.

- [ ] **Step 2: Build both products**

Run:

```bash
cd AutoVolume
swift build --product AutoVolumeApp
swift build --product AutoVolumeAgent
```

Expected: both commands PASS.

- [ ] **Step 3: Confirm workspace status**

Run:

```bash
git status --short
```

Expected: only intentional files are modified or untracked.

- [ ] **Step 4: Commit verification fixes if any**

If Step 1 or Step 2 required fixes, commit them:

```bash
git add AutoVolume
git commit -m "fix: stabilize AutoVolume MVP build"
```

Expected: commit succeeds only when fixes were made.

## Self-Review

- Spec coverage: The plan covers the shared model, JSON storage, Keychain-backed credentials, protocol mount planning, mount state checks, agent reconnect decisions, LaunchAgent template, menu bar UI, and tests. The MVP non-goals remain out of scope.
- Completion scan: The plan contains no unfinished markers. Each code step includes concrete file content or exact commands.
- Type consistency: `VolumeConfig`, `VolumeProtocol`, `VolumeStatus`, `CredentialStore`, `CommandRunner`, `MountPlanner`, `MountStateProvider`, `AgentEngine`, and `AppViewModel` names are consistent across tasks.
