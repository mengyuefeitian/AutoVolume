# 网络卷实时监控 — 设计文档

日期：2026-09-27
状态：设计中，待用户审阅

## 目标

AutoVolume 目前对网络卷（SMB/WebDAV/AFP/NFS）的健康检测是纯定时轮询：`AutoVolumeAgent` 每 60 秒醒一次，对每个卷检查 `CheckScheduler.isDue`（默认间隔 `checkIntervalSeconds` = 300 秒才真正探测一次；一旦判定为网络失败，会强制把重试间隔缩短到 60 秒直到恢复）。这意味着：

- 网络刚恢复到卷重新挂载，最坏延迟 60 秒（已失败状态下）或最坏 300 秒（还没被判定为失败、只是还没到检查点）。
- 一个已挂载的网络卷变得不可达（服务器重启/掉线），最坏要等到下一次检查点（同样最多 300 秒）才会被发现。

本次改造的目标：参照 NTFS 本地磁盘那样的"事件驱动、非轮询"实时监控模式，把网络卷的"断开检测"和"恢复挂载"都做到接近实时，覆盖以下两类场景（均由用户确认为目标场景）：

1. **笔记本本身网络状态变化**：WiFi 断线重连、切换网络、插拔网线、VPN 连接/断开、从睡眠唤醒——这类"本机网络状态变化"系统有现成事件通知，可以做到几乎瞬时感知。
2. **已挂载的网络卷，其服务器本身断线/重启**：笔记本本身网络全程没有变化，但 NAS/服务器重启或临时掉线几秒后又恢复——这类场景没有"本机网络变化"事件可用，需要针对每台已配置服务器的可达性单独做事件驱动监控。

不在本次范围内：改变挂载/重连的底层逻辑本身（`AgentEngine.check`/`reconnect`、`MountPlanner`、`ConnectivityTester` 均不改动，只改变"什么时候调用它们"）；改变 NTFS 本地磁盘的现有实时监控（`NTFSAutoMountService`）。

## 现状分析

- `AutoVolumeAgent/main.swift` 的 `runOnce()` 由 `Timer(timeInterval: 60, repeats: true)` 驱动，每次遍历所有 `configs where config.isEnabled`，用 `CheckScheduler.isDue` 判断是否到了该卷的检查点。
- 判定网络不可达时（`serverReachability(config)` 返回 `isReachable == false`），把该卷记入 `networkFailedVolumeIDs`，并把下次检查点强制设为 60 秒后（而不是原本的 `checkIntervalSeconds`，通常 300 秒），这是目前唯一的"加速重试"机制，但仍然是轮询，最坏延迟 60 秒。
- NTFS 本地磁盘走完全不同的路径：`DASessionCreate` + `DARegisterDiskAppearedCallback`/`DisappearedCallback`，是操作系统对"物理设备插入/拔出"的原生事件通知，不轮询。这个模式对网络卷不能直接套用，因为网络卷不是"物理设备插拔"，而是"远程主机是否可达"——macOS 没有对应的"某台远程主机可达性变化"的 DiskArbitration 事件。

## 架构：三路事件触发 + 保留慢速轮询兜底

新增三个事件来源，全部只负责"什么时候该检查/重连"，检查/重连本身仍然调用现有的 `AgentEngine.check` / `AgentEngine.reconnect`（不改动挂载逻辑）：

```
                    ┌─────────────────────────┐
                    │   NetworkPathWatcher     │  NWPathMonitor：
                    │   (本机网络路径变化)      │  WiFi重连/插拔网线/VPN/唤醒
                    └───────────┬─────────────┘
                                │
┌───────────────────┐          │          ┌──────────────────────────┐
│ServerReachability  │          │          │  MountedVolumeWatcher     │
│Watcher (按主机名去重)│──────────┼──────────│  (NSWorkspace 卸载通知)   │
│SCNetworkReachability│          │          │  系统主动卸载某个网络卷时  │
└───────────┬────────┘          │          └────────────┬─────────────┘
            │                   ▼                        │
            └──────────>  checkVolumesNow(reason:) <──────┘
                                │
                                ▼
                    AgentEngine.check / .reconnect
                    （现有逻辑，不改动）
                                ▲
                                │ 每 60 秒兜底
                    Timer(timeInterval: 60) → runOnce()
```

三路事件的职责划分：

