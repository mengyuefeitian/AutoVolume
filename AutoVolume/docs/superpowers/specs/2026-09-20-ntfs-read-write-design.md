# NTFS 实时读写支持 — 设计文档

日期：2026-09-20
状态：已批准设计，待生成实施计划

## 目标

AutoVolume 目前只处理网络卷（SMB/WebDAV/AFP/NFS）的自动挂载。本次新增：

- 支持本地/USB 外接 **NTFS** 格式硬盘的**读写**挂载（macOS 原生只读，此前的可写方案依赖禁用 SIP，本方案不需要）。
- **实时监控**：无需用户预先在 AutoVolume 中添加配置，任意插入的 NTFS 外接盘会被自动检测并以读写方式重新挂载（体验类似 Mounty，但内置无需额外操作）。
- 驱动组件（FUSE-T + NTFS-3G）**内置在 App 内**，用户无需多次手动安装/配置。

不在本次范围内：远程 Windows 主机上通过 SMB/NFS 访问的 NTFS 分区（协议层已对客户端透明，无需特殊处理）。

## 技术选型

**FUSE-T + NTFS-3G**（已与用户确认）：

- FUSE-T：通过本地回环 NFS 服务实现用户态 FUSE，无需内核扩展、无需用户在“系统设置 → 隐私与安全性”中手动批准扩展、无需重启、无需禁用 SIP。适配 Apple Silicon。
- NTFS-3G：实际执行 NTFS 读写的用户态驱动，GPLv2 授权。以独立子进程（`Process`/`CommandPlan`）方式调用，不做静态链接，符合现有代码库的 `CommandRunner` 模式，不触发 GPL 对宿主 App 的 copyleft 要求；随包附带其 License 文本。

放弃的备选方案：
- macFUSE + NTFS-3G：更成熟但需要用户手动批准 System Extension、可能需要重启，不符合“内置无需多次配置”的要求。
- ntfsmac（一次性 Linux microVM）：无内核扩展，但资源开销大、项目成熟度低（个人维护的小项目），不适合正式产品化。

## 架构

新增 `NTFSAutoMountService`，运行在现有的 `AutoVolumeAgent` launchd 常驻进程内，与现有针对已配置网络卷的轮询循环（`runOnce()` / `CheckScheduler`）并行，互不干扰：

1. 使用 `DiskArbitration`（`DARegisterDiskAppearedCallback`）监听磁盘插入事件，事件驱动、非轮询，满足“实时监控”要求。
2. 对新出现的磁盘做文件系统类型判断，命中 `ntfs`（如 `msdos`/其他变体不处理）时继续。
3. 若用户未开启 NTFS 读写开关或驱动尚未安装，保留 macOS 原生只读挂载，仅在需要时提示一次性引导，不重复打扰。
4. 若已开启且驱动已就绪：卸载系统的只读挂载，改用内置 `ntfs-3g` 挂载为读写。
5. 通过 `DARegisterDiskDisappearedCallback` 监听拔出事件，做相应清理。

## 新增组件

| 文件 | 职责 |
|---|---|
| `Sources/AutoVolumeShared/NTFSDriverInstaller.swift` | 检测 FUSE-T 回环 NFS LaunchDaemon 是否已安装；未安装时通过 `osascript "do shell script ... with administrator privileges"` 一次性静默安装内置的 FUSE-T 安装包（仅首次需要管理员密码，此后不再需要）。 |
| `Sources/AutoVolumeShared/NTFSDiskWatcher.swift` | 封装 `DiskArbitration` 回调，过滤 `ntfs` 文件系统，对同一设备的重复出现事件做防抖。 |
| `Sources/AutoVolumeShared/NTFSMountPlanner.swift` | 参照现有 `MountPlanner` 的模式，构造调用内置 `ntfs-3g` 二进制的 `CommandPlan`。 |
| `Resources/ntfs-3g`（内置二进制） | 实际读写驱动，GPLv2，随包附带 License 文本。 |
| FUSE-T 回环组件（内置） | 提供无内核扩展的用户态 FUSE 支持，BSD/MIT 类授权。 |

## 设置项

`AppSettings` 新增 `autoMountNTFSReadWrite: Bool`，**默认关闭**：接管任意插入硬盘的读写行为是对 macOS 默认行为的重大改变，应作为用户主动开启的选项，首次检测到 NTFS 盘时弹出一次性引导（说明 + 开启入口），拒绝后不再重复打扰，用户也可随时在设置中开启/关闭。

## 数据流

插入磁盘 → DiskArbitration 回调（Agent 进程）→ 文件系统类型判断 → （若开关已开且驱动已装）卸载只读挂载 → `ntfs-3g` 挂载为读写 → 更新 `MountExposure`/`AlertStore` → App UI（`AppViewModel`/`ContentView`）在卷列表中展示，标记为“NTFS（读写）”，与用户手动添加的网络卷区分显示（因为它并非通过手动添加配置产生）。

## 错误处理

- 驱动未安装：首次遇到 NTFS 盘或用户在设置中开启开关时提示安装一次；用户拒绝则保留系统原生只读挂载，仅记录一次性提示，不重复弹窗。
- `ntfs-3g` 挂载失败（如 NTFS 日志脏/文件系统损坏）：回退到系统原生只读挂载，通过现有 `AlertStore` 记录告警。
- 拔出/移除：`DADiskDisappearedCallback` 触发清理，与现有卸载路径一致。

## 测试策略

遵循本项目 TDD 约定：

- `NTFSMountPlanner` 的命令构造是纯函数，比照现有 `MountPlanner` 单元测试。
- `NTFSDiskWatcher` 的文件系统类型过滤/防抖逻辑，用构造的假 DiskArbitration 事件单元测试。
- `NTFSDriverInstaller` 的幂等性检测（是否已安装）做集成测试。
- 真实硬盘插拔的挂载/卸载行为需要物理介质，按本项目 `CLAUDE.md` 现有发布流程，打包 DMG 后交由用户手动自测验证，不在自动化测试范围内。

## 开放问题

- FUSE-T 的具体安装包大小、是否需要针对 Apple Silicon/Intel 提供不同二进制，留待计划阶段调研确认。
- 是否需要在 `DADiskClaim` 阶段抢先接管（避免系统先只读挂载一次再卸载重挂）还是等系统只读挂载完成后再切换，留待计划阶段做技术验证（spike）。
