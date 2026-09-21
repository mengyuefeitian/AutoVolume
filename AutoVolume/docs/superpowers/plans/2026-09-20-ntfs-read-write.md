# NTFS 实时读写支持 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AutoVolume 能够检测任意插入的 NTFS 外接硬盘，并在不禁用 SIP、不要求用户手动批准系统扩展的前提下，用内置的 FUSE-T + ntfs-3g 自动将其从只读切换为读写挂载。

**Architecture:** 新增 `NTFSAutoMountService`（运行在现有 `AutoVolumeAgent` launchd 常驻进程中）通过 DiskArbitration 事件回调（而非轮询）监听磁盘插入/拔出；纯逻辑（文件系统过滤、去抖、命令构造、驱动安装幂等性判断）拆分为独立可单元测试的类型，只有 DiskArbitration 的回调注册留在编排层。App 侧新增一个设置开关（默认关闭）和一次性提醒，复用现有 `AlertStore` 机制展示。**2026-09-21 实施调研修订**：`ntfs-3g` 打开原始块设备始终需要 root 权限（macOS 系统级限制，与 FUSE 后端无关，实测验证），且 ntfs-3g 自身拒绝在链接外部 FUSE 库时以 setuid 方式运行。因此新增一个新的可执行目标 `NTFSPrivilegedHelper`（root 常驻 LaunchDaemon），只负责"挂载/卸载指定块设备到指定路径"；无权限的 `AutoVolumeAgent` 通过本地 Unix domain socket 向它发送请求，不再直接调用 `ntfs-3g`。详见 `docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md` 与 spec 的「权限模型」章节。

**Tech Stack:** Swift 5.10 / macOS 14+，DiskArbitration.framework，FUSE-T（二进制分发许可：非商业用途免费，已与用户确认 AutoVolume 属于非商业用途）+ ntfs-3g（GPLv2，作为独立子进程调用，不静态链接，构建自 `macos-fuse-t/ntfs-3g` 分支），项目现有的 `CommandRunner`/`CommandPlan` 抽象，BSD Unix domain socket（`Darwin` 模块，本地 IPC）。

**Spec:** `docs/superpowers/specs/2026-09-20-ntfs-read-write-design.md`

