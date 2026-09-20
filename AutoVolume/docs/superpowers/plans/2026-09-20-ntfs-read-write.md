# NTFS 实时读写支持 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AutoVolume 能够检测任意插入的 NTFS 外接硬盘，并在不禁用 SIP、不要求用户手动批准系统扩展的前提下，用内置的 FUSE-T + ntfs-3g 自动将其从只读切换为读写挂载。

**Architecture:** 新增 `NTFSAutoMountService`（运行在现有 `AutoVolumeAgent` launchd 常驻进程中）通过 DiskArbitration 事件回调（而非轮询）监听磁盘插入/拔出；纯逻辑（文件系统过滤、去抖、命令构造、驱动安装幂等性判断）拆分为独立可单元测试的类型，只有 DiskArbitration 的回调注册留在编排层。App 侧新增一个设置开关（默认关闭）和一次性提醒，复用现有 `AlertStore` 机制展示。

**Tech Stack:** Swift 5.10 / macOS 14+，DiskArbitration.framework，FUSE-T（BSD/MIT 授权，用户态、无内核扩展）+ ntfs-3g（GPLv2，作为独立子进程调用，不静态链接），项目现有的 `CommandRunner`/`CommandPlan` 抽象。

**Spec:** `docs/superpowers/specs/2026-09-20-ntfs-read-write-design.md`

## Global Constraints

- 不得禁用 SIP，不得要求用户在系统设置中手动批准 System Extension（这是选择 FUSE-T 而非 macFUSE 的硬性前提，见 spec）。
- `ntfs-3g`（GPLv2）必须以独立子进程方式调用（通过 `CommandPlan`/`Process`），禁止静态链接进 `AutoVolumeShared`，随包附带其 License 文本。
- 新增设置项 `autoMountNTFSReadWrite` 默认必须为 `false`（opt-in），且旧版本 `settings.json`（不含该字段）必须能正常解码，不能因缺字段而崩溃或报错。
- 本项目的权威测试套件是 `ManualTests/AutoVolumeManualTests.swift`（通过 `script/build_and_run.sh` 运行，见项目 `CLAUDE.md`），新逻辑必须在此文件中补充对应的 `test...()` 函数并注册进文件末尾的 `tests` 数组；纯逻辑代码禁止依赖 `Bundle.main` 或真实 DiskArbitration 会话，以便可在该套件中无物理硬盘的情况下运行。
- 项目构建脚本 `script/build_and_run.sh` 用显式文件列表调用 `swiftc`（不是 `swift build`），新增的 `Sources/AutoVolumeShared/*.swift` 文件必须手动加入该脚本里的编译文件列表，否则不会被打进 App。
- 每完成一次代码改动（包括中间迭代），必须按 `CLAUDE.md` 流程：升版本号 → `script/build_and_run.sh --no-launch` → `script/package_dmg.sh <version>` → 交给用户自测，不自行判定完成。

---

### Task 1: 调研并落地 FUSE-T + ntfs-3g 的本地安装与挂载方式（Spike，产出 vendored 二进制与调研文档）

**说明：** 这是唯一一个不遵循标准 TDD 步骤的任务——它是一次性的、需要物理/虚拟 NTFS 介质的手工调研（对应 spec 中的两个"开放问题"）。产出物是后续所有任务都会直接引用的**具体事实**（确切的挂载命令、驱动安装标记路径），因此必须先完成并写成文档，后续任务不得再引入新的猜测性命令。

推荐建议模型：opus 5.2（规划/调研判断），执行下方 shell 命令用 sonnet 5 即可。

**Files:**
- Create: `docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md`
- Create: `Resources/NTFSDriver/ntfs-3g`（vendored 二进制）
- Create: `Resources/NTFSDriver/LICENSE-ntfs-3g.txt`
- Create: `Resources/NTFSDriver/fuse-t-installer.pkg`（vendored 安装包）
- Create: `Resources/NTFSDriver/LICENSE-fuse-t.txt`

**Interfaces:**
- Produces：`docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md` 中记录的「确认挂载命令」「确认卸载命令」「确认安装完成标记路径」，供 Task 5、Task 6 直接引用。

- [ ] **Step 1: 在本机（非沙箱环境）安装 FUSE-T 与 ntfs-3g，创建测试用 NTFS 磁盘镜像**

