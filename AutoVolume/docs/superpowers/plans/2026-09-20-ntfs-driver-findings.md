# NTFS 驱动调研结论

日期：2026-09-21

## 已验证的事实

1. **FUSE-T 安装完成标记**：`/Library/Application Support/fuse-t/uninstall.sh` 存在即视为 FUSE-T 已安装（已在本机通过 `brew install --cask fuse-t` 实测确认）。

2. **ntfs-3g 必须使用 `macos-fuse-t/ntfs-3g` 分支，而非通用 Homebrew `ntfs-3g-mac`**：后者链接的是 macFUSE（需要用户在系统设置中手动批准 System Extension），不符合本项目"无需用户手动批准扩展"的前提。正确的是专门为 FUSE-T 构建的分支：

   ```bash
   brew tap macos-fuse-t/homebrew-cask
   brew install fuse-t automake autoconf libtool libgcrypt pkg-config gnutls
   git clone https://github.com/macos-fuse-t/ntfs-3g
   cd ntfs-3g
   export CPPFLAGS="-I/usr/local/include/fuse"
   export LDFLAGS="-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib"
   ./autogen.sh
   ./configure --prefix=/usr/local --exec-prefix=/usr/local --with-fuse=external --sbindir=/usr/local/bin --bindir=/usr/local/bin
   make -j"$(sysctl -n hw.ncpu)"
   ```

   已在本机完整构建成功，产出 `src/.libs/ntfs-3g` 和 `libntfs-3g/.libs/libntfs-3g.89.dylib`。

3. **挂载命令（已实测，普通用户 + root 两种场景都验证过）**：

   ```
   <bundled>/ntfs-3g <devicePath> <mountPoint> -olocal -oallow_other -oauto_xattr
   ```

   用一个本机 `hdiutil create` + `mkntfs` 制作的测试 NTFS 卷验证：挂载后 `touch`/写入文件成功。

4. **卸载命令**：复用现有 `diskutil unmount <mountPoint>`，与 SMB/WebDAV 一致，无需 ntfs-3g 专属卸载命令。

