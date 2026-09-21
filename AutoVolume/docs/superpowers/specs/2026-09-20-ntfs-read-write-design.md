# NTFS 实时读写支持 — 设计文档

日期：2026-09-20（2026-09-21 更新：实施调研发现权限模型问题，见「权限模型」章节）
状态：已批准设计，实施中

## 目标

AutoVolume 目前只处理网络卷（SMB/WebDAV/AFP/NFS）的自动挂载。本次新增：

- 支持本地/USB 外接 **NTFS** 格式硬盘的**读写**挂载（macOS 原生只读，此前的可写方案依赖禁用 SIP，本方案不需要）。
- **实时监控**：无需用户预先在 AutoVolume 中添加配置，任意插入的 NTFS 外接盘会被自动检测并以读写方式重新挂载（体验类似 Mounty，但内置无需额外操作）。
- 驱动组件（FUSE-T + NTFS-3G）**内置在 App 内**，用户无需多次手动安装/配置。

不在本次范围内：远程 Windows 主机上通过 SMB/NFS 访问的 NTFS 分区（协议层已对客户端透明，无需特殊处理）。

## 技术选型

**FUSE-T + NTFS-3G**（已与用户确认）：

- FUSE-T：通过本地回环 NFS 服务实现用户态 FUSE，无需内核扩展、无需用户在“系统设置 → 隐私与安全性”中手动批准扩展、无需重启、无需禁用 SIP。适配 Apple Silicon。
- NTFS-3G：实际执行 NTFS 读写的用户态驱动，GPLv2 授权。以独立子进程（`Process`/`CommandPlan`）方式调用，不做静态链接，符合现有代码库的 `CommandRunner` 模式，不触发 GPL 对宿主 App 的 copyleft 要求；随包附带其 License 文本。必须使用专门为 FUSE-T 构建的 `macos-fuse-t/ntfs-3g` 分支（从源码构建，`--with-fuse=external` 链接 FUSE-T），而非通用 Homebrew `ntfs-3g-mac`（后者链接 macFUSE，需要用户手动批准 System Extension，违反本设计前提）。

**许可证注意事项**：FUSE-T 的二进制分发许可证是"非商业用途免费；商业用途（含捆绑进商业软件分发）需要向 FUSE-T 作者购买商业许可证"。已与用户确认 AutoVolume 目前及可预见的将来均为个人/内部使用，不对外销售或收费，按非商业条款可以直接内置。**如果 AutoVolume 未来转为商业性质分发，需要重新评估此条款。**

放弃的备选方案：
- macFUSE + NTFS-3G：更成熟但需要用户手动批准 System Extension、可能需要重启，不符合“内置无需多次配置”的要求。
- ntfsmac（一次性 Linux microVM）：无内核扩展，但资源开销大、项目成熟度低（个人维护的小项目），不适合正式产品化。

## 权限模型（2026-09-21 实施调研新增，重要）

**原设计假设**：无权限的用户级 `AutoVolumeAgent` 可以像调用 `mount_smbfs`/`mount_nfs` 那样直接 `Process` 调用内置的 `ntfs-3g` 完成挂载。