```bash
brew install --cask fuse-t
brew install ntfs-3g
hdiutil create -size 200m -fs "MS-DOS FAT32" -volname NTFSTest /tmp/ntfstest.dmg
# 用 Windows 或 `mkntfs`（ntfs-3g 附带）把上面的镜像格式化成 NTFS 用于本地测试：
/usr/local/sbin/mkntfs -f /tmp/ntfstest.dmg
```

- [ ] **Step 2: 手动挂载并确认可写，记录确切命令**

```bash
hdiutil attach -nomount /tmp/ntfstest.dmg   # 记录输出的 /dev/diskN
mkdir -p /tmp/ntfsmount
/usr/local/bin/ntfs-3g /dev/diskN /tmp/ntfsmount -olocal -oallow_other -oauto_xattr
touch /tmp/ntfsmount/write-test.txt && echo "写入成功"
umount /tmp/ntfsmount
```

- [ ] **Step 3: 确认 FUSE-T 安装后的幂等性检测标记**

```bash
ls -la "/Library/Application Support/fuse-t/uninstall.sh"
```

确认该文件在安装后存在、卸载后消失，作为 `NTFSDriverInstaller` 判断"是否已安装"的依据。

- [ ] **Step 4: 把验证过的二进制与安装包拷贝进项目 Resources**

```bash
mkdir -p Resources/NTFSDriver
cp /usr/local/bin/ntfs-3g Resources/NTFSDriver/ntfs-3g
cp "$(brew --cellar ntfs-3g)"/*/COPYING Resources/NTFSDriver/LICENSE-ntfs-3g.txt
cp ~/Downloads/fuse-t-*.pkg Resources/NTFSDriver/fuse-t-installer.pkg   # 从 https://www.fuse-t.org 下载的安装包
cp /path/to/fuse-t/LICENSE Resources/NTFSDriver/LICENSE-fuse-t.txt
```

- [ ] **Step 5: 写调研文档**

创建 `docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md`，内容至少包含：

```markdown
# NTFS 驱动调研结论

- 安装完成标记：`/Library/Application Support/fuse-t/uninstall.sh` 存在即视为 FUSE-T 已安装。
- 挂载命令：`<bundled>/ntfs-3g <devicePath> <mountPoint> -olocal -oallow_other -oauto_xattr`
- 卸载命令：复用现有 `diskutil unmount <mountPoint>`（与 SMB/WebDAV 一致，无需 ntfs-3g 专属卸载命令）。
- 安装 FUSE-T 命令：`installer -pkg <bundled>/fuse-t-installer.pkg -target /`（需要管理员权限）。
```

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md Resources/NTFSDriver
git commit -m "docs: record FUSE-T/ntfs-3g driver findings and vendor binaries"
```

---

### Task 2: 扩展 `AppSettings` 增加 `autoMountNTFSReadWrite`（向后兼容）

推荐模型：sonnet 5。

**Files:**
- Modify: `Sources/AutoVolumeShared/AppSettings.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Produces：`AppSettings.autoMountNTFSReadWrite: Bool`（默认 `false`），供 Task 9（Settings UI）与 Task 8（Agent 编排）读取。

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

Run: `script/build_and_run.sh --no-launch`
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

Run: `script/build_and_run.sh --no-launch`
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

Run: `script/build_and_run.sh --no-launch`
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

Run: `script/build_and_run.sh --no-launch`
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
  供 Task 8（Agent 编排）写入、Task 9（App UI）读取。

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

Run: `script/build_and_run.sh --no-launch`
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

Run: `script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSMountedVolumesStore.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add NTFSMountedVolumesStore for tracking active NTFS read-write mounts"
```

---

### Task 5: `NTFSDriverInstaller`（幂等性检测 + 安装 CommandPlan）

推荐模型：sonnet 5。

**Files:**
- Create: `Sources/AutoVolumeShared/NTFSDriverInstaller.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Consumes：`CommandPlan`（已存在，`CommandRunner.swift`）
- Produces：
  ```swift
  public struct NTFSDriverInstaller {
      public init(fileManager: FileManager = .default, installMarkerPath: String = "/Library/Application Support/fuse-t/uninstall.sh")
      public func isInstalled() -> Bool
      public func installPlan(bundledInstallerPkgPath: String) -> CommandPlan
  }
  ```
  供 Task 8（Agent 编排）调用。`installMarkerPath` 与 `installPlan` 的 `installer -pkg ... -target /` 命令直接取自 Task 1 的调研文档 `docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md`。

- [ ] **Step 1: 写失败测试**

```swift
func testNTFSDriverInstallerDetectsInstalledMarker() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let markerPath = directory.appendingPathComponent("uninstall.sh").path
    try "".write(toFile: markerPath, atomically: true, encoding: .utf8)

    let installer = NTFSDriverInstaller(installMarkerPath: markerPath)

    try expect(installer.isInstalled() == true, "Installer should report installed when the marker file exists")
}

