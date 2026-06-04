# AutoVolume 智卷

AutoVolume 是一款轻量级 macOS 菜单栏工具，用于自动检查并恢复网络文件服务器挂载。它适合 NAS、路由器外接硬盘、公司文件服务器、WebDAV 云盘等场景：网络短暂中断后，AutoVolume 会按配置重新连接，减少手动打开 Finder、重新输入服务器地址和账号密码的次数。

![AutoVolume icon](docs/assets/autovolume-icon.png)

## 核心能力

- 支持 SMB、WebDAV、AFP、NFS。
- 支持为每个网络卷配置服务器地址、远程路径、账号、密码、挂载点和检查间隔。
- SMB 支持 SMB2 到 SMB3 自动协商，不启用 SMB1。
- SMB 支持 SMB3 Multichannel 和异步目录读取相关配置。
- 支持挂载服务器内部目录，例如 `smb://nas.local/share/tools`。
- 网络中断后自动检测服务器恢复，并重新挂载。
- 挂载成功后打开 Finder 到目标目录。
- 列表展示挂载状态、失败状态和本地告警，不使用系统弹窗打断工作。
- 密码保存在本地加密文件中，不依赖 macOS 钥匙串。
- 支持中文和英文界面。
- 菜单栏图标支持右键查看日志、关于和退出。
- 单文件本地日志自动保留最近 24 小时，最大 10MB，并按最新时间倒排。

## 下载和安装

最新正式版本为 `0.1.45`，请从 GitHub Releases 下载：

- 发布页: https://mengyuefeitian.github.io/AutoVolume/
- Releases: https://github.com/mengyuefeitian/AutoVolume/releases
- DMG: `AutoVolume-0.1.45.dmg`
- ZIP: `AutoVolume-0.1.45.zip`

安装方式：

1. 打开 DMG。
2. 将 `AutoVolume.app` 拖入 `Applications`。
3. 从 `Applications` 启动 AutoVolume。
4. 在菜单栏中点击 AutoVolume 图标，添加你的网络卷配置。

> 当前包是本地 ad-hoc 签名测试包，未做 Developer ID 公证。首次运行时 macOS 可能会显示安全或网络卷宗权限提示。

## 配置示例

### SMB

- Server: `nas.local`
- Remote Path: `share/tools`
- Mount Point: `/Users/you/Volumes/Tools`
- Username: `your-user`

AutoVolume 会挂载 SMB share，并让 Finder 直接打开配置的子目录。

### WebDAV

- Server: `https://example.com:5006`
- Remote Path: `/` 或 `documents/project`
- Mount Point: `/Users/you/Volumes/WebDAV`

### NFS

- Server: `nas.local`
- Remote Path: `/exports/media`
- Mount Point: `/Users/you/Volumes/Media`

## 隐私和安全

- AutoVolume 不上传你的服务器地址、账号或密码。
- 密码使用本地加密文件保存于用户的 Application Support 目录。
- 挂载命令输出会脱敏，避免在错误提示中泄露密码。
- macOS 仍可能在首次访问网络卷宗时显示系统权限提示，这是系统隐私机制的一部分。

## 构建

项目当前使用 SwiftPM 源码结构，但本地 macOS app bundle 使用手写构建脚本打包。

```bash
cd AutoVolume
./script/build_and_run.sh --verify
```

生成 DMG：

```bash
cd AutoVolume
./script/package_dmg.sh 0.1.45
```

## 项目结构

```text
AutoVolume/
  Sources/AutoVolumeApp/      macOS 菜单栏 App
  Sources/AutoVolumeAgent/    后台检测和重连 Agent
  Sources/AutoVolumeShared/   配置、挂载、加密、状态等共享逻辑
  ManualTests/                本地手工测试入口
  Resources/                  Info.plist、图标、LaunchAgent plist
  script/                     构建和 DMG 打包脚本
docs/
  index.html                  GitHub Pages 产品介绍页
```

## 发布说明

### 0.1.45

- 修复第三方中文输入法在首次添加/编辑窗口中无法输入的问题。
- 菜单栏图标改为原生状态栏控制，支持左键打开列表、右键查看日志、关于和退出。
- 新增本地单文件日志，按最新时间倒排，保留最近 24 小时且最大 10MB。
- 修复列表打开时同步网络卷健康检查导致的卡顿。
- 修复添加/编辑窗口取消、关闭、再次打开和输入框边框显示问题。
- 改进编辑窗口生命周期，避免添加窗口崩溃和关闭后按钮失效。
- 版本号提升到 `0.1.45`。

### 0.1.38

- 增加真实挂载点响应检测，避免 macOS 假挂载或僵尸挂载时仍显示成功。
- 挂载命令返回成功后会验证目标目录是否可访问，必要时清理旧挂载点并重试。
- Finder 无法打开目标目录时改为失败提示，不再显示“挂载成功”误导信息。
- WebDAV 遇到 macOS Finder/DAVKit `-5014` 时显示明确的系统挂载层异常说明。
- 修复 DMG 中 Applications 快捷方式在中文系统下变成“应用程序的替身 2”并乱位的问题。
- 版本号提升到 `0.1.38`。

### 0.1.37

- WebDAV 回到 Finder-compatible AppleScript 挂载路径，避免 `mount_webdav/expect` 的超时和退出码问题。
- 挂载成功后会清理重复 Finder 窗口，并打开系统真实挂载目录。
- 改进 WebDAV、AFP、NFS 的真实挂载点识别和卸载目标选择。
- 网络恢复检测按 1 分钟节奏重试，非网络错误按配置检查间隔处理。
- 增加列表内挂载、卸载、编辑、移除操作和成功/失败状态标记。
- 密码使用本地加密文件保存，错误输出会脱敏。
- 改进 Agent 退出清理，主 App 退出时不再留下孤立保活进程。
- 更新 DMG 安装窗口和 GitHub Pages 介绍页，并优化手机阅读体验。

## License

本项目使用 [MIT License](LICENSE) 开源。