**实测证伪**：在本机用 `hdiutil` + `mkntfs` 制作的测试 NTFS 卷上实测，`ntfs-3g` 打开原始块设备（`/dev/diskN`）**始终需要 root 权限**，这是 macOS 系统级限制，与 FUSE-T/macFUSE 无关。尝试给二进制加 setuid-root 位绕过，被 ntfs-3g 自身的安全检查拒绝（链接外部 FUSE 库时明确拒绝以 setuid 方式运行）。交叉参考 [nohajc/anylinuxfs](https://github.com/nohajc/anylinuxfs)（用 Linux 微虚拟机 + 真实内核驱动挂载任意 Linux 文件系统的类似项目）的官方文档，同样明确要求 `sudo` 才能直接访问 `/dev/disk*`，证实这是 macOS 的普遍限制，任何用户态方案都绕不开。详见 `docs/superpowers/plans/2026-09-20-ntfs-driver-findings.md`。

**修正设计**：新增一个常驻的特权 **LaunchDaemon**（`NTFSPrivilegedHelper`），只负责"挂载/卸载指定块设备到指定路径"这一件事（攻击面最小化，不做其他任何操作）。安装时机与 FUSE-T pkg 安装合并为同一次管理员密码授权（不增加用户操作次数）。无权限的 `AutoVolumeAgent` 通过本地 Unix domain socket 向该 LaunchDaemon 发送挂载/卸载请求，由其以 root 身份代为执行 `ntfs-3g` 命令。这是 macOS 处理"偶尔需要特权操作"的标准做法（等价于经典 SMJobBless 特权助理模式）。

## 架构

新增 `NTFSAutoMountService`，运行在现有的 `AutoVolumeAgent` launchd 常驻进程内，与现有针对已配置网络卷的轮询循环（`runOnce()` / `CheckScheduler`）并行，互不干扰：

1. 使用 `DiskArbitration`（`DARegisterDiskAppearedCallback`）监听磁盘插入事件，事件驱动、非轮询，满足“实时监控”要求。
2. 对新出现的磁盘做文件系统类型判断，命中 `ntfs`（如 `msdos`/其他变体不处理）时继续。
3. 若用户未开启 NTFS 读写开关或驱动尚未安装，保留 macOS 原生只读挂载，仅在需要时提示一次性引导，不重复打扰。
4. 若已开启且驱动已就绪：通过本地 IPC 向 `NTFSPrivilegedHelper`（root LaunchDaemon）请求卸载系统的只读挂载、改用内置 `ntfs-3g` 挂载为读写（`AutoVolumeAgent` 自身不再直接调用 `ntfs-3g`，见「权限模型」）。
5. 通过 `DARegisterDiskDisappearedCallback` 监听拔出事件，做相应清理。

## 新增组件

| 文件 | 职责 |
|---|---|
| `Sources/AutoVolumeShared/NTFSDriverInstaller.swift` | 检测 FUSE-T 是否已安装（`/Library/Application Support/fuse-t/uninstall.sh` 是否存在）及 `NTFSPrivilegedHelper` LaunchDaemon 是否已安装/注册；未安装时通过 `osascript "do shell script ... with administrator privileges"` 一次性完成 FUSE-T pkg 安装 + LaunchDaemon 安装/加载（仅首次需要管理员密码，此后不再需要）。 |
| `Sources/AutoVolumeShared/NTFSDiskWatcher.swift` | 封装 `DiskArbitration` 回调，过滤 `ntfs` 文件系统，对同一设备的重复出现事件做防抖。 |
| `Sources/AutoVolumeShared/NTFSMountPlanner.swift` | 参照现有 `MountPlanner` 的模式，构造**发送给 `NTFSPrivilegedHelper` 的挂载/卸载请求**（不再是直接调用 `ntfs-3g` 的 `CommandPlan`，见「权限模型」）。 |
| `Sources/AutoVolumeNTFSHelper/main.swift`（新可执行目标，`NTFSPrivilegedHelper`） | root LaunchDaemon，监听本地 Unix domain socket，收到挂载/卸载请求后代为执行内置 `ntfs-3g`/`diskutil unmount`，仅此一项职责。 |
| `Resources/NTFSDriver/ntfs-3g` + `libntfs-3g.89.dylib`（内置二进制，已构建） | 实际读写驱动，GPLv2，随包附带 License 文本。已用 `install_name_tool` 调整为相对自身目录，依赖 FUSE-T 安装后的 `/usr/local/lib/libfuse-t.dylib`。 |
| `Resources/NTFSDriver/fuse-t-installer.pkg`（内置，已获取） | FUSE-T 官方安装包，提供无内核扩展的用户态 FUSE 支持。二进制分发许可：非商业用途免费（见上「许可证注意事项」）。 |

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

- ~~FUSE-T 的具体安装包大小、是否需要针对 Apple Silicon/Intel 提供不同二进制~~ 已解决：本项目仅面向 Apple Silicon（现有 `CLAUDE.md`/构建脚本均为 `arm64-apple-macosx`），已内置 arm64 版 FUSE-T pkg（24MB）与 arm64 版 `ntfs-3g`（已本机构建验证）。
- 是否需要在 `DADiskClaim` 阶段抢先接管（避免系统先只读挂载一次再卸载重挂）还是等系统只读挂载完成后再切换，留待计划阶段做技术验证（spike）。
- `NTFSPrivilegedHelper` LaunchDaemon 与 `AutoVolumeAgent` 之间的本地 IPC 协议细节（socket 路径、请求/响应格式、鉴权方式防止其他进程冒充发起挂载请求）留待实施计划阶段具体设计。