**Build environment note：** 本机 `swiftc`（swiftly 管理的 Swift 6.3.3）搭配默认 `MacOSX27.0.sdk` 编译任何多文件 Foundation 导入目标都会失败（`-target-arch-variant` 未知参数错误，ClangImporter 构建 Foundation Clang 模块时触发，已确认与 SDK 27.0 强相关、与 Swift 工具链版本无关）。**所有 `script/build_and_run.sh` 调用都必须加上环境变量前缀**（已记录进 `CLAUDE.md`）：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch
```

## Global Constraints

- 不得禁用 SIP，不得要求用户在系统设置中手动批准 System Extension（这是选择 FUSE-T 而非 macFUSE 的硬性前提，见 spec）。
- `ntfs-3g`（GPLv2）必须以独立子进程方式调用（通过 `CommandPlan`/`Process`），禁止静态链接进 `AutoVolumeShared`，随包附带其 License 文本。
- FUSE-T 二进制分发许可证为非商业用途，AutoVolume 目前及可预见的将来均为个人/内部使用，不做二次分发销售——若未来分发性质改变需重新评估此项。
- 新增设置项 `autoMountNTFSReadWrite` 默认必须为 `false`（opt-in），且旧版本 `settings.json`（不含该字段）必须能正常解码，不能因缺字段而崩溃或报错。
- **权限边界**：`AutoVolumeAgent`（无权限用户级进程）任何时候都不得直接调用 `ntfs-3g` 挂载原始块设备（已实测证实需要 root，且 ntfs-3g 拒绝 setuid 方式运行外部 FUSE 库）。所有实际挂载/卸载操作必须通过 `NTFSPrivilegedHelper`（root LaunchDaemon）的本地 socket 请求完成。`NTFSPrivilegedHelper` 只接受 `mountPoint` 以 `/Volumes/` 开头的请求，拒绝来自 uid 0（root）的连接请求（安全边界最小化，详见 Task 7）。这部分代码涉及本机特权守护进程，实现后必须过一遍 `security-reviewer` 检查（项目全局 CLAUDE.md 对"安全敏感代码"的要求）。
- 本项目的权威测试套件是 `ManualTests/AutoVolumeManualTests.swift`（通过 `script/build_and_run.sh` 运行，见项目 `CLAUDE.md`），新逻辑必须在此文件中补充对应的 `test...()` 函数并注册进文件末尾的 `tests` 数组；纯逻辑代码禁止依赖 `Bundle.main` 或真实 DiskArbitration/socket 会话，以便可在该套件中无物理硬盘、无特权守护进程的情况下运行。
- 项目构建脚本 `script/build_and_run.sh` 用显式文件列表调用 `swiftc`（不是 `swift build`），新增的 `Sources/AutoVolumeShared/*.swift` 文件必须手动加入该脚本里的编译文件列表，否则不会被打进 App。**每个任务自己负责把自己新增的文件加入构建脚本**（不要等到最后一个任务才补——见下方 Task 5 起对此的修正说明），确保每个任务都能独立通过 `script/build_and_run.sh --no-launch` 验证。
- 每完成一次代码改动（包括中间迭代），必须按 `CLAUDE.md` 流程：升版本号 → `SDKROOT=... script/build_and_run.sh --no-launch` → `script/package_dmg.sh <version>` → 交给用户自测，不自行判定完成。**注意**：版本号递增 + DMG 打包只需要在最后一个任务（Task 13）做一次，中间任务只需要跑通 `script/build_and_run.sh --no-launch` 验证编译和 manual tests 通过即可，不必每个任务都打 DMG（DMG 面向用户手动验收，中间任务产出还不是可验收的完整功能）。

---

### Task 1: 调研并落地 FUSE-T + ntfs-3g 的本地安装与挂载方式 — ✅ 已完成

**状态：已完成**（由 controller 直接执行，非子 agent；产出物已提交）。调研发现原计划假设的权限模型不成立（见上方 Architecture 的 2026-09-21 修订说明），已更新 spec 与本计划的后续任务。

产出物：
- `docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md`：完整调研结论，包括已验证的挂载命令、FUSE-T 安装标记路径、权限模型问题、许可证审查。
- `Resources/NTFSDriver/ntfs-3g`、`Resources/NTFSDriver/libntfs-3g.89.dylib`：已构建自 `macos-fuse-t/ntfs-3g` 分支（链接 FUSE-T），已用 `install_name_tool` 调整为相对自身目录的可重定位二进制，已实测验证可读写挂载测试 NTFS 卷。
- `Resources/NTFSDriver/fuse-t-installer.pkg`：FUSE-T 1.2.7 官方安装包。
- `Resources/NTFSDriver/LICENSE-ntfs-3g.txt`、`Resources/NTFSDriver/LICENSE-fuse-t.txt`：许可证文本。

后续任务（Task 5 起）直接引用这些已验证的产物和结论，不再是猜测性设计。

---

### Task 2: 扩展 `AppSettings` 增加 `autoMountNTFSReadWrite`（向后兼容）

推荐模型：sonnet 5。

**Files:**
- Modify: `Sources/AutoVolumeShared/AppSettings.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Produces：`AppSettings.autoMountNTFSReadWrite: Bool`（默认 `false`），供 Task 12（Settings UI）与 Task 11（Agent 编排）读取。

- [ ] **Step 1: 写失败的测试——旧版 settings.json（无新字段）仍能解码，且新字段默认 false**

在 `ManualTests/AutoVolumeManualTests.swift` 中，在 `testAppSettingsStoreDefaultsAndRoundTrip` 函数后新增：

```swift
func testAppSettingsDecodesLegacyJSONWithoutNTFSField() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacyJSON = """
    {"logLevel":0,"openFinderAfterMount":true}
    """
    try legacyJSON.write(to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let store = JSONAppSettingsStore(directory: directory)

    let settings = try store.load()

    try expect(settings.autoMountNTFSReadWrite == false, "Legacy settings.json without the field should default autoMountNTFSReadWrite to false")
}

func testAppSettingsRoundTripsNTFSSetting() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONAppSettingsStore(directory: directory)

    try store.save(AppSettings(autoMountNTFSReadWrite: true))
    let loaded = try store.load()

    try expect(loaded.autoMountNTFSReadWrite == true, "autoMountNTFSReadWrite did not round trip through JSON")
}
```

在文件末尾的 `tests` 数组中，紧跟 `("AppSettingsStore", testAppSettingsStoreDefaultsAndRoundTrip),` 之后添加：

```swift
    ("AppSettings legacy JSON decode", testAppSettingsDecodesLegacyJSONWithoutNTFSField),
    ("AppSettings NTFS setting round trip", testAppSettingsRoundTripsNTFSSetting),
```

- [ ] **Step 2: 运行测试确认失败**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译失败（`AppSettings` 没有 `autoMountNTFSReadWrite` 参数/属性），或测试断言失败。

- [ ] **Step 3: 修改 `AppSettings` 增加字段并自定义 Codable 以兼容旧数据**

`Sources/AutoVolumeShared/AppSettings.swift` 中的 `AppSettings` struct 目前依赖合成的 `Codable`。替换为：

```swift
public struct AppSettings: Codable, Equatable {
    public var logLevel: LogLevel
    public var openFinderAfterMount: Bool
    public var autoMountNTFSReadWrite: Bool

    enum CodingKeys: String, CodingKey {
        case logLevel
        case openFinderAfterMount
        case autoMountNTFSReadWrite
    }

    public init(logLevel: LogLevel = .info, openFinderAfterMount: Bool = true, autoMountNTFSReadWrite: Bool = false) {
        self.logLevel = logLevel
        self.openFinderAfterMount = openFinderAfterMount
        self.autoMountNTFSReadWrite = autoMountNTFSReadWrite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.logLevel = try container.decode(LogLevel.self, forKey: .logLevel)
        self.openFinderAfterMount = try container.decode(Bool.self, forKey: .openFinderAfterMount)
        self.autoMountNTFSReadWrite = try container.decodeIfPresent(Bool.self, forKey: .autoMountNTFSReadWrite) ?? false
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: `PASS: AppSettings legacy JSON decode`、`PASS: AppSettings NTFS setting round trip`，且所有既有测试仍然 `PASS`。

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/AppSettings.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add autoMountNTFSReadWrite setting with legacy JSON compatibility"
```

---

### Task 3: `NTFSVolume` 模型与文件系统类型过滤

推荐模型：sonnet 5。

**Files:**
- Create: `Sources/AutoVolumeShared/NTFSVolume.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Produces：
  - `public struct NTFSVolume: Codable, Identifiable, Equatable { public var id: String { bsdName }; public var bsdName: String; public var volumeName: String; public var devicePath: String; public var mountPoint: String; public var mountedAt: Date }`
  - `public enum NTFSDiskClassifier { public static func isNTFSFileSystem(personality: String?) -> Bool; public static func isOwnedByOurDriver(mountedFileSystemName: String?) -> Bool }`
- Consumes：无（纯新增类型）

- [ ] **Step 1: 写失败测试**

在 `ManualTests/AutoVolumeManualTests.swift` 添加：

```swift
func testNTFSDiskClassifierIdentifiesNTFSPersonality() throws {
    try expect(NTFSDiskClassifier.isNTFSFileSystem(personality: "Windows_NTFS") == true, "Windows_NTFS should classify as NTFS")
    try expect(NTFSDiskClassifier.isNTFSFileSystem(personality: "ntfs") == true, "lowercase ntfs should classify as NTFS")
    try expect(NTFSDiskClassifier.isNTFSFileSystem(personality: "Windows_FAT_32") == false, "FAT32 should not classify as NTFS")
    try expect(NTFSDiskClassifier.isNTFSFileSystem(personality: nil) == false, "nil personality should not classify as NTFS")
}

func testNTFSDiskClassifierIgnoresAlreadyMountedByOurDriver() throws {
    try expect(NTFSDiskClassifier.isOwnedByOurDriver(mountedFileSystemName: "fusefs_ntfs") == true, "fusefs_ntfs mounts should be recognized as already ours")
    try expect(NTFSDiskClassifier.isOwnedByOurDriver(mountedFileSystemName: "ntfs") == false, "native read-only ntfs mounts are not yet ours")
    try expect(NTFSDiskClassifier.isOwnedByOurDriver(mountedFileSystemName: nil) == false, "nil mounted filesystem is not ours")
}

func testNTFSVolumeRoundTripsThroughJSON() throws {
    let volume = NTFSVolume(bsdName: "disk4s1", volumeName: "MY USB", devicePath: "/dev/disk4s1", mountPoint: "/Volumes/MY USB", mountedAt: Date(timeIntervalSince1970: 1_700_000_000))

    let data = try JSONEncoder().encode(volume)
    let decoded = try JSONDecoder().decode(NTFSVolume.self, from: data)

    try expect(decoded == volume, "NTFSVolume JSON round trip failed")
}
```

在 `tests` 数组末尾添加：

```swift
    ("NTFSDiskClassifier NTFS personality", testNTFSDiskClassifierIdentifiesNTFSPersonality),
    ("NTFSDiskClassifier already-mounted filter", testNTFSDiskClassifierIgnoresAlreadyMountedByOurDriver),
    ("NTFSVolume JSON round trip", testNTFSVolumeRoundTripsThroughJSON),
```

- [ ] **Step 2: 运行测试确认失败**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译失败（`NTFSVolume`/`NTFSDiskClassifier` 不存在）

- [ ] **Step 3: 实现**

创建 `Sources/AutoVolumeShared/NTFSVolume.swift`：

```swift
import Foundation

public struct NTFSVolume: Codable, Identifiable, Equatable {
    public var id: String { bsdName }
    public var bsdName: String
    public var volumeName: String
    public var devicePath: String
    public var mountPoint: String
    public var mountedAt: Date

    public init(bsdName: String, volumeName: String, devicePath: String, mountPoint: String, mountedAt: Date) {
        self.bsdName = bsdName
        self.volumeName = volumeName
        self.devicePath = devicePath
        self.mountPoint = mountPoint
        self.mountedAt = mountedAt
    }
}

public enum NTFSDiskClassifier {
    public static func isNTFSFileSystem(personality: String?) -> Bool {
        guard let personality else { return false }
        return personality.lowercased().contains("ntfs")
    }

    public static func isOwnedByOurDriver(mountedFileSystemName: String?) -> Bool {
        guard let mountedFileSystemName else { return false }
        return mountedFileSystemName.lowercased().contains("fusefs_ntfs")
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSVolume.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add NTFSVolume model and NTFS filesystem classifier"
```

---

### Task 4: `NTFSMountedVolumesStore`（持久化当前只读切读写的 NTFS 卷列表）

推荐模型：sonnet 5。

**Files:**
- Create: `Sources/AutoVolumeShared/NTFSMountedVolumesStore.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Consumes：`NTFSVolume`（Task 3）
- Produces：
  ```swift
  public final class NTFSMountedVolumesStore {
      public init(directory: URL? = nil)
      public func load() throws -> [NTFSVolume]
      public func add(_ volume: NTFSVolume) throws
      public func remove(bsdName: String) throws
  }
  ```
  供 Task 11（Agent 编排）写入、Task 12（App UI）读取。

- [ ] **Step 1: 写失败测试**

```swift
func testNTFSMountedVolumesStoreAddLoadRemove() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NTFSMountedVolumesStore(directory: directory)

    let missing = try store.load()
    try expect(missing == [], "Missing store should load as empty array")

    let volume = NTFSVolume(bsdName: "disk4s1", volumeName: "USB", devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB", mountedAt: Date(timeIntervalSince1970: 1_700_000_000))
    try store.add(volume)
    let loaded = try store.load()
    try expect(loaded == [volume], "Added volume did not load back")

    try store.remove(bsdName: "disk4s1")
    let afterRemove = try store.load()
    try expect(afterRemove == [], "Removed volume should no longer be present")
}

func testNTFSMountedVolumesStoreAddReplacesSameBSDName() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NTFSMountedVolumesStore(directory: directory)

    let first = NTFSVolume(bsdName: "disk4s1", volumeName: "USB", devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB", mountedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let second = NTFSVolume(bsdName: "disk4s1", volumeName: "USB Renamed", devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB Renamed", mountedAt: Date(timeIntervalSince1970: 1_700_000_100))
    try store.add(first)
    try store.add(second)

    let loaded = try store.load()
    try expect(loaded == [second], "Re-adding the same bsdName should replace, not duplicate")
}
```

添加到 `tests` 数组：

```swift
    ("NTFSMountedVolumesStore add/load/remove", testNTFSMountedVolumesStoreAddLoadRemove),
    ("NTFSMountedVolumesStore replaces same bsdName", testNTFSMountedVolumesStoreAddReplacesSameBSDName),
```

- [ ] **Step 2: 运行确认失败**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译失败（类型不存在）

- [ ] **Step 3: 实现（直接参照 `AlertStore.swift` 的结构）**

```swift
import Foundation

public final class NTFSMountedVolumesStore {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let baseDirectory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AutoVolume", isDirectory: true)
        self.fileURL = baseDirectory.appendingPathComponent("ntfs-volumes.json")
    }

    public func load() throws -> [NTFSVolume] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([NTFSVolume].self, from: data)
    }

    public func add(_ volume: NTFSVolume) throws {
        var volumes = try load()
        volumes.removeAll { $0.bsdName == volume.bsdName }
        volumes.append(volume)
        try save(volumes)
    }

    public func remove(bsdName: String) throws {
        var volumes = try load()
        volumes.removeAll { $0.bsdName == bsdName }
        try save(volumes)
    }

    private func save(_ volumes: [NTFSVolume]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(volumes).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSMountedVolumesStore.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add NTFSMountedVolumesStore for tracking active NTFS read-write mounts"
```

---

### Task 5: `NTFSHelperProtocol`（Agent ↔ 特权 Helper 的共享请求/响应类型 + 路径常量 + 校验逻辑）

推荐模型：sonnet 5。

**说明：** 这是权限模型修正后新增的基础类型任务，供 Task 6（helper 内部挂载命令构造，沿用原设计不变）、Task 7（helper 本体）、Task 8（安装器）、Task 9（Agent 侧 socket 客户端）共同使用。所有路径都是固定常量（不依赖 `Bundle.main`），因此在 helper（root LaunchDaemon，运行时脱离 App bundle）和 Agent（在 App bundle 内）两侧都能一致工作。

**Files:**
- Create: `Sources/AutoVolumeShared/NTFSHelperProtocol.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Produces：
  ```swift
  public enum NTFSDriverPaths {
      public static let installDirectory: String   // "/Library/PrivilegedHelperTools/com.autovolume.ntfsdriver"
      public static var ntfs3gExecutablePath: String { get }
      public static var ntfs3gDylibPath: String { get }
  }
  public enum NTFSHelperSocket {
      public static let path: String   // "/var/run/com.autovolume.ntfshelper.sock"
      public static let daemonLabel: String   // "com.autovolume.ntfshelper"
      public static let daemonPlistInstallPath: String   // "/Library/LaunchDaemons/com.autovolume.ntfshelper.plist"
      public static let helperInstallPath: String   // "/Library/PrivilegedHelperTools/com.autovolume.ntfshelper"
  }
  public enum NTFSHelperAction: String, Codable, Equatable { case mount, unmount }
  public struct NTFSHelperRequest: Codable, Equatable {
      public var action: NTFSHelperAction
      public var devicePath: String?
      public var mountPoint: String
      public init(action: NTFSHelperAction, devicePath: String? = nil, mountPoint: String)
  }
  public struct NTFSHelperResponse: Codable, Equatable {
      public var success: Bool
      public var message: String
      public init(success: Bool, message: String = "")
  }
  public enum NTFSHelperWireFormat {
      public static func encode(_ request: NTFSHelperRequest) throws -> Data
      public static func encode(_ response: NTFSHelperResponse) throws -> Data
      public static func decodeRequest(_ data: Data) throws -> NTFSHelperRequest
      public static func decodeResponse(_ data: Data) throws -> NTFSHelperResponse
  }
  public enum NTFSHelperRequestValidator {
      public static func validate(_ request: NTFSHelperRequest) -> String?   // nil = valid, else 错误信息
  }
  ```
  供 Task 6-9 使用。`NTFSHelperWireFormat` 用换行符分隔的 JSON（每条消息一行），`NTFSHelperRequestValidator` 校验 `mountPoint` 必须以 `/Volumes/` 开头（防止请求方指定任意系统路径）、`action == .mount` 时 `devicePath` 不能为空。

- [ ] **Step 1: 写失败测试**

```swift
func testNTFSHelperRequestRoundTripsThroughJSON() throws {
    let request = NTFSHelperRequest(action: .mount, devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB")

    let encoded = try NTFSHelperWireFormat.encode(request)
    let decoded = try NTFSHelperWireFormat.decodeRequest(encoded)

    try expect(decoded == request, "NTFSHelperRequest did not round trip through the wire format")
    try expect(encoded.last == 0x0A, "Encoded request must end with a newline delimiter")
}

func testNTFSHelperResponseRoundTripsThroughJSON() throws {
    let response = NTFSHelperResponse(success: false, message: "mount failed")

    let encoded = try NTFSHelperWireFormat.encode(response)
    let decoded = try NTFSHelperWireFormat.decodeResponse(encoded)

    try expect(decoded == response, "NTFSHelperResponse did not round trip through the wire format")
    try expect(encoded.last == 0x0A, "Encoded response must end with a newline delimiter")
}

func testNTFSHelperRequestValidatorRejectsMountPointOutsideVolumes() throws {
    let request = NTFSHelperRequest(action: .unmount, mountPoint: "/etc/passwd")

    let error = NTFSHelperRequestValidator.validate(request)

    try expect(error != nil, "A mountPoint outside /Volumes must be rejected")
}

func testNTFSHelperRequestValidatorAcceptsMountPointUnderVolumes() throws {
    let request = NTFSHelperRequest(action: .unmount, mountPoint: "/Volumes/USB")

    let error = NTFSHelperRequestValidator.validate(request)

    try expect(error == nil, "A mountPoint under /Volumes should be accepted, got: \(error ?? "")")
}

func testNTFSHelperRequestValidatorRejectsMountActionWithoutDevicePath() throws {
    let request = NTFSHelperRequest(action: .mount, devicePath: nil, mountPoint: "/Volumes/USB")

    let error = NTFSHelperRequestValidator.validate(request)

    try expect(error != nil, "A mount action without devicePath must be rejected")
}

func testNTFSDriverPathsAreUnderPrivilegedHelperTools() throws {
    try expect(NTFSDriverPaths.installDirectory == "/Library/PrivilegedHelperTools/com.autovolume.ntfsdriver", "installDirectory changed unexpectedly")
    try expect(NTFSDriverPaths.ntfs3gExecutablePath == "/Library/PrivilegedHelperTools/com.autovolume.ntfsdriver/ntfs-3g", "ntfs3gExecutablePath changed unexpectedly")
}
```

添加到 `tests` 数组：

```swift
    ("NTFSHelperRequest wire round trip", testNTFSHelperRequestRoundTripsThroughJSON),
    ("NTFSHelperResponse wire round trip", testNTFSHelperResponseRoundTripsThroughJSON),
    ("NTFSHelperRequestValidator rejects outside /Volumes", testNTFSHelperRequestValidatorRejectsMountPointOutsideVolumes),
    ("NTFSHelperRequestValidator accepts /Volumes path", testNTFSHelperRequestValidatorAcceptsMountPointUnderVolumes),
    ("NTFSHelperRequestValidator rejects mount without devicePath", testNTFSHelperRequestValidatorRejectsMountActionWithoutDevicePath),
    ("NTFSDriverPaths constants", testNTFSDriverPathsAreUnderPrivilegedHelperTools),
```

- [ ] **Step 2: 运行确认失败**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译失败（类型不存在）

- [ ] **Step 3: 实现**

```swift
import Foundation

public enum NTFSDriverPaths {
    public static let installDirectory = "/Library/PrivilegedHelperTools/com.autovolume.ntfsdriver"
    public static var ntfs3gExecutablePath: String { installDirectory + "/ntfs-3g" }
    public static var ntfs3gDylibPath: String { installDirectory + "/libntfs-3g.89.dylib" }
}

public enum NTFSHelperSocket {
    public static let path = "/var/run/com.autovolume.ntfshelper.sock"
    public static let daemonLabel = "com.autovolume.ntfshelper"
    public static let daemonPlistInstallPath = "/Library/LaunchDaemons/com.autovolume.ntfshelper.plist"
    public static let helperInstallPath = "/Library/PrivilegedHelperTools/com.autovolume.ntfshelper"
}

public enum NTFSHelperAction: String, Codable, Equatable {
    case mount
    case unmount
}

public struct NTFSHelperRequest: Codable, Equatable {
    public var action: NTFSHelperAction
    public var devicePath: String?
    public var mountPoint: String

    public init(action: NTFSHelperAction, devicePath: String? = nil, mountPoint: String) {
        self.action = action
        self.devicePath = devicePath
        self.mountPoint = mountPoint
    }
}

public struct NTFSHelperResponse: Codable, Equatable {
    public var success: Bool
    public var message: String

    public init(success: Bool, message: String = "") {
        self.success = success
        self.message = message
    }
}

public enum NTFSHelperWireFormat {
    public static func encode(_ request: NTFSHelperRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return data
    }

    public static func encode(_ response: NTFSHelperResponse) throws -> Data {
        var data = try JSONEncoder().encode(response)
        data.append(0x0A)
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> NTFSHelperRequest {
        try JSONDecoder().decode(NTFSHelperRequest.self, from: trimmedTrailingNewline(data))
    }

    public static func decodeResponse(_ data: Data) throws -> NTFSHelperResponse {
        try JSONDecoder().decode(NTFSHelperResponse.self, from: trimmedTrailingNewline(data))
    }

    private static func trimmedTrailingNewline(_ data: Data) -> Data {
        guard data.last == 0x0A else { return data }
        return data.dropLast()
    }
}

public enum NTFSHelperRequestValidator {
    public static func validate(_ request: NTFSHelperRequest) -> String? {
        guard request.mountPoint.hasPrefix("/Volumes/") else {
            return "mountPoint must be under /Volumes"
        }
        if request.action == .mount, request.devicePath == nil {
            return "devicePath is required for mount"
        }
        return nil
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSHelperProtocol.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add NTFSHelperProtocol shared types for Agent-to-helper IPC"
```

---

### Task 6: `NTFSMountPlanner`（Helper 内部使用——卸载只读挂载 + ntfs-3g 读写挂载的 CommandPlan）

推荐模型：sonnet 5。

**说明：** 内容与原设计不变，唯一区别是消费方：现在是 `NTFSPrivilegedHelper`（Task 7，root 进程）调用它构造实际命令，而不是 `AutoVolumeAgent`。`ntfs3gPath` 的值现在应该是 `NTFSDriverPaths.ntfs3gExecutablePath`（Task 5），由 Task 7 传入。

**Files:**
- Create: `Sources/AutoVolumeShared/NTFSMountPlanner.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Consumes：`CommandPlan`
- Produces：
  ```swift
  public struct NTFSMountPlanner {
      public init(ntfs3gPath: String)
      public func unmountReadOnlyPlan(mountPoint: String) -> CommandPlan
      public func mountReadWritePlan(devicePath: String, mountPoint: String) -> CommandPlan
  }
  ```
  供 Task 7（`NTFSPrivilegedHelper`）使用。挂载命令直接取自 Task 1 调研文档记录的 `ntfs-3g <devicePath> <mountPoint> -olocal -oallow_other -oauto_xattr`；卸载复用现有 `diskutil unmount`（与 `MountPlanner.unmountPlan` 相同命令，不新增卸载逻辑）。

- [ ] **Step 1: 写失败测试**

```swift
func testNTFSMountPlannerUnmountUsesDiskutil() throws {
    let planner = NTFSMountPlanner(ntfs3gPath: NTFSDriverPaths.ntfs3gExecutablePath)

    let plan = planner.unmountReadOnlyPlan(mountPoint: "/Volumes/USB")

    try expect(plan.executable == "/usr/sbin/diskutil", "Unmount plan should use diskutil")
    try expect(plan.arguments == ["unmount", "/Volumes/USB"], "Unmount plan arguments did not match")
}

func testNTFSMountPlannerMountUsesBundledNtfs3g() throws {
    let planner = NTFSMountPlanner(ntfs3gPath: NTFSDriverPaths.ntfs3gExecutablePath)

    let plan = planner.mountReadWritePlan(devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB")

    try expect(plan.executable == NTFSDriverPaths.ntfs3gExecutablePath, "Mount plan should invoke the installed ntfs-3g binary")
    try expect(plan.arguments == ["/dev/disk4s1", "/Volumes/USB", "-olocal", "-oallow_other", "-oauto_xattr"], "Mount plan arguments did not match the researched invocation")
}
```

添加到 `tests` 数组：

```swift
    ("NTFSMountPlanner unmount uses diskutil", testNTFSMountPlannerUnmountUsesDiskutil),
    ("NTFSMountPlanner mount uses bundled ntfs-3g", testNTFSMountPlannerMountUsesBundledNtfs3g),
```

- [ ] **Step 2: 运行确认失败**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译失败（类型不存在）

- [ ] **Step 3: 实现**

```swift
import Foundation

public struct NTFSMountPlanner {
    private let ntfs3gPath: String

    public init(ntfs3gPath: String) {
        self.ntfs3gPath = ntfs3gPath
    }

    public func unmountReadOnlyPlan(mountPoint: String) -> CommandPlan {
        CommandPlan(executable: "/usr/sbin/diskutil", arguments: ["unmount", mountPoint])
    }

    public func mountReadWritePlan(devicePath: String, mountPoint: String) -> CommandPlan {
        CommandPlan(
            executable: ntfs3gPath,
            arguments: [devicePath, mountPoint, "-olocal", "-oallow_other", "-oauto_xattr"]
        )
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSMountPlanner.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add NTFSMountPlanner for ntfs-3g read-write remount commands"
```

---

### Task 7: `NTFSPrivilegedHelper`（root LaunchDaemon 本体）— **安全敏感，实现后需要 security-reviewer 复核**

推荐模型：sonnet 5 实现；**完成后必须派发一次 `security-reviewer` agent 复核这个任务的 diff**（本项目全局 CLAUDE.md 规则：安全敏感代码必须过 security-reviewer），重点检查：peer credential 校验是否可被绕过、socket 文件权限、`NTFSHelperRequestValidator` 是否在处理请求前被无条件调用、是否有除挂载/卸载之外的任何命令注入面。这一条复核在本任务的 task review 之外**额外**执行，是本任务"完成"的必要条件之一。

**Files:**
- Create: `Sources/AutoVolumeNTFSHelper/main.swift`（新可执行目标，产出 `NTFSPrivilegedHelper`）
- Create: `Resources/com.autovolume.ntfshelper.plist`（LaunchDaemon plist）

**说明：** 本任务是本地 socket 服务器的运行时"glue"代码（类似现有 `Sources/AutoVolumeAgent/main.swift` 的定位），不含可脱离真实 socket/进程环境单元测试的逻辑——所有可测试的判断逻辑（请求校验、挂载命令构造）已经在 Task 5/6 里实现并测试过，本任务只是把它们接起来监听 socket。因此本任务没有 Step 1/2（写测试/确认失败），直接实现 + 手动构建验证。

**Interfaces:**
- Consumes：`NTFSHelperSocket`、`NTFSHelperRequest`、`NTFSHelperResponse`、`NTFSHelperWireFormat`、`NTFSHelperRequestValidator`（Task 5）、`NTFSMountPlanner`、`NTFSDriverPaths`（Task 6/5）、`CommandRunner`/`ProcessCommandRunner`（既有）。
- Produces：一个监听 `NTFSHelperSocket.path` 的常驻可执行文件，供 Task 8（安装脚本会把它复制到 `NTFSHelperSocket.helperInstallPath` 并注册为 LaunchDaemon）、Task 9（Agent 侧客户端连接它）使用。

- [ ] **Step 1: 实现 `NTFSPrivilegedHelper` 主循环**

创建 `Sources/AutoVolumeNTFSHelper/main.swift`：

```swift
import Foundation
import Darwin
import AutoVolumeShared

let socketPath = NTFSHelperSocket.path
unlink(socketPath)

let serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
guard serverSocket >= 0 else {
    fputs("NTFSPrivilegedHelper: failed to create socket (errno \(errno))\n", stderr)
    exit(1)
}

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8CString)
withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
    let buffer = rawBuffer.bindMemory(to: CChar.self)
    for index in 0..<min(pathBytes.count, buffer.count) {
        buffer[index] = pathBytes[index]
    }
}

let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(serverSocket, sockaddrPointer, addrSize)
    }
}
guard bindResult == 0 else {
    fputs("NTFSPrivilegedHelper: bind failed (errno \(errno))\n", stderr)
    exit(1)
}
chmod(socketPath, 0o666)
guard listen(serverSocket, 8) == 0 else {
    fputs("NTFSPrivilegedHelper: listen failed (errno \(errno))\n", stderr)
    exit(1)
}

let mountPlanner = NTFSMountPlanner(ntfs3gPath: NTFSDriverPaths.ntfs3gExecutablePath)
let commandRunner = ProcessCommandRunner()

func peerUID(of fileDescriptor: Int32) -> uid_t? {
    var credential = xucred()
    var credentialSize = socklen_t(MemoryLayout<xucred>.size)
    guard getsockopt(fileDescriptor, 0, LOCAL_PEERCRED, &credential, &credentialSize) == 0 else { return nil }
    return credential.cr_uid
}

func respond(_ response: NTFSHelperResponse, on clientSocket: Int32) {
    guard let encoded = try? NTFSHelperWireFormat.encode(response) else { return }
    encoded.withUnsafeBytes { buffer in
        _ = write(clientSocket, buffer.baseAddress, buffer.count)
    }
}

func handle(clientSocket: Int32) {
    defer { close(clientSocket) }

    guard let uid = peerUID(of: clientSocket), uid != 0 else {
        respond(NTFSHelperResponse(success: false, message: "unauthorized"), on: clientSocket)
        return
    }

    var buffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = read(clientSocket, &buffer, buffer.count)
    guard bytesRead > 0 else { return }
    let requestData = Data(buffer[0..<bytesRead])

    do {
        let request = try NTFSHelperWireFormat.decodeRequest(requestData)
        if let validationError = NTFSHelperRequestValidator.validate(request) {
            respond(NTFSHelperResponse(success: false, message: validationError), on: clientSocket)
            return
        }

        switch request.action {
        case .mount:
            guard let devicePath = request.devicePath else {
                respond(NTFSHelperResponse(success: false, message: "devicePath is required for mount"), on: clientSocket)
                return
            }
            _ = try? commandRunner.run(mountPlanner.unmountReadOnlyPlan(mountPoint: request.mountPoint))
            let mountResult = try commandRunner.run(mountPlanner.mountReadWritePlan(devicePath: devicePath, mountPoint: request.mountPoint))
            respond(NTFSHelperResponse(success: mountResult.exitCode == 0, message: mountResult.stderr), on: clientSocket)
        case .unmount:
            let result = try commandRunner.run(mountPlanner.unmountReadOnlyPlan(mountPoint: request.mountPoint))
            respond(NTFSHelperResponse(success: result.exitCode == 0, message: result.stderr), on: clientSocket)
        }
    } catch {
        respond(NTFSHelperResponse(success: false, message: error.localizedDescription), on: clientSocket)
    }
}

while true {
    let clientSocket = accept(serverSocket, nil, nil)
    guard clientSocket >= 0 else { continue }
    handle(clientSocket: clientSocket)
}
```

- [ ] **Step 2: 创建 LaunchDaemon plist**

创建 `Resources/com.autovolume.ntfshelper.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.autovolume.ntfshelper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/com.autovolume.ntfshelper</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

（`Label` 和 `ProgramArguments` 的值必须与 `NTFSHelperSocket.daemonLabel`、`NTFSHelperSocket.helperInstallPath` 保持一致，Task 8 的安装脚本依赖这个一致性。）

- [ ] **Step 3: 手动验证编译通过**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macosx14.0 -parse Sources/AutoVolumeNTFSHelper/main.swift -I <指向已编译的 AutoVolumeShared.swiftmodule 目录，参照 Task 13 构建脚本里其他可执行目标的编译方式>`
Expected: 无编译错误。完整构建接入留到 Task 13（此时项目构建脚本还没有加入这个新的可执行目标，属预期）。

- [ ] **Step 4: Commit**

```bash
git add Sources/AutoVolumeNTFSHelper/main.swift Resources/com.autovolume.ntfshelper.plist
git commit -m "feat: add NTFSPrivilegedHelper LaunchDaemon for root-level NTFS mount/unmount"
```

- [ ] **Step 5: 派发 security-reviewer 复核（本任务完成的必要条件）**

对本任务的 diff 派发一次 `security-reviewer` agent 复核，重点见本任务开头的说明。若复核发现问题，在本任务范围内修复后重新运行 Step 3 验证编译，再重新提交一次 commit。

---

### Task 8: `NTFSDriverInstaller`（安装 FUSE-T + Helper + LaunchDaemon，一次管理员密码授权完成全部）

推荐模型：sonnet 5。

**说明：** 这是原设计里 `NTFSDriverInstaller` 的修订版——不再只安装 FUSE-T，而是把 FUSE-T pkg 安装、ntfs-3g 二进制拷贝、`NTFSPrivilegedHelper` 安装、LaunchDaemon 注册全部合并进**同一次** `osascript ... with administrator privileges` 调用，确保用户只需要输入一次密码。

**Files:**
- Create: `Sources/AutoVolumeShared/NTFSDriverInstaller.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Consumes：`CommandPlan`（既有）、`NTFSDriverPaths`、`NTFSHelperSocket`（Task 5）
- Produces：
  ```swift
  public struct NTFSDriverInstaller {
      public init(fileManager: FileManager = .default, fuseTMarkerPath: String = "/Library/Application Support/fuse-t/uninstall.sh")
      public func isFUSETInstalled() -> Bool
      public func isHelperInstalled() -> Bool   // 检测 NTFSHelperSocket.daemonPlistInstallPath 是否存在
      public func isFullyInstalled() -> Bool   // isFUSETInstalled() && isHelperInstalled()
      public func installPlan(bundledInstallerPkgPath: String, bundledHelperExecutablePath: String, bundledDaemonPlistPath: String, bundledNTFS3GPath: String, bundledNTFS3GDylibPath: String) -> CommandPlan
  }
  ```
  供 Task 11（`NTFSAutoMountService`）使用。`installPlan` 构造的 `CommandPlan` 在**不需要 root 权限的 Agent 进程内**执行（`osascript` 自己会弹出管理员密码授权对话框，这与现有 App 里其他需要提权的操作方式一致，不需要 Agent 自身是特权进程）。

- [ ] **Step 1: 写失败测试**

```swift
func testNTFSDriverInstallerDetectsFUSETInstalledMarker() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let markerPath = directory.appendingPathComponent("uninstall.sh").path
    try "".write(toFile: markerPath, atomically: true, encoding: .utf8)

    let installer = NTFSDriverInstaller(fuseTMarkerPath: markerPath)

    try expect(installer.isFUSETInstalled() == true, "Installer should report FUSE-T installed when the marker file exists")
}

func testNTFSDriverInstallerDetectsFUSETMissingMarker() throws {
    let installer = NTFSDriverInstaller(fuseTMarkerPath: "/tmp/\(UUID().uuidString)/does-not-exist.sh")

    try expect(installer.isFUSETInstalled() == false, "Installer should report FUSE-T not installed when the marker file is missing")
}

func testNTFSDriverInstallerHelperInstalledMatchesDaemonPlistPresence() throws {
    let installer = NTFSDriverInstaller()

    let matchesRealFilesystemState = installer.isHelperInstalled() == FileManager.default.fileExists(atPath: NTFSHelperSocket.daemonPlistInstallPath)

    try expect(matchesRealFilesystemState, "isHelperInstalled() should reflect whether the daemon plist exists on disk")
}

func testNTFSDriverInstallerBuildsSingleAdminPrivilegedInstallPlan() throws {
    let installer = NTFSDriverInstaller()

    let plan = installer.installPlan(
        bundledInstallerPkgPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/fuse-t-installer.pkg",
        bundledHelperExecutablePath: "/Applications/AutoVolume.app/Contents/Resources/NTFSPrivilegedHelper",
        bundledDaemonPlistPath: "/Applications/AutoVolume.app/Contents/Resources/com.autovolume.ntfshelper.plist",
        bundledNTFS3GPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/ntfs-3g",
        bundledNTFS3GDylibPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/libntfs-3g.89.dylib"
    )

    try expect(plan.executable == "/usr/bin/osascript", "Install plan should run through osascript for a single admin-privileged prompt")
    try expect(plan.arguments.count == 2 && plan.arguments[0] == "-e", "Install plan should be a single osascript -e invocation")
    let script = plan.arguments[1]
    try expect(script.contains("with administrator privileges"), "Install plan must request administrator privileges")
    try expect(script.contains("installer -pkg"), "Install plan must install the bundled FUSE-T pkg")
    try expect(script.contains(NTFSHelperSocket.helperInstallPath), "Install plan must copy the helper to its install path")
    try expect(script.contains(NTFSHelperSocket.daemonPlistInstallPath), "Install plan must copy the LaunchDaemon plist to its install path")
    try expect(script.contains("launchctl bootstrap system"), "Install plan must bootstrap the LaunchDaemon")
}
```

添加到 `tests` 数组：

```swift
    ("NTFSDriverInstaller detects FUSE-T installed marker", testNTFSDriverInstallerDetectsFUSETInstalledMarker),
    ("NTFSDriverInstaller detects FUSE-T missing marker", testNTFSDriverInstallerDetectsFUSETMissingMarker),
    ("NTFSDriverInstaller helper-installed matches daemon plist presence", testNTFSDriverInstallerHelperInstalledMatchesDaemonPlistPresence),
    ("NTFSDriverInstaller builds single admin-privileged install plan", testNTFSDriverInstallerBuildsSingleAdminPrivilegedInstallPlan),
```

- [ ] **Step 2: 运行确认失败**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译失败（类型不存在）

- [ ] **Step 3: 实现**

```swift
import Foundation

public struct NTFSDriverInstaller {
    private let fileManager: FileManager
    private let fuseTMarkerPath: String

    public init(fileManager: FileManager = .default, fuseTMarkerPath: String = "/Library/Application Support/fuse-t/uninstall.sh") {
        self.fileManager = fileManager
        self.fuseTMarkerPath = fuseTMarkerPath
    }

    public func isFUSETInstalled() -> Bool {
        fileManager.fileExists(atPath: fuseTMarkerPath)
    }

    public func isHelperInstalled() -> Bool {
        fileManager.fileExists(atPath: NTFSHelperSocket.daemonPlistInstallPath)
    }

    public func isFullyInstalled() -> Bool {
        isFUSETInstalled() && isHelperInstalled()
    }

    public func installPlan(
        bundledInstallerPkgPath: String,
        bundledHelperExecutablePath: String,
        bundledDaemonPlistPath: String,
        bundledNTFS3GPath: String,
        bundledNTFS3GDylibPath: String
    ) -> CommandPlan {
        let driverDir = NTFSDriverPaths.installDirectory
        let shellCommand = """
        set -e
        installer -pkg '\(shellEscaped(bundledInstallerPkgPath))' -target /
        mkdir -p '\(shellEscaped(driverDir))'
        cp '\(shellEscaped(bundledNTFS3GPath))' '\(shellEscaped(NTFSDriverPaths.ntfs3gExecutablePath))'
        cp '\(shellEscaped(bundledNTFS3GDylibPath))' '\(shellEscaped(NTFSDriverPaths.ntfs3gDylibPath))'
        chmod 755 '\(shellEscaped(NTFSDriverPaths.ntfs3gExecutablePath))'
        cp '\(shellEscaped(bundledHelperExecutablePath))' '\(shellEscaped(NTFSHelperSocket.helperInstallPath))'
        chown root:wheel '\(shellEscaped(NTFSHelperSocket.helperInstallPath))'
        chmod 544 '\(shellEscaped(NTFSHelperSocket.helperInstallPath))'
        cp '\(shellEscaped(bundledDaemonPlistPath))' '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))'
        chown root:wheel '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))'
        chmod 644 '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))'
        launchctl bootstrap system '\(shellEscaped(NTFSHelperSocket.daemonPlistInstallPath))'
        """
        let escapedShellCommand = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return CommandPlan(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "do shell script \"\(escapedShellCommand)\" with administrator privileges"]
        )
    }

    private func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSDriverInstaller.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add NTFSDriverInstaller for one-shot FUSE-T + privileged helper install"
```

---

### Task 9: `NTFSHelperClient`（Agent 侧 socket 客户端）

推荐模型：sonnet 5。

**Files:**
- Create: `Sources/AutoVolumeShared/NTFSHelperClient.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Consumes：`NTFSHelperRequest`、`NTFSHelperResponse`、`NTFSHelperWireFormat`、`NTFSHelperSocket`（Task 5）
- Produces：
  ```swift
  public protocol NTFSHelperClientProtocol {
      func send(_ request: NTFSHelperRequest) -> NTFSHelperResponse
  }
  public struct NTFSHelperClient: NTFSHelperClientProtocol {
      public init(socketPath: String = NTFSHelperSocket.path)
      public func send(_ request: NTFSHelperRequest) -> NTFSHelperResponse
  }
  ```
  供 Task 11（`NTFSAutoMountService`）使用；协议化是为了让 Task 11 的测试可以注入一个 `RecordingHelperClient` 假实现，不需要真实连接 socket。`NTFSHelperClient.send` 内部：连接 Unix domain socket → 写入编码后的请求 → 读取响应 → 解码；任何 socket/编解码失败都返回 `NTFSHelperResponse(success: false, message: "...")`，不 `throw`（调用方总能拿到一个明确的结果，不需要处理 socket 层错误）。

- [ ] **Step 1: 写失败测试——只测试对 socket 不存在时的降级行为（真实 socket 通信是运行时集成行为，交给用户用真机自测，见 Task 13）**

```swift
func testNTFSHelperClientReturnsFailureWhenSocketMissing() throws {
    let client = NTFSHelperClient(socketPath: "/tmp/\(UUID().uuidString)/does-not-exist.sock")

    let response = client.send(NTFSHelperRequest(action: .unmount, mountPoint: "/Volumes/USB"))

    try expect(response.success == false, "Sending to a non-existent socket should return a failure response, not crash or throw")
}

func testNTFSHelperClientConformsToProtocol() throws {
    let client: NTFSHelperClientProtocol = NTFSHelperClient(socketPath: "/tmp/\(UUID().uuidString)/does-not-exist.sock")

    let response = client.send(NTFSHelperRequest(action: .mount, devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB"))

    try expect(response.success == false, "NTFSHelperClient should be usable through NTFSHelperClientProtocol")
}
```

添加到 `tests` 数组：

```swift
    ("NTFSHelperClient returns failure when socket missing", testNTFSHelperClientReturnsFailureWhenSocketMissing),
    ("NTFSHelperClient conforms to NTFSHelperClientProtocol", testNTFSHelperClientConformsToProtocol),
```

- [ ] **Step 2: 运行确认失败**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译失败（类型不存在）

- [ ] **Step 3: 实现**

```swift
import Foundation
import Darwin

public protocol NTFSHelperClientProtocol {
    func send(_ request: NTFSHelperRequest) -> NTFSHelperResponse
}

public struct NTFSHelperClient: NTFSHelperClientProtocol {
    private let socketPath: String

    public init(socketPath: String = NTFSHelperSocket.path) {
        self.socketPath = socketPath
    }

    public func send(_ request: NTFSHelperRequest) -> NTFSHelperResponse {
        let clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientSocket >= 0 else {
            return NTFSHelperResponse(success: false, message: "failed to create socket")
        }
        defer { close(clientSocket) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: CChar.self)
            for index in 0..<min(pathBytes.count, buffer.count) {
                buffer[index] = pathBytes[index]
            }
        }

        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(clientSocket, sockaddrPointer, addrSize)
            }
        }
        guard connectResult == 0 else {
            return NTFSHelperResponse(success: false, message: "could not connect to NTFSPrivilegedHelper (errno \(errno))")
        }

        guard let requestData = try? NTFSHelperWireFormat.encode(request) else {
            return NTFSHelperResponse(success: false, message: "failed to encode request")
        }
        let bytesWritten = requestData.withUnsafeBytes { buffer -> Int in
            write(clientSocket, buffer.baseAddress, buffer.count)
        }
        guard bytesWritten == requestData.count else {
            return NTFSHelperResponse(success: false, message: "failed to write request")
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientSocket, &buffer, buffer.count)
        guard bytesRead > 0 else {
            return NTFSHelperResponse(success: false, message: "no response from NTFSPrivilegedHelper")
        }

        guard let response = try? NTFSHelperWireFormat.decodeResponse(Data(buffer[0..<bytesRead])) else {
            return NTFSHelperResponse(success: false, message: "failed to decode response")
        }
        return response
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSHelperClient.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add NTFSHelperClient for Agent-side helper socket IPC"
```

---

### Task 10: `NTFSRemountDebouncer`（防止我们自己触发的挂载事件被重复处理）

推荐模型：sonnet 5。

**Files:**
- Create: `Sources/AutoVolumeShared/NTFSRemountDebouncer.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Produces：
  ```swift
  public final class NTFSRemountDebouncer {
      public init(cooldown: TimeInterval = 30)
      public func shouldProcess(bsdName: String, now: Date = Date()) -> Bool
      public func markProcessed(bsdName: String, at date: Date = Date())
  }
  ```
  供 Task 11 使用：ntfs-3g 挂载成功后，DiskArbitration 会再次为新挂载点触发一次 appeared 回调，必须能识别"这是我们自己刚处理过的设备"从而跳过，避免死循环。

- [ ] **Step 1: 写失败测试**

```swift
func testNTFSRemountDebouncerSuppressesWithinCooldown() throws {
    let debouncer = NTFSRemountDebouncer(cooldown: 30)
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    try expect(debouncer.shouldProcess(bsdName: "disk4s1", now: start) == true, "First occurrence should be processed")
    debouncer.markProcessed(bsdName: "disk4s1", at: start)
    try expect(debouncer.shouldProcess(bsdName: "disk4s1", now: start.addingTimeInterval(5)) == false, "Re-appearance within the cooldown window should be suppressed")
}

func testNTFSRemountDebouncerAllowsAfterCooldownExpires() throws {
    let debouncer = NTFSRemountDebouncer(cooldown: 30)
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    debouncer.markProcessed(bsdName: "disk4s1", at: start)
    try expect(debouncer.shouldProcess(bsdName: "disk4s1", now: start.addingTimeInterval(31)) == true, "Re-appearance after the cooldown window should be processed (e.g. user re-inserted the drive)")
}

func testNTFSRemountDebouncerTracksDevicesIndependently() throws {
    let debouncer = NTFSRemountDebouncer(cooldown: 30)
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    debouncer.markProcessed(bsdName: "disk4s1", at: start)
    try expect(debouncer.shouldProcess(bsdName: "disk5s1", now: start.addingTimeInterval(1)) == true, "A different device should not be suppressed by another device's cooldown")
}
```

添加到 `tests` 数组：

```swift
    ("NTFSRemountDebouncer suppresses within cooldown", testNTFSRemountDebouncerSuppressesWithinCooldown),
    ("NTFSRemountDebouncer allows after cooldown", testNTFSRemountDebouncerAllowsAfterCooldownExpires),
    ("NTFSRemountDebouncer tracks devices independently", testNTFSRemountDebouncerTracksDevicesIndependently),
```

- [ ] **Step 2: 运行确认失败**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译失败（类型不存在）

- [ ] **Step 3: 实现**

```swift
import Foundation

public final class NTFSRemountDebouncer {
    private let cooldown: TimeInterval
    private var lastProcessed: [String: Date] = [:]
    private let lock = NSLock()

    public init(cooldown: TimeInterval = 30) {
        self.cooldown = cooldown
    }

    public func shouldProcess(bsdName: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastProcessed[bsdName] else { return true }
        return now.timeIntervalSince(last) > cooldown
    }

    public func markProcessed(bsdName: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        lastProcessed[bsdName] = date
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSRemountDebouncer.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add NTFSRemountDebouncer to prevent remount event loops"
```

---

### Task 11: `NTFSAutoMountService`（DiskArbitration 编排，经由 Helper 完成挂载）+ 接入 `AutoVolumeAgent`

推荐模型：sonnet 5（编排逻辑用到 DiskArbitration C API，实现时如遇 API 细节问题可切换 opus 5.2 排查）。

**说明：** 与原设计的关键区别——本服务**不再**直接用 `CommandRunner` 调用 `ntfs-3g`；实际挂载/卸载改为通过 `NTFSHelperClientProtocol` 发送请求给 `NTFSPrivilegedHelper`（Task 7/9）。驱动安装（`NTFSDriverInstaller.installPlan`）仍然由 `AutoVolumeAgent`（无权限进程）通过 `commandRunner` 触发——这一步本身就是 `osascript ... with administrator privileges`，会自己弹出密码框，不需要 Agent 是特权进程。

**Files:**
- Create: `Sources/AutoVolumeShared/NTFSAutoMountService.swift`
- Modify: `Sources/AutoVolumeAgent/main.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Consumes：`NTFSDiskClassifier`（Task 3）、`NTFSMountedVolumesStore`（Task 4）、`NTFSDriverInstaller`（Task 8）、`NTFSHelperClientProtocol`/`NTFSHelperRequest`（Task 5/9）、`NTFSRemountDebouncer`（Task 10）、`CommandRunner`（既有，仅用于驱动安装）、`AlertStore`（既有，用于一次性提醒）。
- Produces：
  ```swift
  public final class NTFSAutoMountService {
      public init(
          settingsStore: AppSettingsStore = JSONAppSettingsStore(),
          driverInstaller: NTFSDriverInstaller = NTFSDriverInstaller(),
          helperClient: NTFSHelperClientProtocol = NTFSHelperClient(),
          mountedVolumesStore: NTFSMountedVolumesStore = NTFSMountedVolumesStore(),
          commandRunner: CommandRunner = ProcessCommandRunner(),
          alertStore: AlertStore = AlertStore(),
          debouncer: NTFSRemountDebouncer = NTFSRemountDebouncer(),
          bundledInstallerPaths: NTFSBundledInstallerPaths = NTFSBundledInstallerPaths()
      )
      public static let onboardingAlertID: UUID
      public func handleDiskEligibleForReadWrite(bsdName: String, devicePath: String, volumeName: String, mountPoint: String, filesystemPersonality: String?, mountedFileSystemName: String?)
      public func handleDiskDisappeared(bsdName: String)
  }
  public struct NTFSBundledInstallerPaths {
      public var fuseTInstallerPkgPath: String
      public var helperExecutablePath: String
      public var daemonPlistPath: String
      public var ntfs3gPath: String
      public var ntfs3gDylibPath: String
      public init(bundle: Bundle = .main)   // 用 Bundle.main 定位 App bundle 内的 Resources，取不到时回退到 /Applications/AutoVolume.app/Contents/Resources/... 的默认路径
  }
  ```
  `handleDiskEligibleForReadWrite`/`handleDiskDisappeared` 是从 DiskArbitration 回调中提取好字段后调用的纯编排入口，方便测试时绕过真实 DiskArbitration 会话直接调用。`NTFSBundledInstallerPaths` 把原来散落在 `Bundle.main.path(forResource:...)` 里的逻辑收成一个可注入的小结构体，方便测试用固定字符串路径构造。

- [ ] **Step 1: 写失败测试——设置关闭时只记录一次性提醒，不挂载**

```swift
func testNTFSAutoMountServiceRecordsOnboardingAlertWhenSettingDisabled() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let alertsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let volumesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: settingsDirectory)
        try? FileManager.default.removeItem(at: alertsDirectory)
        try? FileManager.default.removeItem(at: volumesDirectory)
    }
    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: false))
    let commandRunner = RecordingCommandRunner()
    let helperClient = RecordingHelperClient()
    let alertStore = AlertStore(directory: alertsDirectory)
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: "/tmp/\(UUID().uuidString)/missing"),
        helperClient: helperClient,
        mountedVolumesStore: NTFSMountedVolumesStore(directory: volumesDirectory),
        commandRunner: commandRunner,
        alertStore: alertStore
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")

    try expect(commandRunner.plans.isEmpty, "No install commands should run while the setting is disabled")
    try expect(helperClient.sentRequests.isEmpty, "No helper requests should be sent while the setting is disabled")
    let alerts = try alertStore.load()
    try expect(alerts.contains { $0.volumeID == NTFSAutoMountService.onboardingAlertID }, "A one-time onboarding alert should be recorded when an NTFS drive is seen with the setting disabled")
}

func testNTFSAutoMountServiceSkipsWhenAlreadyOwnedByOurDriver() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: settingsDirectory) }
    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: true))
    let commandRunner = RecordingCommandRunner()
    let helperClient = RecordingHelperClient()
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: "/tmp/\(UUID().uuidString)/missing"),
        helperClient: helperClient,
        mountedVolumesStore: NTFSMountedVolumesStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        commandRunner: commandRunner,
        alertStore: AlertStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "fusefs_ntfs")

    try expect(commandRunner.plans.isEmpty, "Disks already mounted by our own driver should not be reprocessed")
    try expect(helperClient.sentRequests.isEmpty, "Disks already mounted by our own driver should not trigger a helper request")
}

func testNTFSAutoMountServiceInstallsDriverThenSendsHelperMountRequest() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let volumesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let markerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: settingsDirectory)
        try? FileManager.default.removeItem(at: volumesDirectory)
        try? FileManager.default.removeItem(at: markerDirectory)
    }
    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: true))
    let markerPath = markerDirectory.appendingPathComponent("uninstall.sh").path
    // marker does not exist yet: installer must run first
    let commandRunner = RecordingCommandRunner()
    let helperClient = RecordingHelperClient(responseToReturn: NTFSHelperResponse(success: true))
    let volumesStore = NTFSMountedVolumesStore(directory: volumesDirectory)
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: markerPath),
        helperClient: helperClient,
        mountedVolumesStore: volumesStore,
        commandRunner: commandRunner,
        alertStore: AlertStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")

    try expect(commandRunner.plans.count == 1, "Expected exactly the driver install command; got \(commandRunner.plans.count)")
    try expect(commandRunner.plans[0].executable == "/usr/bin/osascript", "The one command run by the Agent should be the driver install")
    try expect(helperClient.sentRequests.count == 1, "Expected exactly one mount request sent to the helper")
    try expect(helperClient.sentRequests[0] == NTFSHelperRequest(action: .mount, devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB"), "Helper request did not match expected mount request")
    let volumes = try volumesStore.load()
    try expect(volumes.contains { $0.bsdName == "disk4s1" }, "The remounted volume should be recorded in NTFSMountedVolumesStore")
}

func testNTFSAutoMountServiceDoesNotRecordVolumeWhenHelperMountFails() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let volumesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: settingsDirectory)
        try? FileManager.default.removeItem(at: volumesDirectory)
    }
    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: true))
    let helperClient = RecordingHelperClient(responseToReturn: NTFSHelperResponse(success: false, message: "mount failed"))
    let volumesStore = NTFSMountedVolumesStore(directory: volumesDirectory)
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(fuseTMarkerPath: "/Library/Application Support/fuse-t/uninstall.sh"),
        helperClient: helperClient,
        mountedVolumesStore: volumesStore,
        commandRunner: RecordingCommandRunner(),
        alertStore: AlertStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")

    let volumes = try volumesStore.load()
    try expect(volumes.isEmpty, "A failed helper mount must not be recorded as an active NTFS volume")
}
```

添加到 `tests` 数组：

```swift
    ("NTFSAutoMountService onboarding alert when disabled", testNTFSAutoMountServiceRecordsOnboardingAlertWhenSettingDisabled),
    ("NTFSAutoMountService skips already-owned mounts", testNTFSAutoMountServiceSkipsWhenAlreadyOwnedByOurDriver),
    ("NTFSAutoMountService installs driver then sends helper mount request", testNTFSAutoMountServiceInstallsDriverThenSendsHelperMountRequest),
    ("NTFSAutoMountService does not record volume when helper mount fails", testNTFSAutoMountServiceDoesNotRecordVolumeWhenHelperMountFails),
```

同时在 `ManualTests/AutoVolumeManualTests.swift` 文件底部（`RecordingCommandRunner`/`SequenceCommandRunner` 定义附近）新增一个测试替身，供上面几个测试使用：

```swift
final class RecordingHelperClient: NTFSHelperClientProtocol {
    var sentRequests: [NTFSHelperRequest] = []
    private let responseToReturn: NTFSHelperResponse

    init(responseToReturn: NTFSHelperResponse = NTFSHelperResponse(success: true)) {
        self.responseToReturn = responseToReturn
    }

    func send(_ request: NTFSHelperRequest) -> NTFSHelperResponse {
        sentRequests.append(request)
        return responseToReturn
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译失败（`NTFSAutoMountService`/`RecordingHelperClient` 不存在）

- [ ] **Step 3: 实现 `NTFSAutoMountService`**

```swift
import Foundation

public struct NTFSBundledInstallerPaths {
    public var fuseTInstallerPkgPath: String
    public var helperExecutablePath: String
    public var daemonPlistPath: String
    public var ntfs3gPath: String
    public var ntfs3gDylibPath: String

    public init(bundle: Bundle = .main) {
        let resourcesPath = bundle.resourcePath ?? "/Applications/AutoVolume.app/Contents/Resources"
        self.fuseTInstallerPkgPath = resourcesPath + "/NTFSDriver/fuse-t-installer.pkg"
        self.helperExecutablePath = resourcesPath + "/NTFSPrivilegedHelper"
        self.daemonPlistPath = resourcesPath + "/com.autovolume.ntfshelper.plist"
        self.ntfs3gPath = resourcesPath + "/NTFSDriver/ntfs-3g"
        self.ntfs3gDylibPath = resourcesPath + "/NTFSDriver/libntfs-3g.89.dylib"
    }
}

public final class NTFSAutoMountService {
    public static let onboardingAlertID = UUID(uuidString: "00000000-0000-0000-0000-00000000AF01")!

    private let settingsStore: AppSettingsStore
    private let driverInstaller: NTFSDriverInstaller
    private let helperClient: NTFSHelperClientProtocol
    private let mountedVolumesStore: NTFSMountedVolumesStore
    private let commandRunner: CommandRunner
    private let alertStore: AlertStore
    private let debouncer: NTFSRemountDebouncer
    private let bundledInstallerPaths: NTFSBundledInstallerPaths

    public init(
        settingsStore: AppSettingsStore = JSONAppSettingsStore(),
        driverInstaller: NTFSDriverInstaller = NTFSDriverInstaller(),
        helperClient: NTFSHelperClientProtocol = NTFSHelperClient(),
        mountedVolumesStore: NTFSMountedVolumesStore = NTFSMountedVolumesStore(),
        commandRunner: CommandRunner = ProcessCommandRunner(),
        alertStore: AlertStore = AlertStore(),
        debouncer: NTFSRemountDebouncer = NTFSRemountDebouncer(),
        bundledInstallerPaths: NTFSBundledInstallerPaths = NTFSBundledInstallerPaths()
    ) {
        self.settingsStore = settingsStore
        self.driverInstaller = driverInstaller
        self.helperClient = helperClient
        self.mountedVolumesStore = mountedVolumesStore
        self.commandRunner = commandRunner
        self.alertStore = alertStore
        self.debouncer = debouncer
        self.bundledInstallerPaths = bundledInstallerPaths
    }

    public func handleDiskEligibleForReadWrite(
        bsdName: String,
        devicePath: String,
        volumeName: String,
        mountPoint: String,
        filesystemPersonality: String?,
        mountedFileSystemName: String?
    ) {
        guard NTFSDiskClassifier.isNTFSFileSystem(personality: filesystemPersonality) else { return }
        guard !NTFSDiskClassifier.isOwnedByOurDriver(mountedFileSystemName: mountedFileSystemName) else { return }
        guard debouncer.shouldProcess(bsdName: bsdName) else { return }

        let settings = (try? settingsStore.load()) ?? AppSettings()
        guard settings.autoMountNTFSReadWrite else {
            try? alertStore.record(
                volumeID: Self.onboardingAlertID,
                volumeName: volumeName,
                message: "检测到 NTFS 硬盘「\(volumeName)」。前往设置开启「NTFS 读写支持」即可以读写方式挂载。"
            )
            return
        }

        if !driverInstaller.isFullyInstalled() {
            let plan = driverInstaller.installPlan(
                bundledInstallerPkgPath: bundledInstallerPaths.fuseTInstallerPkgPath,
                bundledHelperExecutablePath: bundledInstallerPaths.helperExecutablePath,
                bundledDaemonPlistPath: bundledInstallerPaths.daemonPlistPath,
                bundledNTFS3GPath: bundledInstallerPaths.ntfs3gPath,
                bundledNTFS3GDylibPath: bundledInstallerPaths.ntfs3gDylibPath
            )
            _ = try? commandRunner.run(plan)
        }

        let response = helperClient.send(NTFSHelperRequest(action: .mount, devicePath: devicePath, mountPoint: mountPoint))
        guard response.success else { return }

        debouncer.markProcessed(bsdName: bsdName)
        try? mountedVolumesStore.add(NTFSVolume(bsdName: bsdName, volumeName: volumeName, devicePath: devicePath, mountPoint: mountPoint, mountedAt: Date()))
        try? alertStore.resolve(volumeID: Self.onboardingAlertID)
    }

    public func handleDiskDisappeared(bsdName: String) {
        try? mountedVolumesStore.remove(bsdName: bsdName)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: 接入 `AutoVolumeAgent/main.swift`——注册 DiskArbitration 回调**

在 `Sources/AutoVolumeAgent/main.swift` 顶部 `import Darwin` 之后添加 `import DiskArbitration`，在文件中 `let alertStore = AlertStore()`（第 21 行）之后添加：

```swift
let ntfsAutoMountService = NTFSAutoMountService()

func startNTFSDiskWatcher() {
    guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
    DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

    let appearedCallback: DADiskAppearedCallback = { disk, _ in
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return }
        guard let bsdName = String(cString: DADiskGetBSDName(disk) ?? UnsafePointer(bitPattern: 1)!, encoding: .utf8), !bsdName.isEmpty else { return }
        let personality = description[kDADiskDescriptionVolumeKindKey as String] as? String
        let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String ?? bsdName
        guard let volumePath = description[kDADiskDescriptionVolumePathKey as String] as? URL else { return }
        let mountedFileSystemName = description[kDADiskDescriptionVolumeKindKey as String] as? String
        ntfsAutoMountService.handleDiskEligibleForReadWrite(
            bsdName: bsdName,
            devicePath: "/dev/\(bsdName)",
            volumeName: volumeName,
            mountPoint: volumePath.path,
            filesystemPersonality: personality,
            mountedFileSystemName: mountedFileSystemName
        )
    }
    let disappearedCallback: DADiskDisappearedCallback = { disk, _ in
        guard let bsdName = String(cString: DADiskGetBSDName(disk) ?? UnsafePointer(bitPattern: 1)!, encoding: .utf8), !bsdName.isEmpty else { return }
        ntfsAutoMountService.handleDiskDisappeared(bsdName: bsdName)
    }
    DARegisterDiskAppearedCallback(session, nil, appearedCallback, nil)
    DARegisterDiskDisappearedCallback(session, nil, disappearedCallback, nil)
}

startNTFSDiskWatcher()
```

> 注：`DADiskCopyDescription` 返回的具体 key 名称（`kDADiskDescriptionVolumeKindKey` 是否等价于「文件系统类型」还是需要改用 `kDADiskDescriptionMediaKindKey`）在真实设备上可能与文档不完全一致——这是实现该步骤时唯一允许通过手动插拔真实/虚拟 NTFS 盘临时验证并调整的地方（用 `print(description)` 打印完整字典核对 key），不影响本任务其余部分（Step 1-4）已经落地的可测试逻辑。`AutoVolumeAgent` 运行在没有 `Bundle.main` 指向 App bundle 的普通命令行上下文中吗？不会——`AutoVolumeAgent` 本身也是从 `AutoVolume.app/Contents/Resources/AutoVolumeAgent` 启动的，`Bundle.main` 在它里面指向的是 Agent 自己的可执行文件而非 App bundle，因此 `NTFSBundledInstallerPaths()` 默认参数里的 `Bundle.main.resourcePath` 在 Agent 进程里可能拿不到期望的路径——**这里改为显式传入基于 Agent 自身可执行文件位置推导的路径**：把上面 `NTFSAutoMountService()` 一行改成：
>
> ```swift
> let agentExecutableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
> let appResourcesPath = agentExecutableURL.deletingLastPathComponent().path // .../AutoVolume.app/Contents/Resources
> let ntfsAutoMountService = NTFSAutoMountService(bundledInstallerPaths: NTFSBundledInstallerPaths(bundle: Bundle(path: appResourcesPath) ?? Bundle.main))
> ```
>
> （`AutoVolumeAgent` 二进制本身就安装在 `Contents/Resources/AutoVolumeAgent`，所以它的上一级目录正是 `Contents/Resources`，与 `NTFSBundledInstallerPaths` 期望的 `resourcePath` 一致。）

- [ ] **Step 6: 构建确认整体编译通过（含 DiskArbitration 框架链接，见 Task 13）**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译成功、全部 manual tests `PASS`（Task 13 会补上 `-framework DiskArbitration` 链接参数，如果此步先报链接错误属预期，留到 Task 13 解决）

- [ ] **Step 7: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSAutoMountService.swift Sources/AutoVolumeAgent/main.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: wire NTFSAutoMountService into AutoVolumeAgent via DiskArbitration and the privileged helper"
```

---

### Task 12: Settings 开关 + 一次性提醒展示

推荐模型：sonnet 5。

**Files:**
- Modify: `Sources/AutoVolumeApp/SettingsView.swift`

**Interfaces:**
- Consumes：`AppSettings.autoMountNTFSReadWrite`（Task 2）、`AppViewModel.updateSettings`/`AppViewModel.alerts`（既有，onboarding 提醒已经通过 Task 11 写入的 `AlertStore` 自动出现在既有的提醒铃铛菜单里，无需改动 `ContentView.swift`）。

- [ ] **Step 1: 修改 `SettingsView` 增加开关（手动验证用例：打开设置面板，勾选后卷列表下次检测到 NTFS 盘应触发读写挂载，取消勾选后应恢复只读且不再弹出一次性提醒）**

`Sources/AutoVolumeApp/SettingsView.swift` 中：

```swift
struct SettingsView: View {
    let viewModel: AppViewModel

    @State private var logLevel: LogLevel
    @State private var openFinderAfterMount: Bool
    @State private var autoMountNTFSReadWrite: Bool

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _logLevel = State(initialValue: viewModel.settings.logLevel)
        _openFinderAfterMount = State(initialValue: viewModel.settings.openFinderAfterMount)
        _autoMountNTFSReadWrite = State(initialValue: viewModel.settings.autoMountNTFSReadWrite)
    }

    var body: some View {
        Form {
            Section(localized("日志", "Logging")) {
                Picker(localized("日志错误级别", "Log Level"), selection: $logLevel) {
                    Text(localized("全部", "All")).tag(LogLevel.info)
                    Text(localized("警告及以上", "Warning and above")).tag(LogLevel.warning)
                    Text(localized("仅错误", "Errors only")).tag(LogLevel.error)
                }
                Text(localized("调整后，低于所选级别的日志将不会写入日志文件。日志文件大小限制不变。", "After adjusting, log entries below the selected level won't be written to the log file. The log file size limit is unchanged."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(localized("挂载", "Mounting")) {
                Toggle(localized("重连成功后自动在 Finder 中打开", "Open in Finder after a successful reconnect"), isOn: $openFinderAfterMount)
                Text(localized("关闭后，自动挂载或重连成功将不会自动打开 Finder 窗口。", "When off, a successful automatic mount or reconnect won't open a Finder window."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(localized("NTFS 硬盘", "NTFS Drives")) {
                Toggle(localized("自动以读写方式挂载 NTFS 外接硬盘", "Automatically mount external NTFS drives read-write"), isOn: $autoMountNTFSReadWrite)
                Text(localized("开启后，插入的 NTFS 格式硬盘会自动切换为可读写（首次开启需要输入一次管理员密码安装内置驱动，之后不再需要）。关闭时保持 macOS 原生只读挂载。", "When on, inserted NTFS drives are automatically switched to read-write (the first time requires an admin password to install the bundled driver, never again after that). When off, macOS's native read-only mount is left untouched."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 380)
        .onChange(of: logLevel) { _, newValue in
            viewModel.updateSettings(AppSettings(logLevel: newValue, openFinderAfterMount: openFinderAfterMount, autoMountNTFSReadWrite: autoMountNTFSReadWrite))
        }
        .onChange(of: openFinderAfterMount) { _, newValue in
            viewModel.updateSettings(AppSettings(logLevel: logLevel, openFinderAfterMount: newValue, autoMountNTFSReadWrite: autoMountNTFSReadWrite))
        }
        .onChange(of: autoMountNTFSReadWrite) { _, newValue in
            viewModel.updateSettings(AppSettings(logLevel: logLevel, openFinderAfterMount: openFinderAfterMount, autoMountNTFSReadWrite: newValue))
        }
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        viewModel.language == .chinese ? chinese : english
    }
}
```

- [ ] **Step 2: 手动验证（这是纯 SwiftUI 绑定改动，本项目 UI 层没有自动化测试覆盖，遵循既有 `VolumeEditorView`/`SettingsView` 的方式——通过 Step 5 的整体构建 + 用户自测 DMG 验证）**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译通过

- [ ] **Step 3: Commit**

```bash
git add Sources/AutoVolumeApp/SettingsView.swift
git commit -m "feat: add NTFS read-write toggle to Settings"
```

---

### Task 13: 构建脚本接入（新文件、新可执行目标、DiskArbitration 链接、驱动+Helper 资源打包）+ 版本发布

推荐模型：sonnet 5。

**Files:**
- Modify: `script/build_and_run.sh`
- Modify: `Resources/Info.plist`

**Interfaces:**
- 无新增代码接口；这是把前面所有任务新增的文件正式接入项目"唯一真实"的构建/测试/打包流程，并新增一个可执行目标（`NTFSPrivilegedHelper`）。

- [ ] **Step 1: 在 `script/build_and_run.sh` 的 `AutoVolumeShared` swiftc 文件列表中追加新文件**

在 `Sources/AutoVolumeShared/AlertStore.swift`（该 swiftc 调用的最后一行输入文件）之后追加：

```
  Sources/AutoVolumeShared/AlertStore.swift \
  Sources/AutoVolumeShared/NTFSVolume.swift \
  Sources/AutoVolumeShared/NTFSMountedVolumesStore.swift \
  Sources/AutoVolumeShared/NTFSHelperProtocol.swift \
  Sources/AutoVolumeShared/NTFSMountPlanner.swift \
  Sources/AutoVolumeShared/NTFSDriverInstaller.swift \
  Sources/AutoVolumeShared/NTFSHelperClient.swift \
  Sources/AutoVolumeShared/NTFSRemountDebouncer.swift \
  Sources/AutoVolumeShared/NTFSAutoMountService.swift
```

（即把最后一行 `Sources/AutoVolumeShared/AlertStore.swift` 改成上面这段，用新文件列表替换原来单独一行的收尾。`AutoVolumeShared` 本身不直接使用 DiskArbitration/socket 特有的框架链接，不需要额外 `-framework`。）

在编译 `AutoVolumeAgent` 的 `swiftc` 调用里追加 `-framework DiskArbitration`（因为 Task 11 在 `Sources/AutoVolumeAgent/main.swift` 里直接 `import DiskArbitration` 并调用了它的 C API）：

```
swiftc \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -framework DiskArbitration \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/AutoVolumeAgent" \
  Sources/AutoVolumeAgent/main.swift
```

在同一个 `swiftc` 编译 `AutoVolumeApp`/`AutoVolumeAgent` 的区块之后，新增一个编译 `NTFSPrivilegedHelper` 的调用：

```
swiftc \
  -I "$BUILD/shared" \
  -L "$BUILD/shared" \
  -lAutoVolumeShared \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  -o "$BUILD/NTFSPrivilegedHelper" \
  Sources/AutoVolumeNTFSHelper/main.swift
```

- [ ] **Step 2: 在打包 App bundle 的阶段拷贝并签名驱动/Helper 资源**

在脚本中 `cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"` 之后、`codesign` 之前添加：

```bash
mkdir -p "$APP/Contents/Resources/NTFSDriver"
cp "$ROOT/Resources/NTFSDriver/ntfs-3g" "$APP/Contents/Resources/NTFSDriver/ntfs-3g"
cp "$ROOT/Resources/NTFSDriver/libntfs-3g.89.dylib" "$APP/Contents/Resources/NTFSDriver/libntfs-3g.89.dylib"
cp "$ROOT/Resources/NTFSDriver/fuse-t-installer.pkg" "$APP/Contents/Resources/NTFSDriver/fuse-t-installer.pkg"
cp "$ROOT/Resources/NTFSDriver/LICENSE-ntfs-3g.txt" "$APP/Contents/Resources/NTFSDriver/LICENSE-ntfs-3g.txt"
cp "$ROOT/Resources/NTFSDriver/LICENSE-fuse-t.txt" "$APP/Contents/Resources/NTFSDriver/LICENSE-fuse-t.txt"
chmod +x "$APP/Contents/Resources/NTFSDriver/ntfs-3g"
cp "$BUILD/NTFSPrivilegedHelper" "$APP/Contents/Resources/NTFSPrivilegedHelper"
cp "$ROOT/Resources/com.autovolume.ntfshelper.plist" "$APP/Contents/Resources/com.autovolume.ntfshelper.plist"
```

并在既有的 `codesign --force --sign - "$APP/Contents/Resources/AutoVolumeAgent"` 之后添加：

```bash
codesign --force --sign - "$APP/Contents/Resources/NTFSDriver/ntfs-3g"
codesign --force --sign - "$APP/Contents/Resources/NTFSPrivilegedHelper"
```

- [ ] **Step 3: 按 `CLAUDE.md` 流程升版本号**

编辑 `Resources/Info.plist`：将 `CFBundleShortVersionString` 从当前值递增 patch 号，`CFBundleVersion` 同步改为对应的纯数字。

- [ ] **Step 4: 完整构建并运行全部 manual tests**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch`
Expected: 编译成功（`ntfs-3g`、`DiskArbitration`、`NTFSPrivilegedHelper` 均构建/链接通过），全部既有 + 新增 manual tests `PASS`，无遗留失败。

- [ ] **Step 5: 打包 DMG**

Run: `script/package_dmg.sh <新版本号>`
Expected: `dist/AutoVolume-<新版本号>-local.dmg` 生成成功。

- [ ] **Step 6: Commit**

```bash
git add script/build_and_run.sh Resources/Info.plist
git commit -m "release: bundle NTFS driver, privileged helper, and prepare AutoVolume <新版本号>"
```

- [ ] **Step 7: 交给用户自测**

告知用户新 DMG 路径，请其用真实 NTFS 外接硬盘验证：① 设置关闭时看到一次性提醒但保持只读；② 设置开启后首次插入弹出**一次**管理员密码授权（同时安装 FUSE-T + 特权 helper），随后自动切换为可读写；③ 拔出后再插入不再重复请求密码、能立即读写（因为 helper 作为 LaunchDaemon 常驻，不需要重新安装）；④ 关闭设置开关后新插入的 NTFS 盘恢复只读；⑤ 重启 Mac 后 helper 应该自动随 LaunchDaemon 机制启动（`KeepAlive`/`RunAtLoad`），无需重新授权。不由 Claude 自行判定完成。

---

## Self-Review 记录

- **Spec 覆盖**：驱动选型（Task 1/6）、实时监控（DiskArbitration，Task 11）、无需 SIP/无需内核扩展（Task 1 选型 + Task 8 安装方式）、内置无需多次配置（Task 8/13 打包 + 一次管理员授权同时装 FUSE-T 和 helper）、默认关闭 + 一次性提醒（Task 2/11/12）、UI 展示（Task 12，复用既有提醒铃铛）、错误处理（Task 11 的 guard/回退到只读、helper 返回失败时不记录卷）、测试策略（每个纯逻辑 Task 都在 `ManualTests` 中补充用例；Task 7 的 socket 运行时 glue 明确标注不可脱离真实环境单测，留给 Task 13 的整体构建 + 用户自测覆盖）、**权限模型修正**（Task 5-9 新增的 `NTFSPrivilegedHelper` + IPC 协议，解决 Task 1 调研发现的 root 权限问题）均已覆盖。
- **占位符扫描**：已移除所有 TBD；Task 1 的两个原 spec"开放问题"已通过实际调研（包括权限模型问题的发现）转化为具体、已验证的结论，后续任务直接引用该结论而非留白。
- **类型一致性**：`NTFSHelperRequest`/`NTFSHelperResponse`/`NTFSHelperClientProtocol`/`NTFSDriverPaths`/`NTFSHelperSocket` 等类型在 Task 5-11 之间的方法签名、字段名已交叉核对一致；`NTFSDriverInstaller` 的方法名从原设计的 `isInstalled()` 改为 `isFUSETInstalled()`/`isHelperInstalled()`/`isFullyInstalled()`，已在 Task 8、Task 11 的所有引用处同步更新，无遗留旧名称引用。
- **安全审查标记**：Task 7（`NTFSPrivilegedHelper`）在 Global Constraints 和任务正文中都明确标注了必须过 `security-reviewer` 复核，这是本计划里唯一涉及特权守护进程/本地 IPC 的任务，风险最集中，已重点标注。
