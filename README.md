<div align="center">

<img src="docs/assets/autovolume-icon.png" width="128" alt="AutoVolume icon">

# AutoVolume 智卷

**让 NAS、网盘和移动硬盘在 Mac 上「一直在线」的菜单栏小工具**

断网、休眠、换 Wi‑Fi 之后，自动帮你把网络文件夹重新挂回来；NTFS 移动硬盘插上就能直接读写。

[![Download](https://img.shields.io/github/v/release/mengyuefeitian/AutoVolume?label=%E4%B8%8B%E8%BD%BD&style=flat-square)](https://github.com/mengyuefeitian/AutoVolume/releases/latest)
![Platform](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)
![Requirements](https://img.shields.io/badge/macOS-14%2B-fa4e49?style=flat-square)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2B-black?style=flat-square)
[![Website](https://img.shields.io/badge/%E5%AE%98%E7%BD%91-xiaoanhome.xyz-015FBA?style=flat-square)](https://www.xiaoanhome.xyz/autovolume)
[![License](https://img.shields.io/github/license/mengyuefeitian/AutoVolume?style=flat-square)](LICENSE)

中文 | [English](README_en.md)

</div>

---

## ✨ 它能帮你做什么

每天打开 Mac，NAS 上的文件夹又断开了？挂载 WebDAV 网盘要重新输一遍地址和密码？插上 Windows 用的移动硬盘却只能看不能写？

AutoVolume 住在菜单栏里，把这些麻烦都自动处理掉：

- 🔁 **自动重连**：网络断了又恢复、Mac 从睡眠醒来之后，自动把网络文件夹重新挂上，不用再手动在 Finder 里「连接服务器」。
- 🗂 **一次配置，长期可用**：服务器地址、账号、密码、挂载位置保存一次就好，之后开机即用。
- 💽 **NTFS 移动硬盘读写**：插上 NTFS 格式的移动硬盘，自动以「可读写」方式挂载（首次需要输入一次电脑密码）。
- 🔄 **自动更新**：每天自动检查新版本，一键安装并重新打开。
- 🌏 **多语言**：跟随系统 / 中文 / English / 한국어 / 日本語 / Русский，切换即时生效。
- 🩺 **一键诊断**：遇到问题，一键导出诊断包（不含密码），方便反馈排查。

## 📦 支持的连接方式

| 类型 | 适用场景 | 示例 |
|---|---|---|
| **SMB** | 群晖 / 威联通 NAS、Windows 共享、路由器外接硬盘 | `nas.local` + `share/tools` |
| **WebDAV** | 群晖 WebDAV、坚果云等网盘 | `https://example.com:5006` + `/` |
| **AFP** | 老款 NAS / Time Capsule | `nas.local` + `share` |
| **NFS** | Linux 服务器、NAS 的 NFS 共享 | `nas.local` + `/exports/media` |
| **NTFS 硬盘** | Windows 格式的 U 盘 / 移动硬盘 | 插上即可，无需配置 |

SMB 默认使用 SMB2–SMB3 自动协商（不启用不安全的 SMB1），并可开启 SMB3 多通道等高级选项；也支持直接挂载共享里的子目录，例如 `smb://nas.local/share/tools`。

## 📥 下载安装

1. 前往 [Releases](https://github.com/mengyuefeitian/AutoVolume/releases/latest) 下载最新的 `AutoVolume-x.y.z.dmg`。
2. 打开 DMG，把 **AutoVolume** 拖进「应用程序」文件夹。
3. 从「应用程序」打开 AutoVolume，菜单栏会出现 AutoVolume 图标。

> **首次打开被 macOS 拦截？** AutoVolume 目前没有经过 Apple 公证。请打开「系统设置 → 隐私与安全性」，在页面下方点击「仍要打开」即可。

> **从 0.1.52 及更早版本升级**：需要手动下载安装一次 0.1.53 或更新版本；之后的新版本会自动提示升级。

**系统要求**：macOS 14 Sonoma 或更高版本，Apple 芯片（M1 及以上）的 Mac。

## 🚀 使用方法

1. **添加网络文件夹**：左键点击菜单栏图标 → 点「添加」→ 选择类型（SMB / WebDAV / AFP / NFS），填写服务器地址、路径、账号和密码 →「测试连通性」→「保存并挂载」。
2. **之后就不用管了**：AutoVolume 会按你设置的间隔检查，断开了就自动重新挂载；列表里可以随时手动挂载、卸载、编辑或删除。
3. **NTFS 硬盘读写**：右键菜单栏图标 →「设置」→「NTFS」页，打开「自动以读写方式挂载 NTFS 外接硬盘」，之后插入硬盘即可读写。
4. **右键菜单**：查看日志、导出诊断信息、设置、检查更新、退出。
5. **设置**：
   - 「通用」：语言、日志级别、重连成功后是否自动在 Finder 中打开。
   - 「NTFS」：NTFS 硬盘读写开关。
   - 「关于」：版本号、GitHub、官网、检查更新。

## ❓ 常见问题

<details>
<summary><b>菜单栏里看不到 AutoVolume 图标？</b></summary>

- 请确认使用的是 **0.1.53 或更新版本**：更早的版本在 macOS 14/15 上无法启动。
- 如果菜单栏图标太多，带刘海的 MacBook 可能会把部分图标挡住，可以按住 ⌘ 拖动其他图标腾出位置，或使用 Ice、Bartender 等菜单栏管理工具。

</details>

<details>
<summary><b>WebDAV 挂载失败，提示 401 / 403 / 404？</b></summary>

- **401**：账号或密码不对。
- **403**：这个账号没有访问该路径的权限。
- **404**：远程路径写错了，根目录请填 `/`。

</details>

<details>
<summary><b>开启 NTFS 读写为什么要输入电脑密码？</b></summary>

读写 NTFS 硬盘需要安装一个小驱动（基于开源的 ntfs-3g 和 FUSE-T，不需要安装系统扩展、不用进恢复模式）。安装驱动需要管理员权限，只在第一次、以及 AutoVolume 升级后需要输入一次。

</details>

<details>
<summary><b>出问题了怎么反馈？</b></summary>

右键菜单栏图标 →「导出诊断信息…」，桌面会生成一个 zip 压缩包。请在 [Issues](https://github.com/mengyuefeitian/AutoVolume/issues) 里描述问题并附上这个压缩包。压缩包里**不包含任何密码**，账号名也会被隐去。

</details>

<details>
<summary><b>怎么卸载？</b></summary>

右键菜单栏图标 →「退出」，把「应用程序」里的 AutoVolume 移到废纸篓。如需清除配置，删除 `~/Library/Application Support/AutoVolume` 文件夹。

如果开启过 NTFS 读写，还可以在「终端」里执行以下命令移除 NTFS 组件（需要输入电脑密码）：

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.autovolume.ntfshelper.plist
sudo rm -f /Library/LaunchDaemons/com.autovolume.ntfshelper.plist /Library/PrivilegedHelperTools/com.autovolume.ntfshelper /etc/newsyslog.d/com.autovolume.ntfshelper.conf
sudo rm -rf /Library/PrivilegedHelperTools/com.autovolume.ntfsdriver
```

FUSE-T 是独立安装的组件，可按 [FUSE-T 官方说明](https://www.fuse-t.org) 卸载。

</details>

## 🔒 隐私与安全

- 不收集、不上传任何数据；服务器地址、账号、密码只保存在你自己的 Mac 上。
- 密码使用本地加密文件保存，不写入日志；日志和诊断包中的密码会被自动隐去。
- 自动更新通过 GitHub 下载，并使用 EdDSA 签名校验，防止安装被篡改的更新。

## 🛠 从源码构建

```bash
git clone https://github.com/mengyuefeitian/AutoVolume.git
cd AutoVolume/AutoVolume
./script/build_and_run.sh --verify     # 编译、运行测试、签名
./script/package_dmg.sh 0.1.53         # 打包 DMG（版本号需与 Info.plist 一致）
```

构建说明、发布流程等详见 [`AutoVolume/CLAUDE.md`](AutoVolume/CLAUDE.md)。

<details>
<summary>项目结构</summary>

```text
AutoVolume/
  Sources/AutoVolumeApp/        菜单栏 App（界面、设置、自动更新）
  Sources/AutoVolumeAgent/      后台检测与自动重连
  Sources/AutoVolumeShared/     配置、挂载、多语言、日志等共享逻辑
  Sources/AutoVolumeNTFSHelper/ NTFS 特权辅助进程
  ManualTests/                  测试
  Resources/                    Info.plist、图标、NTFS 驱动
  script/                       构建、打包、发布脚本
docs/
  index.html                    GitHub Pages 介绍页
  appcast.xml                   自动更新源
```

</details>

## 📝 更新日志

每个版本的更新内容见 [Releases](https://github.com/mengyuefeitian/AutoVolume/releases)。

## 🙏 致谢

- [Sparkle](https://sparkle-project.org) — 自动更新框架（MIT）
- [ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g) — NTFS 读写驱动（GPLv2）
- [FUSE-T](https://www.fuse-t.org) — 无需内核扩展的 FUSE 实现（非商业用途免费）

## 📄 许可证

AutoVolume 使用 [MIT License](LICENSE) 开源。内置的第三方组件遵循各自的许可证，许可证文本随应用一起分发。
