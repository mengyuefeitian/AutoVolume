# 多架构发布管理（arm64 + x86_64）— 架构决策与实施记录

日期：2026-09-28

## 决策摘要（ADR）

**决策**：单一仓库、单一源码树，架构差异全部下沉到构建层与分发层。每次发布产出**两个安装包**，各自对应独立的 Sparkle 更新源。

**状态**：已实施（0.1.59 起）。

**适用期限**：直至 macOS 28 正式发布，届时移除 x86_64。

**否决的方案**：
- ❌ **按架构分叉源码**（两个仓库 / 两个分支）——必然漂移，修一个 bug 只修一边，review 无法发现。
- ❌ **universal 胖二进制**——单产物、单 feed 看似省事，但维护成本高且不可拆，且被 Homebrew 用惨痛经验证伪（见下）。

---

## 一、三层模型：差异该落在哪一层

多架构产品的差异只应出现在**构建层**和**分发层**，源码层必须保持架构中立。

```
┌─ 源码层（架构中立，单一副本）─────────────────┐
│  Swift 源码零架构分支                          │
│  arch 只出现在日志与诊断导出，不参与逻辑判断   │
└────────────────────────────────────────────┘
            ↓ TARGET_ARCH
┌─ 构建层（参数化）─────────────────────────────┐
│  -target arm64-apple-macosx14.0 / x86_64-…    │
│  第三方二进制按架构分目录：                   │
│    Resources/NTFSDriver/{arm64,x86_64}/       │
└────────────────────────────────────────────┘
            ↓
┌─ 分发层（双产物 + 双 feed）──────────────────┐
│  AutoVolume-<v>.dmg          → appcast.xml     │
│  AutoVolume-<v>-x86_64.dmg   → appcast-x86_64  │
└────────────────────────────────────────────┘
```

**唯一该"分开"的东西是架构特定的第三方二进制**——不是代码。ntfs-3g 必须按架构分别编译（它链接 FUSE-T，是 C 项目，无法靠 Swift 的参数化解决），所以按 `Resources/NTFSDriver/<arch>/` 分目录存放。这是唯一必要的物理分离。

---

## 二、业界证据

### Homebrew：单一 formula，按架构分别分发 bottle

每个 formula 只有**一份定义**，但 bottle 按平台架构分别构建与分发（`arm64_tahoe`、`tahoe`、`sequoia` 各有独立 sha256）。

关键反证：**Homebrew 明确拒绝做 fat/universal binary**。官方讨论记录显示，ppc64/i386/x86_64 时代尝试过 universal，结论是 "was a road of pain"。理由包括：体积翻倍、链接期歧义、单一架构的修复需要重建整个 fat binary、无法独立回滚某个架构。

### Go 生态：单一源码 + 构建矩阵

单一源码树 + `GOOS/GOARCH` 矩阵（CI 中 `strategy.matrix`），产物按 `myapp-darwin-arm64` / `myapp-darwin-amd64` 命名。GoReleaser 提供 `universal_binaries`，但那是**可选的单产物方案，不是默认路径**。

### 结论

双产物是主流，且被 Homebrew 的经验验证。**架构差异从来不是分仓库的理由**；真正该另建仓库的只有一种情况：独立的产品线、独立的发布节奏与团队。

---

## 三、AutoVolume 的落地方案

### 3.1 构建层：`TARGET_ARCH` 贯穿全链路

`TARGET_ARCH`（`arm64` | `x86_64`，默认 `arm64`）是唯一开关，驱动所有脚本：

| 脚本 | 参数化内容 |
|---|---|
| `build_and_run.sh` | 5 处 `-target`、按架构选 NTFS 驱动、按架构注入 `SUFeedURL`、校验驱动 slice |
| `build_ntfs3g.sh` | `-arch`；自动发现 Homebrew autotools；产物输出到 `NTFSDriver/<arch>/` |
| `check_binary_compat.sh` | arm64 硬校验 → 按 `TARGET_ARCH` 校验对应 slice |
| `package_dmg.sh` | 产物命名带架构后缀；去重按架构维度 |
| `release_all.sh` | 串行编排：build → package，两个架构依次完成 |

**顺序是硬约束**：两个架构共用同一个 `dist/AutoVolume.app`，必须"构建完立刻打包"，否则一个架构的包会被封进另一个架构的 DMG。

### 3.2 分发层：双产物 + 双 feed

**为什么必须双 feed**：Sparkle 无法按架构过滤 `enclosure`。如果两份产物写进同一个 appcast，arm64 用户会拿到 x86_64 更新（反之亦然）。