1. **`NetworkPathWatcher`**（`NWPathMonitor` 封装）：只关心"本机网络路径变了"，不判断具体哪台服务器可达——任何路径更新都触发一次 `checkVolumesNow`。覆盖场景 1。
2. **`ServerReachabilityWatcher`**（`SCNetworkReachability` 封装，按 `ConnectivityTester.hostOnly` 抽出的主机名去重后逐个注册回调）：某台服务器主机的可达性发生变化（不可达→可达，或反之）时触发 `checkVolumesNow`。覆盖场景 2——这是本次改造能覆盖"NAS 本身重启"场景的关键，因为这种情况下本机网络路径完全没变化，`NWPathMonitor` 不会触发。
3. **`MountedVolumeWatcher`**（`NSWorkspace.didUnmountNotification`）：系统主动把一个网络卷强制卸载时（SMB 长时间无响应后系统有时会这样做）立即感知，不等下一次检查点。

**诚实说明一个真实存在的盲区**：SCNetworkReachability 反映的是"到这台主机的网络路由是否存在"，不是"这台主机上的 SMB/WebDAV 服务是否存活"。如果服务器主机本身没有重启、网络路由也没变化，只是共享服务进程本身卡死/崩溃，三路事件都不会触发——这种情况下没有任何系统级事件可用，只能靠兜底轮询发现，和现状一致（不是本次改造的退步，只是没有变得更好）。

**兜底轮询**：现有的 `Timer(timeInterval: 60)` → `runOnce()` 原样保留，不改动其触发频率和 `CheckScheduler.isDue` 逻辑。它是三路事件都可能漏掉情况的最终保障，也是 Agent 刚启动、事件监听器还没建立起来之前的初始检查手段。

## 新增组件

| 文件 | 职责 |
|---|---|
| `Sources/AutoVolumeShared/ServerHostSet.swift` | 纯函数：`static func hosts(for configs: [VolumeConfig]) -> Set<String>`，从已启用的网络卷配置中按 `ConnectivityTester` 现有的主机名解析规则去重抽取主机名集合。抽出为独立、可单测的纯函数（无 OS API 依赖），是 `ServerReachabilityWatcher` 决定"该监听哪些主机"的输入。需要把 `ConnectivityTester.hostOnly` 从 `private` 改为可在 `AutoVolumeShared` 内共享（改成 `internal` 或抽成独立函数），避免重复实现主机名解析逻辑。 |
| `Sources/AutoVolumeAgent/NetworkPathWatcher.swift` | 封装 `NWPathMonitor`：`start(onChange: @escaping () -> Void)` / `stop()`。任何 path update 都调用一次 `onChange`，不做业务判断。属于"胶水代码"，直接调用系统 API，不做单元测试（与现有 `startNTFSDiskWatcher()` 的定位一致——那个函数同样没有单测，只测试它调用的 `NTFSAutoMountService` 纯逻辑）。 |
| `Sources/AutoVolumeAgent/ServerReachabilityWatcher.swift` | 封装 `SCNetworkReachability`：`sync(hosts: Set<String>, onChange: @escaping (String, Bool) -> Void)`，对比当前已注册的主机集合和传入的新集合，增量注册新主机、注销不再需要的主机；每个主机一个 `SCNetworkReachabilityRef`，回调里读 `SCNetworkReachabilityFlags` 判断是否 `.reachable`。同样是胶水代码，不做单元测试；但 `sync` 内部"哪些主机该加/该删"这部分差集计算逻辑很简单，直接用 `Set` 运算即可，不需要额外抽象。 |
| `Sources/AutoVolumeAgent/MountedVolumeWatcher.swift` | 封装 `NSWorkspace.shared.notificationCenter` 对 `NSWorkspace.didUnmountNotification` 的订阅，从 `userInfo[NSWorkspace.volumeURLUserInfoKey]` 取出被卸载的路径，只有当路径命中当前某个已启用网络卷的挂载点时才回调（避免用户拔个 U 盘也触发一次全量检查）。 |

`AutoVolumeAgent/main.swift` 改动：

- 把 `runOnce()` 里"遍历 configs、对到期的卷做检查"的循环体抽成 `checkVolumes(configs:, now:, bypassSchedule: Bool)`：
  - `bypassSchedule == false`（原有定时器路径）：保留现有 `scheduler.isDue` 判断，逐个卷决定是否检查——**完全不改变现有行为**。
  - `bypassSchedule == true`（三路事件触发的路径）：跳过 `isDue` 判断，对所有启用的卷立即检查一次；检查完仍然照常调用 `scheduler.markChecked`，让后续的兜底轮询知道"刚检查过，不用马上再查一次"。
