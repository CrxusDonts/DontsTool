# 安装与完整性校验

`install.sh` 面向无需 GitHub 登录的用户，从公开 Release 安装已构建的 Universal 应用。不在用户机器上构建源码，不需要 Homebrew、Python、GitHub CLI 或 Xcode。需要 macOS 26+，支持 Apple Silicon 和 Intel。

## 使用脚本安装

在终端运行，无需登录 GitHub：

```bash
curl -fsSL https://raw.githubusercontent.com/CrxusDonts/DontsTool/main/install.sh | /bin/bash
```

默认安装最新稳定版到 `/Applications`，也可下载脚本检查后再执行：

```bash
bash install.sh --help
bash install.sh --dir "$HOME/Applications"
bash install.sh --version v0.3.0
```

脚本不使用 `sudo`。目标目录不可写时会提示改用用户目录，不会自动换目录，避免装出两份应用。仓库或 Release 未公开时匿名下载会失败，旧应用保持不变。

## 为什么发布包是 `.zip` 以及清理机制

DontsTool 正式分发采用经过 Developer ID 签名与 Apple 公证的 Universal `.zip`（而非 `.dmg` 或 `.pkg`）：

- **对齐应用内自动更新**：Sparkle 2 更新器通过 `appcast.xml` 直接消费经过 Ed25519 签名的 `.zip` 归档，同一份发布包同时服务脚本安装、手动拖拽和应用内升级。
- **免挂载与免提权**：`.zip` 不需要挂载磁盘映像或执行特权安装器，脚本可直接校验哈希、签名与公证票据并原子替换 `DontsTool.app`。
- **临时文件与旧版清理**：
  - `install.sh` 在 `$TMPDIR` 下创建一次性临时目录解压校验，并在安装目录同级建立暂存目录完成替换，退出时通过 `trap` 自动清理临时目录、安装锁与已替换成功的旧版备份（替换失败或中断时回滚旧版）。
  - 应用内 Sparkle 更新在重启安装前会先通过终止准备流程刷新打开的本地便笺草稿，替换完成后自动清理下载缓存。
  - 无论脚本替换还是应用内升级，都只更新 `DontsTool.app` 本身，不会清理或改动 `~/Library/Application Support/DontsTool/` 中的便笺、备份和已安装插件，也不会触动钥匙串密钥。

## 首次打开与安装官方插件

1. 从「应用程序」启动 DontsTool（应用驻留菜单栏，不显示 Dock 图标），按默认快捷键 `⌥ Space` 呼出启动器。
2. 按 `⌘,` 打开设置窗口，切换到 **设置 → 插件**。
3. 列表默认内置官方插件仓库 `CrxusDonts/DontsTool-Plugins` 并自动拉取目录。点击「安装全部推荐插件」或按需逐个安装（结束进程、IDEA 项目、文件搜索、Google Chrome、终端与访达）。
4. 在弹出的确认框中核对插件权限和 SHA-256 校验状态后确认安装，插件即刻热加载生效，无需重启主程序。

更多关于自定义 GitHub 插件源、更新与卸载的操作见 [插件使用与开发指南](plugins.md)。

## 脚本下载与替换流程

1. 读取 `manifest.json`，验证应用名、平台、版本、最低系统版本和预期安装包名（`0.2.10` 及之后版本同时核验 `signing=developer-id`、`teamId=Q2K3CAKGG2` 与 `notarized=true`）。
2. 按 manifest 的明确版本下载 `SHA256SUMS` 和 ZIP，避免操作期间 `latest` 变化混用版本。
3. 对照 `SHA256SUMS` 校验 manifest 和 ZIP，并核对 manifest 内的 ZIP SHA256。未知路径或父目录跳转会在解压前被拒绝。
4. 解压到临时目录，检查应用 bundle identifier、版本与代码签名：`0.2.10` 及之后版本使用 `codesign --verify --deep --strict -R=...` 校验 Developer ID（`Q2K3CAKGG2`）身份并通过 `xcrun stapler validate` 校验离线公证票据；`0.2.9` 及更早版本执行 `codesign --verify --deep --strict` 完整性校验。
5. 复制到安装目录内的暂存目录，再执行同等签名与公证校验。替换前再次检查 DontsTool 是否运行，正在运行时提示用户先保存草稿并正常退出。
6. 暂存旧应用，移动新应用到目标位置，并复核最终安装位置的签名与公证票据。失败或中断时尝试恢复旧应用，恢复失败则保留备份并打印位置。

安装目录内的原子锁会阻止两个脚本同时安装，锁从检查目标前一直持有到清理完成。进程被强制杀死留下锁时，脚本会提示位置；确认没有安装任务后可手动删除该空目录。目标位置已有其他应用、文件或符号链接时拒绝覆盖。

## 签名与公证说明

- **0.2.10 及之后版本**：正式发布包使用 Apple Developer ID（Team ID：`Q2K3CAKGG2`）签名、开启 Hardened Runtime 并经 Apple 官方公证及离线钉票，下载安装后可直接通过系统 Gatekeeper 打开。
- **0.2.9 及更早历史版本**：采用 ad-hoc 本地签名。首次打开若被系统拦截，先尝试打开一次，再到 **系统设置 → 隐私与安全性** 选择「仍要打开」。

SHA256 用于检查发布文件一致性；脚本不删除隔离标记或修改 Gatekeeper 策略。应用内的 Sparkle 更新另有 Ed25519 签名验证。

## 脚本测试验证

`make test-installer` 在临时目录创建并签名最小 macOS 应用，使用真实 ZIP、SHA256、plist 和签名检查，只替换下载、进程查询和系统版本查询。覆盖首次安装、指定版本更新、运行中拒绝（含下载期间启动）、文件损坏、缺失校验记录、签名损坏、错误应用、危险路径、替换失败及中断恢复和并发安装。测试不会改动 `/Applications` 或启动应用。