- `docs/appcast.xml` —— **保持为 arm64 feed**。所有存量安装已指向它，改名会让老用户断更。
- `docs/appcast-x86_64.xml` —— Intel 专用 feed（新增）。
- `SUFeedURL` 在**构建时**按架构注入到该架构的 `Info.plist`。
- `publish_release.sh` 按 DMG 文件名路由（含 `x86_64` → Intel feed，其余一律 fallback arm64），并**校验包内二进制架构与文件名一致**，不匹配的包拒绝发布。

fallback 到 arm64 是刻意的：历史产物（`AutoVolume-0.1.58-local.dmg` 等）也能正确落入 arm64 feed。

### 3.3 命名约定

| 架构 | 产物名 |
|---|---|
| arm64 | `AutoVolume-<v>.dmg` |
| x86_64 | `AutoVolume-<v>-x86_64.dmg` |

arm64 不带标记是**安全的**（feed 判定有 fallback），且与早期 `AutoVolume-0.1.53.dmg` 一致，已发布的下载 URL 继续有效。

### 3.4 DMG 窗口布局不再依赖 Finder

**决策**：布局从**提交的快照** `Resources/DMGLayout/dmg-window-layout.dsstore` 应用，不再脚本化 Finder。

**理由**：Finder 自动化需要 macOS TCC 授权，而**无头 CI 机器永远拿不到这个授权**。依赖它还会让产物取决于"哪台机器打包的"。窗口布局是固定设计（两个图标在两个固定位置），快照足够且确定性。

- 默认 `DMG_LAYOUT_MODE=snapshot`
- `DMG_LAYOUT_MODE=finder DMG_SAVE_LAYOUT=1` 可经 Finder 重新生成并回写快照（需授权）
- Finder 失败时的报错已改为明确指出是权限问题而非打包 bug

---

## 四、验证结果（0.1.59）

- x86_64 版 ntfs-3g 编译成功（`x86_64 minos=14.0`）
- 两个架构全链路构建成功；主二进制 / Agent / ntfs-3g 架构一致
- `SUFeedURL` 按架构正确指向各自 feed
- **端到端路由验证**：x86_64 包 → Intel feed、arm64 包 → arm64 feed，互不污染
- `test_check_binary_compat.sh` 与 `test_publish_release.sh` 在双架构下全部通过
- 打包产物挂载校验：`.DS_Store` 布局存在、架构正确、feed 正确

### 顺带修复：日志性能测试的阈值设计缺陷

`ManualTests` 断言首次 `write()` < 0.3s，实测成本 0.28–0.32s —— **阈值压在实测值上，必然随机翻转**（单独跑也 1 通过 2 失败）。

根因：首次 `write()` 必然触发一次 O(n) 全量 prune（60 秒节流），成本本来就与历史日志量相关，用绝对时间阈值判定且机器负载不可控，设计上就脆。

修法：上限提到 1.0s（仍远低于真实回归），并补一条**相对断言**——节流窗口内的第二次 write 必须快于首次的一半。这才是不受机器负载影响的、真正要保护的性质。

---

## 五、生命周期与退出条件

| 时间 | 事件 |
|---|---|
| macOS 26 Tahoe | 末代 Intel 版本，仅 4 款机型 |
| macOS 27 Golden Gate | **已不支持 Intel** |
| macOS 28 | 计划移除 x86_64 支持 |

**退出步骤**（macOS 28 发布后）：
1. 停止发布 `AutoVolume-<v>-x86_64.dmg`
2. 归档 `docs/appcast-x86_64.xml`（保留一段时间，让存量 Intel 用户能拿到最后一个版本）
3. 删除 `build_ntfs3g.sh` 的 x86_64 分支与 `Resources/NTFSDriver/x86_64/`
4. `release_all.sh` 的架构列表收敛为 arm64

因为差异全在构建/分发层，**退出不需要动任何 Swift 源码**——这正是本方案的可逆性价值。

---

## 六、遗留风险

1. **x86_64 无法本机验证**：Rosetta 不能反向模拟（Apple Silicon 能跑 x86_64，Intel 跑不了 arm64）。NTFS 读写涉及 root LaunchDaemon + FUSE-T + ntfs-3g 三方联动，最容易在架构边界出问题。当前只有"二进制架构正确 + 编译链接通过"，**没有真机功能验证**。
2. **FUSE-T 商业授权**：README 注明"非商业用途免费"，商业化前必须谈清楚（与架构无关，但属发布风险）。
3. **SDK 27 的 `-target-arch-variant` bug**：当前 pinned 到 `MacOSX26.5.sdk`，阻塞 macOS 27 适配。