func testNTFSDriverInstallerDetectsMissingMarker() throws {
    let installer = NTFSDriverInstaller(installMarkerPath: "/tmp/\(UUID().uuidString)/does-not-exist.sh")

    try expect(installer.isInstalled() == false, "Installer should report not installed when the marker file is missing")
}

func testNTFSDriverInstallerBuildsAdminPrivilegedInstallPlan() throws {
    let installer = NTFSDriverInstaller()

    let plan = installer.installPlan(bundledInstallerPkgPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/fuse-t-installer.pkg")

    try expect(plan.executable == "/usr/bin/osascript", "Install plan should run through osascript for admin privileges")
    try expect(plan.arguments == ["-e", "do shell script \"installer -pkg '/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/fuse-t-installer.pkg' -target /\" with administrator privileges"], "Install plan arguments did not match expected admin-privileged installer command")
}
```

添加到 `tests` 数组：

```swift
    ("NTFSDriverInstaller detects installed marker", testNTFSDriverInstallerDetectsInstalledMarker),
    ("NTFSDriverInstaller detects missing marker", testNTFSDriverInstallerDetectsMissingMarker),
    ("NTFSDriverInstaller builds admin-privileged install plan", testNTFSDriverInstallerBuildsAdminPrivilegedInstallPlan),
```

- [ ] **Step 2: 运行确认失败**

Run: `script/build_and_run.sh --no-launch`
Expected: 编译失败（类型不存在）

- [ ] **Step 3: 实现**

```swift
import Foundation

public struct NTFSDriverInstaller {
    private let fileManager: FileManager
    private let installMarkerPath: String

    public init(fileManager: FileManager = .default, installMarkerPath: String = "/Library/Application Support/fuse-t/uninstall.sh") {
        self.fileManager = fileManager
        self.installMarkerPath = installMarkerPath
    }

    public func isInstalled() -> Bool {
        fileManager.fileExists(atPath: installMarkerPath)
    }

    public func installPlan(bundledInstallerPkgPath: String) -> CommandPlan {
        let escapedPath = bundledInstallerPkgPath.replacingOccurrences(of: "'", with: "'\\''")
        let shellCommand = "installer -pkg '\(escapedPath)' -target /"
        let escapedShellCommand = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return CommandPlan(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "do shell script \"\(escapedShellCommand)\" with administrator privileges"]
        )
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSDriverInstaller.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add NTFSDriverInstaller for one-time admin-privileged FUSE-T install"
```

---

### Task 6: `NTFSMountPlanner`（卸载只读挂载 + ntfs-3g 读写挂载的 CommandPlan）

推荐模型：sonnet 5。

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
  供 Task 8 使用。挂载命令直接取自 Task 1 调研文档记录的 `ntfs-3g <devicePath> <mountPoint> -olocal -oallow_other -oauto_xattr`；卸载复用现有 `diskutil unmount`（与 `MountPlanner.unmountPlan` 相同命令，不新增卸载逻辑）。

- [ ] **Step 1: 写失败测试**

```swift
func testNTFSMountPlannerUnmountUsesDiskutil() throws {
    let planner = NTFSMountPlanner(ntfs3gPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/ntfs-3g")

    let plan = planner.unmountReadOnlyPlan(mountPoint: "/Volumes/USB")

    try expect(plan.executable == "/usr/sbin/diskutil", "Unmount plan should use diskutil")
    try expect(plan.arguments == ["unmount", "/Volumes/USB"], "Unmount plan arguments did not match")
}

func testNTFSMountPlannerMountUsesBundledNtfs3g() throws {
    let planner = NTFSMountPlanner(ntfs3gPath: "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/ntfs-3g")

    let plan = planner.mountReadWritePlan(devicePath: "/dev/disk4s1", mountPoint: "/Volumes/USB")

    try expect(plan.executable == "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/ntfs-3g", "Mount plan should invoke the bundled ntfs-3g binary")
    try expect(plan.arguments == ["/dev/disk4s1", "/Volumes/USB", "-olocal", "-oallow_other", "-oauto_xattr"], "Mount plan arguments did not match the researched invocation")
}
```

添加到 `tests` 数组：

```swift
    ("NTFSMountPlanner unmount uses diskutil", testNTFSMountPlannerUnmountUsesDiskutil),
    ("NTFSMountPlanner mount uses bundled ntfs-3g", testNTFSMountPlannerMountUsesBundledNtfs3g),
```

- [ ] **Step 2: 运行确认失败**

Run: `script/build_and_run.sh --no-launch`
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

Run: `script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSMountPlanner.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add NTFSMountPlanner for ntfs-3g read-write remount commands"
```

---

### Task 7: `NTFSRemountDebouncer`（防止我们自己触发的挂载事件被重复处理）

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
  供 Task 8 使用：ntfs-3g 挂载成功后，DiskArbitration 会再次为新挂载点触发一次 appeared 回调，必须能识别"这是我们自己刚处理过的设备"从而跳过，避免死循环。

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

Run: `script/build_and_run.sh --no-launch`
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

Run: `script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSRemountDebouncer.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: add NTFSRemountDebouncer to prevent remount event loops"
```

---

### Task 8: `NTFSAutoMountService`（DiskArbitration 编排）+ 接入 `AutoVolumeAgent`

推荐模型：sonnet 5（编排逻辑用到 DiskArbitration C API，实现时如遇 API 细节问题可切换 opus 5.2 排查）。

**Files:**
- Create: `Sources/AutoVolumeShared/NTFSAutoMountService.swift`
- Modify: `Sources/AutoVolumeAgent/main.swift`
- Test: `ManualTests/AutoVolumeManualTests.swift`

**Interfaces:**
- Consumes：`NTFSDiskClassifier`（Task 3）、`NTFSMountedVolumesStore`（Task 4）、`NTFSDriverInstaller`（Task 5）、`NTFSMountPlanner`（Task 6）、`NTFSRemountDebouncer`（Task 7）、`CommandRunner`（既有）、`AlertStore`（既有，用于一次性提醒）。
- Produces：
  ```swift
  public final class NTFSAutoMountService {
      public init(
          settingsStore: AppSettingsStore = JSONAppSettingsStore(),
          driverInstaller: NTFSDriverInstaller = NTFSDriverInstaller(),
          mountPlanner: NTFSMountPlanner,
          mountedVolumesStore: NTFSMountedVolumesStore = NTFSMountedVolumesStore(),
          commandRunner: CommandRunner = ProcessCommandRunner(),
          alertStore: AlertStore = AlertStore(),
          debouncer: NTFSRemountDebouncer = NTFSRemountDebouncer()
      )
      public static let onboardingAlertID: UUID
      public func handleDiskEligibleForReadWrite(bsdName: String, devicePath: String, volumeName: String, mountPoint: String, filesystemPersonality: String?, mountedFileSystemName: String?)
      public func handleDiskDisappeared(bsdName: String)
  }
  ```
  `handleDiskEligibleForReadWrite`/`handleDiskDisappeared` 是从 DiskArbitration 回调中提取好字段后调用的纯编排入口，方便测试时绕过真实 DiskArbitration 会话直接调用。

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
    let alertStore = AlertStore(directory: alertsDirectory)
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(installMarkerPath: "/tmp/\(UUID().uuidString)/missing"),
        mountPlanner: NTFSMountPlanner(ntfs3gPath: "/tmp/unused-ntfs-3g"),
        mountedVolumesStore: NTFSMountedVolumesStore(directory: volumesDirectory),
        commandRunner: commandRunner,
        alertStore: alertStore
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")

    try expect(commandRunner.plans.isEmpty, "No mount commands should run while the setting is disabled")
    let alerts = try alertStore.load()
    try expect(alerts.contains { $0.volumeID == NTFSAutoMountService.onboardingAlertID }, "A one-time onboarding alert should be recorded when an NTFS drive is seen with the setting disabled")
}

func testNTFSAutoMountServiceSkipsWhenAlreadyOwnedByOurDriver() throws {
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: settingsDirectory) }
    let settingsStore = JSONAppSettingsStore(directory: settingsDirectory)
    try settingsStore.save(AppSettings(autoMountNTFSReadWrite: true))
    let commandRunner = RecordingCommandRunner()
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(installMarkerPath: "/tmp/\(UUID().uuidString)/missing"),
        mountPlanner: NTFSMountPlanner(ntfs3gPath: "/tmp/unused-ntfs-3g"),
        mountedVolumesStore: NTFSMountedVolumesStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        commandRunner: commandRunner,
        alertStore: AlertStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "fusefs_ntfs")

    try expect(commandRunner.plans.isEmpty, "Disks already mounted by our own driver should not be reprocessed")
}

func testNTFSAutoMountServiceInstallsDriverThenRemountsReadWrite() throws {
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
    let volumesStore = NTFSMountedVolumesStore(directory: volumesDirectory)
    let service = NTFSAutoMountService(
        settingsStore: settingsStore,
        driverInstaller: NTFSDriverInstaller(installMarkerPath: markerPath),
        mountPlanner: NTFSMountPlanner(ntfs3gPath: "/tmp/unused-ntfs-3g"),
        mountedVolumesStore: volumesStore,
        commandRunner: commandRunner,
        alertStore: AlertStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    )

    service.handleDiskEligibleForReadWrite(bsdName: "disk4s1", devicePath: "/dev/disk4s1", volumeName: "USB", mountPoint: "/Volumes/USB", filesystemPersonality: "Windows_NTFS", mountedFileSystemName: "ntfs")

    try expect(commandRunner.plans.count == 3, "Expected install, unmount, then mount commands; got \(commandRunner.plans.count)")
    try expect(commandRunner.plans[0].executable == "/usr/bin/osascript", "First command should be the driver install")
    try expect(commandRunner.plans[1].executable == "/usr/sbin/diskutil", "Second command should unmount the read-only mount")
    try expect(commandRunner.plans[2].executable == "/tmp/unused-ntfs-3g", "Third command should mount read-write via ntfs-3g")
    let volumes = try volumesStore.load()
    try expect(volumes.contains { $0.bsdName == "disk4s1" }, "The remounted volume should be recorded in NTFSMountedVolumesStore")
}
```

添加到 `tests` 数组：

```swift
    ("NTFSAutoMountService onboarding alert when disabled", testNTFSAutoMountServiceRecordsOnboardingAlertWhenSettingDisabled),
    ("NTFSAutoMountService skips already-owned mounts", testNTFSAutoMountServiceSkipsWhenAlreadyOwnedByOurDriver),
    ("NTFSAutoMountService installs driver then remounts", testNTFSAutoMountServiceInstallsDriverThenRemountsReadWrite),
```

（`RecordingCommandRunner` 已存在于 `ManualTests/AutoVolumeManualTests.swift` 文件底部，复用即可，无需新建。）

- [ ] **Step 2: 运行确认失败**

Run: `script/build_and_run.sh --no-launch`
Expected: 编译失败（`NTFSAutoMountService` 不存在）

- [ ] **Step 3: 实现 `NTFSAutoMountService`**

```swift
import Foundation

public final class NTFSAutoMountService {
    public static let onboardingAlertID = UUID(uuidString: "00000000-0000-0000-0000-00000000AF01")!

    private let settingsStore: AppSettingsStore
    private let driverInstaller: NTFSDriverInstaller
    private let mountPlanner: NTFSMountPlanner
    private let mountedVolumesStore: NTFSMountedVolumesStore
    private let commandRunner: CommandRunner
    private let alertStore: AlertStore
    private let debouncer: NTFSRemountDebouncer

    public init(
        settingsStore: AppSettingsStore = JSONAppSettingsStore(),
        driverInstaller: NTFSDriverInstaller = NTFSDriverInstaller(),
        mountPlanner: NTFSMountPlanner,
        mountedVolumesStore: NTFSMountedVolumesStore = NTFSMountedVolumesStore(),
        commandRunner: CommandRunner = ProcessCommandRunner(),
        alertStore: AlertStore = AlertStore(),
        debouncer: NTFSRemountDebouncer = NTFSRemountDebouncer()
    ) {
        self.settingsStore = settingsStore
        self.driverInstaller = driverInstaller
        self.mountPlanner = mountPlanner
        self.mountedVolumesStore = mountedVolumesStore
        self.commandRunner = commandRunner
        self.alertStore = alertStore
        self.debouncer = debouncer
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

        if !driverInstaller.isInstalled() {
            let bundledInstallerPath = Bundle.main.path(forResource: "fuse-t-installer", ofType: "pkg", inDirectory: "NTFSDriver")
                ?? "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/fuse-t-installer.pkg"
            _ = try? commandRunner.run(driverInstaller.installPlan(bundledInstallerPkgPath: bundledInstallerPath))
        }

        _ = try? commandRunner.run(mountPlanner.unmountReadOnlyPlan(mountPoint: mountPoint))
        let mountResult = try? commandRunner.run(mountPlanner.mountReadWritePlan(devicePath: devicePath, mountPoint: mountPoint))
        guard mountResult?.exitCode == 0 else { return }

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

Run: `script/build_and_run.sh --no-launch`
Expected: 全部 `PASS`

- [ ] **Step 5: 接入 `AutoVolumeAgent/main.swift`——注册 DiskArbitration 回调**

在 `Sources/AutoVolumeAgent/main.swift` 顶部 `import Darwin` 之后添加 `import DiskArbitration`，在文件中 `let alertStore = AlertStore()`（第 21 行）之后添加：

```swift
let ntfsBundledBinaryPath = Bundle.main.path(forResource: "ntfs-3g", ofType: nil, inDirectory: "NTFSDriver")
    ?? "/Applications/AutoVolume.app/Contents/Resources/NTFSDriver/ntfs-3g"
let ntfsAutoMountService = NTFSAutoMountService(mountPlanner: NTFSMountPlanner(ntfs3gPath: ntfsBundledBinaryPath))

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

> 注：`DADiskCopyDescription` 返回的具体 key 名称（`kDADiskDescriptionVolumeKindKey` 是否等价于「文件系统类型」还是需要改用 `kDADiskDescriptionMediaKindKey`）在真实设备上可能与文档不完全一致——这是实现该步骤时唯一允许通过手动插拔真实/虚拟 NTFS 盘临时验证并调整的地方（用 `print(description)` 打印完整字典核对 key），不影响本任务其余部分（Step 1-4）已经落地的可测试逻辑。

- [ ] **Step 6: 构建确认整体编译通过（含 DiskArbitration 框架链接，见 Task 10）**

Run: `script/build_and_run.sh --no-launch`
Expected: 编译成功、全部 manual tests `PASS`（Task 10 会补上 `-framework DiskArbitration` 链接参数，如果此步先报链接错误属预期，留到 Task 10 解决）

- [ ] **Step 7: Commit**

```bash
git add Sources/AutoVolumeShared/NTFSAutoMountService.swift Sources/AutoVolumeAgent/main.swift ManualTests/AutoVolumeManualTests.swift
git commit -m "feat: wire NTFSAutoMountService into AutoVolumeAgent via DiskArbitration"
```

---

### Task 9: Settings 开关 + 一次性提醒展示

推荐模型：sonnet 5。

**Files:**
- Modify: `Sources/AutoVolumeApp/SettingsView.swift`

**Interfaces:**
- Consumes：`AppSettings.autoMountNTFSReadWrite`（Task 2）、`AppViewModel.updateSettings`/`AppViewModel.alerts`（既有，onboarding 提醒已经通过 Task 8 写入的 `AlertStore` 自动出现在既有的提醒铃铛菜单里，无需改动 `ContentView.swift`）。

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

Run: `script/build_and_run.sh --no-launch`
Expected: 编译通过

- [ ] **Step 3: Commit**

```bash
git add Sources/AutoVolumeApp/SettingsView.swift
git commit -m "feat: add NTFS read-write toggle to Settings"
```

---

### Task 10: 构建脚本接入（新文件、DiskArbitration 链接、驱动资源打包）+ 版本发布

推荐模型：sonnet 5。

**Files:**
- Modify: `script/build_and_run.sh`
- Modify: `Resources/Info.plist`

**Interfaces:**
- 无新增代码接口；这是把前面所有任务新增的文件正式接入项目"唯一真实"的构建/测试/打包流程。

- [ ] **Step 1: 在 `script/build_and_run.sh` 的 `AutoVolumeShared` swiftc 文件列表中追加新文件，并链接 DiskArbitration 框架**

在 `Sources/AutoVolumeShared/AlertStore.swift`（该 swiftc 调用的最后一行输入文件）之后追加：

```
  Sources/AutoVolumeShared/AlertStore.swift \
  Sources/AutoVolumeShared/NTFSVolume.swift \
  Sources/AutoVolumeShared/NTFSMountedVolumesStore.swift \
  Sources/AutoVolumeShared/NTFSDriverInstaller.swift \
  Sources/AutoVolumeShared/NTFSMountPlanner.swift \
  Sources/AutoVolumeShared/NTFSRemountDebouncer.swift \
  Sources/AutoVolumeShared/NTFSAutoMountService.swift \
  -framework DiskArbitration
```

（即把最后一行 `Sources/AutoVolumeShared/AlertStore.swift` 改成上面这段，用新文件列表 + `-framework DiskArbitration` 替换原来单独一行的收尾。）

同时在编译 `AutoVolumeAgent` 的 `swiftc` 调用里也追加 `-framework DiskArbitration`（因为 Task 8 在 `Sources/AutoVolumeAgent/main.swift` 里直接 `import DiskArbitration` 并调用了它的 C API）：

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

- [ ] **Step 2: 在打包 App bundle 的阶段拷贝并签名驱动资源**

在脚本中 `cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"` 之后、`codesign` 之前添加：

```bash
mkdir -p "$APP/Contents/Resources/NTFSDriver"
cp "$ROOT/Resources/NTFSDriver/ntfs-3g" "$APP/Contents/Resources/NTFSDriver/ntfs-3g"
cp "$ROOT/Resources/NTFSDriver/fuse-t-installer.pkg" "$APP/Contents/Resources/NTFSDriver/fuse-t-installer.pkg"
cp "$ROOT/Resources/NTFSDriver/LICENSE-ntfs-3g.txt" "$APP/Contents/Resources/NTFSDriver/LICENSE-ntfs-3g.txt"
cp "$ROOT/Resources/NTFSDriver/LICENSE-fuse-t.txt" "$APP/Contents/Resources/NTFSDriver/LICENSE-fuse-t.txt"
chmod +x "$APP/Contents/Resources/NTFSDriver/ntfs-3g"
```

并在既有的 `codesign --force --sign - "$APP/Contents/Resources/AutoVolumeAgent"` 之后添加：

```bash
codesign --force --sign - "$APP/Contents/Resources/NTFSDriver/ntfs-3g"
```

- [ ] **Step 3: 按 `CLAUDE.md` 流程升版本号**

编辑 `Resources/Info.plist`：将 `CFBundleShortVersionString` 从当前值（如 `0.1.47`）递增 patch 号，`CFBundleVersion` 同步改为对应的纯数字。

- [ ] **Step 4: 完整构建并运行全部 manual tests**

Run: `script/build_and_run.sh --no-launch`
Expected: 编译成功（`ntfs-3g`、`DiskArbitration` 链接均通过），全部既有 + 新增 manual tests `PASS`，无遗留失败。

- [ ] **Step 5: 打包 DMG**

Run: `script/package_dmg.sh <新版本号>`
Expected: `dist/AutoVolume-<新版本号>-local.dmg` 生成成功。

- [ ] **Step 6: Commit**

```bash
git add script/build_and_run.sh Resources/Info.plist
git commit -m "release: bundle NTFS driver and prepare AutoVolume <新版本号>"
```

- [ ] **Step 7: 交给用户自测**

告知用户新 DMG 路径，请其用真实 NTFS 外接硬盘验证：① 设置关闭时看到一次性提醒但保持只读；② 设置开启后首次插入弹出管理员密码授权、随后自动切换为可读写；③ 拔出后再插入不再重复请求密码、能立即读写；④ 关闭设置开关后新插入的 NTFS 盘恢复只读。不由 Claude 自行判定完成。

---

## Self-Review 记录

- **Spec 覆盖**：驱动选型（Task 1/6）、实时监控（DiskArbitration，Task 8）、无需 SIP/无需内核扩展（Task 1 选型 + Task 5 安装方式）、内置无需多次配置（Task 5/10 打包 + 一次性管理员授权）、默认关闭 + 一次性提醒（Task 2/8/9）、UI 展示（Task 9，复用既有提醒铃铛）、错误处理（Task 8 的 guard/回退到只读）、测试策略（每个 Task 都在 `ManualTests` 中补充用例）均已覆盖。
- **占位符扫描**：已移除所有 TBD；两个原 spec "开放问题"通过 Task 1（Spike）转化为具体、已验证的调研结论，后续任务直接引用该结论而非留白。
- **类型一致性**：`NTFSVolume`、`NTFSDiskClassifier`、`NTFSMountedVolumesStore`、`NTFSDriverInstaller`、`NTFSMountPlanner`、`NTFSRemountDebouncer`、`NTFSAutoMountService` 的方法签名在各任务间保持一致，已交叉核对。