5. **⚠️ 重大发现——原计划的权限模型不成立**：无论用 FUSE-T 还是 macFUSE，`ntfs-3g` 打开原始块设备（`/dev/diskN`）都需要 root 权限，这是 macOS 的系统级限制，与 FUSE 后端无关（已用普通用户直接调用验证，报错 `Unprivileged user can not mount NTFS block devices`）。
   - 尝试过给二进制加 setuid-root 位（`chown root:wheel` + `chmod u+s`）绕过——**被 ntfs-3g 自身的安全检查拒绝**：链接外部 FUSE 库（即 FUSE-T）时，ntfs-3g 明确拒绝以 setuid 方式运行（`Mount is denied because setuid and setgid root ntfs-3g is insecure with the external FUSE library`），这是 ntfs-3g 上游有意的安全设计，无法绕过。
   - 交叉验证：参考了用户提供的 [nohajc/anylinuxfs](https://github.com/nohajc/anylinuxfs) 项目（用 libkrun 微虚拟机运行真实 Linux 内核驱动挂载任意 Linux 文件系统，通过 NFS 暴露给 macOS，同样无内核扩展）——其官方文档同样明确写着 **"It is needed to run mount commands with sudo otherwise we're not allowed direct access to /dev/disk* files"**。这证实了「打开原始块设备需要 root」是 macOS 的普遍限制，不是 ntfs-3g 或某个 FUSE 实现的特有问题，任何方案都绕不开。
   - **结论**：不能像 SMB/WebDAV/NFS 那样让无权限的 `AutoVolumeAgent` 直接 shell out 执行挂载命令。必须新增一个**常驻的特权 LaunchDaemon 辅助进程**（安装时需要一次管理员密码，这一步本来就已经需要——FUSE-T 安装本身就需要管理员权限——不增加额外的用户操作次数），由它以 root 身份代为执行挂载/卸载，无权限的 Agent 通过本地 IPC（Unix domain socket）向它发送请求。这是 macOS 上处理"需要偶尔特权操作"的标准做法（等价于经典的 SMJobBless 特权助理模式）。

6. **许可证审查**：
   - `ntfs-3g`（`macos-fuse-t/ntfs-3g` 分支同样遵循上游）：GPLv2，作为独立子进程调用，不静态链接，随包附带 `LICENSE-ntfs-3g.txt`。
   - **FUSE-T 二进制分发许可证：非商业用途免费；商业用途（含捆绑进商业软件分发）需要向 FUSE-T 作者购买商业许可证**（见 `LICENSE-fuse-t.txt`）。已与用户确认：AutoVolume 目前是个人/内部使用，不对外销售或收费，属于非商业用途，可以直接使用免费条款内置 FUSE-T。**如果未来 AutoVolume 的分发方式变为商业性质（销售、收费、对外分发给不特定用户等），需要重新评估此许可证条款，可能需要联系 FUSE-T 作者购买商业许可，或改用其他方案。**

## 已内置到 Resources/NTFSDriver 的产物

- `ntfs-3g`：已构建、已用 `install_name_tool` 调整为相对自身目录（`@loader_path/libntfs-3g.89.dylib`）+ 依赖 FUSE-T 安装后位于 `/usr/local/lib` 的 `libfuse-t.dylib`（通过 rpath 解析），使其在 App bundle 内自包含（除 FUSE-T 本身需要另行安装外不依赖其他 `/usr/local` 路径）。
- `libntfs-3g.89.dylib`：`ntfs-3g` 的运行时依赖。
- `fuse-t-installer.pkg`：FUSE-T 1.2.7 官方安装包（来自 Homebrew cask 缓存）。
- `LICENSE-ntfs-3g.txt`、`LICENSE-fuse-t.txt`：对应许可证文本。

## 对计划的影响（需要在正式实施前更新 spec 和 plan）

原 spec/plan 假设 `AutoVolumeAgent`（无权限用户级进程）可以直接调用 bundled `ntfs-3g` 完成挂载。经本次调研证实不可行，需要新增权限模型：

- 新增一个特权 LaunchDaemon（root 常驻服务），只负责"挂载/卸载指定设备到指定路径"这一件事，攻击面尽量小。
- 首次安装时（与 FUSE-T pkg 安装同一次管理员密码授权流程）一并安装并启动这个 LaunchDaemon。
- `AutoVolumeAgent`（无权限）通过本地 Unix domain socket 向 LaunchDaemon 发送挂载/卸载请求，不再自己直接 `Process` 调用 `ntfs-3g`。
- 后续任务需要新增：`NTFSPrivilegedHelper`（LaunchDaemon 的可执行文件 + plist）、一个简单的请求/响应协议、`NTFSMountPlanner` 需要改为构造"发给 helper 的请求"而不是直接构造 `ntfs-3g` 的 `CommandPlan`。

## Rebuild for 14.0（2026-09-24）

上面第 2 条记录的手工构建产物 minos=27.0，导致 `check_binary_compat.sh` 门禁在 macOS 14–26 上失败。已改为可复现脚本 `script/build_ntfs3g.sh`：以 `MACOSX_DEPLOYMENT_TARGET=14.0` + `-mmacosx-version-min=14.0` 重新 clone 并编译 `macos-fuse-t/ntfs-3g`，产出 `ntfs-3g` 和 `libntfs-3g.89.dylib` 替换 `Resources/NTFSDriver` 下的旧文件，install name / rpath / 依赖列表与旧版完全一致（`@loader_path/libntfs-3g.89.dylib`、`@rpath/libfuse-t.dylib`、`libSystem`、`CoreFoundation`，`LC_RPATH /usr/local/lib`）。

FUSE-T 头文件（`fuse.h` 等）在本机 `/usr/local/include/fuse` 不存在时，脚本支持通过 `FUSE_INCLUDE` 环境变量指向从 `Resources/NTFSDriver/fuse-t-installer.pkg` 用 `pkgutil --expand-full` 解出的 `.../fuse-t-core.pkg/Payload/Library/Application Support/fuse-t/include/fuse` 目录；注意该路径含空格，需先复制到一个不含空格的临时目录再传给 `FUSE_INCLUDE`（否则 `CPPFLAGS` 在 `configure`/`make` 内部被空格拆分，`configure` 会报 "C compiler cannot create executables"）。

详见 `script/build_ntfs3g.sh`。
