# AutoVolume Project Rules

## 铁律 / HARD RULE — 永远不要使用 macOS 钥匙串（Keychain）

> **本项目禁止使用 Apple 钥匙串，任何情况下都不行。没有例外，没有"这样更方便"的折中。**

凭据一律存 `EncryptedFileCredentialStore`（`Sources/AutoVolumeShared/CredentialStore.swift`）：用户拥有的本地加密文件，盐 + AES-GCM。

禁止出现：

- 任何 Keychain API —— `SecItemAdd`、`SecItemCopyMatching`、`SecItemUpdate`、`SecItemDelete`、`SecKeychain*`、`SecAccessControl`、`kSecClass*`、`kSecAttrService`、`kSecAttrAccount`
- 通过 `Process`/shell 调用 `security` 命令行工具

**唯一允许的例外**：`import Security` 仅用于 `SecRandomCopyBytes`（CSPRNG，生成盐和 nonce）。这是随机数发生器，不是钥匙串。不要因为这个 import 存在就以为可以用钥匙串。

**为什么**：钥匙串会在不可预期的时刻弹授权框；且本应用实际运行在三种完全不同的上下文里（菜单栏 App、LaunchAgent、特权 LaunchDaemon），钥匙串在这些上下文中的行为不一致；它还会把用户的 NAS 密码放进一个应用无法推理、无法迁移的地方。

**强制方式**：`script/check_no_keychain.sh` 在 `build_and_run.sh` 最前面运行（编译之前，失败成本一秒）。它会剥离注释后再扫描——说明文字里提到禁用符号不算违规。该门禁自身由 `script/tests/test_check_no_keychain.sh` 测试。扫描范围包含 `script/`，所以发布脚本里出现 `security` 命令同样会让构建失败。

### 发布工具链（git / GitHub）同样禁止钥匙串

git 默认用 `osxkeychain`、GitHub 工具默认把 token 放进钥匙串，于是每一次 `git push`、每一次 GitHub 调用都要敲门——一次发布连弹好几次。本仓库改用文件通道：

- token 放在 `~/.config/autovolume/github_token`（owner-only，600），与 Sparkle 私钥同一模式，不入 git
- `script/git_credential_file.sh` —— git credential helper，从该文件应答（`get` 有效，`store`/`erase` 直接忽略，避免凭据被重新藏到别处）
- `script/setup_git_no_keychain.sh` —— 一键配置，**只写 `<repo>/.git/config`**，不影响机器上其他项目。它先用空值 helper 重置继承来的 `osxkeychain`：git 按 system→global→local 顺序收集 helper，不清空的话全局的 osxkeychain 会先跑并弹窗，我们的 helper 根本轮不上
- `script/publish_release.sh` 导出 `GH_TOKEN` / `GITHUB_TOKEN` 供任何 GitHub 工具使用（文件缺失时保持不设置，让 API 调用自己报错，而不是发布中途弹框）

迁移 token（这是最后一次需要钥匙串出面的操作）：

```bash
mkdir -p ~/.config/autovolume
printf 'protocol=https\nhost=github.com\n' | git credential fill   # 取 password= 那一行
# 或：gh auth token > ~/.config/autovolume/github_token
chmod 600 ~/.config/autovolume/github_token
```

配置后自检：`printf 'protocol=https\nhost=github.com\n' | git credential fill` 应当立即返回 username/password 且不弹框。

## Build environment note (Swift toolchain / SDK)

On this machine, the default `swiftc` (installed via `swiftly`, Swift 6.3.3) fails to compile any multi-file target that imports Foundation when paired with the default `MacOSX.sdk` (`MacOSX27.0.sdk`) — it hits a reproducible `error: unknown argument: '-target-arch-variant'` inside the ClangImporter's Foundation module build. This reproduces identically on Swift 6.2.4 and 6.3.3, and is specific to SDK 27.0 (confirmed via minimal repro: 2+ Swift files each importing Foundation, `-emit-module`, any SDK-27.0-based invocation). The older `MacOSX26.5.sdk` (also shipped under `/Library/Developer/CommandLineTools/SDKs/`) does not have this bug.