- 新增 `checkVolumesNow(reason: String)`，供三路事件触发调用，内部逻辑是：记一行日志（带 `reason`，方便以后排障时从日志看出这次挂载是被什么事件触发的而不是定时轮询，沿用现有 `AutoVolumeLogger` 不新增日志文件）→ 用 `store.load()` 取最新配置 → 调用 `checkVolumes(configs:, now: Date(), bypassSchedule: true)`。另加一个简单的"正在检查中/待处理"标记（两个 `Bool`），避免三路事件短时间内密集触发时并发跑多份 `curl`/`nc`/`mount` 子进程；如果调用 `checkVolumesNow` 时已经有一轮检查在跑，新的触发只记一个"稍后再跑一次"的标记，当前这轮跑完后如果标记为真就立即再跑一轮（而不是丢弃或排队多次）。原有定时器路径调用 `checkVolumes(configs:, now:, bypassSchedule: false)` 不受这个标记影响，两条路径共用同一个"是否在跑"状态即可，避免定时轮询和事件触发的检查互相重叠。
- 启动时创建并 `start()` 三个 watcher；`ServerReachabilityWatcher.sync(hosts:)` 每次 `runOnce()`（无论是定时触发还是事件触发）都重新计算一次当前主机集合并调用，这样卷被增删改时会在下一轮检查内自动更新监听的主机列表，不需要额外监听配置文件变化。

## 边界情况

- **多个卷共用一台服务器**（现有配置里 `synology`/`home` 两个卷用的是同一台群晖）：`ServerHostSet.hosts` 按主机名去重，只注册一次 `SCNetworkReachability`，回调触发的 `checkVolumesNow` 会检查所有启用的卷（不做"只查这台主机对应的卷"的精确匹配，简化实现——反正 `checkVolumesNow` 一轮检查所有卷的成本很低，已挂载且健康的卷检查是轻量的 `isMounted` 本地判断，不会重复发起网络请求）。
- **卷被禁用/删除**：`ServerHostSet.hosts` 只统计 `isEnabled` 的卷，下一次 `sync` 会自动注销不再需要的主机监听。
- **网络抖动导致事件密集触发**：`checkVolumesNow` 的"正在检查中/待处理"标记天然起到合并多次触发的作用，不需要额外的防抖计时器。
- **SCNetworkReachability 注册失败**（比如主机名一时解析不了）：跳过该主机，记一条 warning 日志，该卷退化为只靠 60 秒兜底轮询检测，不影响其他卷。
- **Agent 会话非活跃**（`appSessionIsActive()` 返回 false）：`checkVolumesNow` 内部沿用现有检查，非活跃时不做任何检查（和现有 `runOnce()` 行为一致）。

## 测试策略

延续本代码库已有的测试边界（`ManualTests/AutoVolumeManualTests.swift`，不引入 XCTest）：

- **单测覆盖**：`ServerHostSet.hosts(for:)` 是纯函数，覆盖去重、跳过禁用卷、各协议类型的主机名解析（沿用/复用 `ConnectivityTester.hostOnly` 已验证的逻辑）等场景。
- **不做单测的部分**：`NetworkPathWatcher`（`NWPathMonitor` 胶水）、`ServerReachabilityWatcher` 的 `SCNetworkReachability` 胶水、`MountedVolumeWatcher` 的 `NSWorkspace` 通知订阅——这三者直接封装系统 API 回调，和现有 `startNTFSDiskWatcher()`（`DiskArbitration` 胶水，同样没有单测）是同一类代码，本代码库目前没有为这类系统事件胶水搭建测试基础设施（比如可注入的 fake `NWPathMonitor`），本次也不新增这类基础设施——这是一个明确的、可接受的测试盲区，和现有 NTFS 实时监控的测试覆盖边界一致，不是本次改造引入的新问题。
- **手动验证**（发布前）：断开/重连 WiFi 观察卷是否秒级重新挂载；关闭 NAS 电源模拟服务器下线，观察是否记录失败告警；重新打开 NAS 电源，观察是否秒级自动重新挂载（对比现状最坏 300 秒）；确认现有 60 秒兜底定时轮询行为不受影响（比如临时禁用三路 watcher 测试兜底路径仍然工作）。

## 不做的事

- 不改变 `AgentEngine`、`MountPlanner`、`ConnectivityTester`、`CheckScheduler` 的现有逻辑，只改变触发时机。
- 不针对"服务进程假死但主机可达"这种没有系统事件可用的场景做特殊处理（现状如此，不是本次要解决的问题）。
- 不改变 NTFS 本地磁盘的现有实时监控实现。