**Always build/test with these env vars set** until this is fixed upstream or a newer Xcode/CLT resolves it:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk MACOSX_DEPLOYMENT_TARGET=14.0 script/build_and_run.sh --no-launch
```

(`MACOSX_DEPLOYMENT_TARGET=14.0` matches `Package.swift`'s `platforms: [.macOS(.v14)]`.) Every command below that invokes `script/build_and_run.sh` **or `script/package_dmg.sh`** implicitly needs this prefix — `package_dmg.sh` also shells out to `swift` (to render the DMG background image) and hits the same SDK 27.0 bug otherwise.

## Release workflow after code changes

> **铁律 / HARD RULE — 每次修改完成必须提升版本号，绝不覆盖已有版本。**
> Every build handed to the user after ANY code change MUST have a new, never-used version (patch +1 in `CFBundleShortVersionString`, `CFBundleVersion` +1). **Never** rebuild or repackage under a version number that already has a DMG in `dist/` or was ever handed to the user — not for "small fixes", not for review-fix waves, not for "the same release, just corrected". Each distinct build = distinct version, so the user can tell which build a bug came from. `script/package_dmg.sh` refuses to overwrite an existing DMG; never delete an old DMG to get around that. This rule also overrides any plan text that says "bump once at the end": plans batch work, but every DMG given to the user gets its own version.

After finishing any code change in this project (including small/intermediate iterations, not just final "done" states), automatically:

1. **Bump the version** in `Resources/Info.plist`:
   - `CFBundleShortVersionString`: increment the patch number (e.g. `0.1.45` → `0.1.46`)
   - `CFBundleVersion`: match the new patch number as a plain integer (e.g. `46`)
2. **Build and package both architectures**: run `script/release_all.sh <version>` (e.g. `script/release_all.sh 0.1.46`), matching the version bumped in step 1. It pins `SDKROOT`/`MACOSX_DEPLOYMENT_TARGET` internally, then builds arm64 and x86_64 in turn, **packaging each immediately** — both architectures write to the same `dist/AutoVolume.app`, so build and package must stay paired or one arch's bundle will be sealed into the other arch's DMG. Produces `dist/AutoVolume-<v>.dmg` (arm64) and `dist/AutoVolume-<v>-x86_64.dmg` (Intel). All manual tests must pass for each architecture.
4. **Hand back to the user for self-testing**: tell the user the new DMG paths (`dist/AutoVolume-<version>.dmg` and `dist/AutoVolume-<version>-x86_64.dmg`) and ask them to test them themselves before it's considered done. Do not mark the task complete on your own say-so — this step exists because compile/tests passing does not prove the feature behaves correctly in the running app.

This applies automatically without the user needing to ask each time — it mirrors the workflow this project used with Codex previously. Skip this only if the user explicitly says not to (e.g. "don't package this, just show me the diff").

**Not covered by this rule:** git commits/pushes.

## Dual-architecture releases (arm64 + x86_64)

Every release ships **two installers** — `AutoVolume-<v>.dmg` (arm64) and `AutoVolume-<v>-x86_64.dmg` (Intel) — cut from the same source at the same version. This continues until macOS 28 ships, after which Intel support is dropped.

Only Intel is explicitly marked. arm64 keeps the plain `AutoVolume-<v>.dmg` name used by every pre-0.1.59 release, so published download URLs and appcast entries keep resolving without a rename.

- **`TARGET_ARCH`** (`arm64` | `x86_64`, default `arm64`) drives every script: `build_and_run.sh`, `build_ntfs3g.sh`, `check_binary_compat.sh`, `package_dmg.sh`. `build_and_run.sh` exports it, so the shell test suites inherit the architecture being built — their fixtures compile for `TARGET_ARCH` too.
- **Two Sparkle feeds.** Sparkle cannot filter enclosures by architecture, so each arch has its own feed and the matching `SUFeedURL` is baked into that arch's Info.plist at build time:
  - `docs/appcast.xml` → arm64 (kept as-is: every install predating the split already points here)
  - `docs/appcast-x86_64.xml` → x86_64
- **Publishing**: `script/publish_release.sh` derives the architecture from the DMG filename and writes to the matching feed. Verify both artifacts landed in the right feed — swapping them silently breaks updates for one architecture.
- **NTFS driver**: `ntfs-3g`/`libntfs-3g` are architecture-specific and must be built per-arch. arm64 keeps the flat `Resources/NTFSDriver/` layout; other architectures live in `Resources/NTFSDriver/<arch>/`. Rebuild with `TARGET_ARCH=x86_64 script/build_ntfs3g.sh` (needs the GNU build system; the script finds Homebrew's autotools itself). FUSE-T is already universal, so no cross-toolchain work is needed there.
- **Only the ntfs-3g binaries are arch-specific.** Swift sources, Sparkle, FUSE-T, the mount commands and the LaunchDaemon plists are all architecture-neutral — no `#if arch(...)` branches exist anywhere. Bumping the version and building a local DMG are local, reversible actions; committing to git still follows the global git-safety rules (only commit when explicitly asked). When the user does ask to commit a release, follow the existing convention: a single `release: prepare AutoVolume X.Y.Z` commit (see `git log` for examples) that includes the version bump alongside the code changes.
