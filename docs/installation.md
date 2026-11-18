# 安装脚本

`install.sh` 面向无需 GitHub 登录的用户，从公开 Release 安装已构建的 Universal 应用。不在用户机器上构建源码，不需要 Homebrew、Python、GitHub CLI 或 Xcode。需要 macOS 26+，支持 Apple Silicon 和 Intel。

## 使用

在终端运行，无需登录 GitHub：

```bash
curl -fsSL https://raw.githubusercontent.com/CrxusDonts/DontsTool/main/install.sh | /bin/bash
```

默认安装最新稳定版到 `/Applications`，也可下载脚本并检查后执行：

```bash
bash install.sh --help
bash install.sh --dir "$HOME/Applications"
bash install.sh --version v0.2.6
```

脚本不使用 `sudo`。目录不可写时会提示改用用户目录；不自动换目录，以免意外装出两份应用。仓库或 Release 未公开时，匿名下载会失败，旧应用保留。

## 下载和替换

1. 读取 `manifest.json`，验证应用名、平台、版本、最低系统版本和预期安装包名（`0.2.10` 及之后版本同时核验 `signing=developer-id`、`teamId=Q2K3CAKGG2` 与 `notarized=true`）。
2. 按 manifest 的明确版本下载 `SHA256SUMS` 和 ZIP，避免操作期间 `latest` 变化混用版本。
3. 对照 `SHA256SUMS` 校验 manifest 和 ZIP，并核对 manifest 内的 ZIP SHA256。未知路径或父目录跳转会在解压前被拒绝。
4. 解压到临时目录，检查应用 bundle identifier、版本与代码签名：`0.2.10` 及之后版本使用 `codesign --verify --deep --strict -R=...` 校验 Developer ID（`Q2K3CAKGG2`）身份并通过 `xcrun stapler validate` 校验离线公证票据；`0.2.9` 及更早版本执行 `codesign --verify --deep --strict` 完整性校验。
5. 复制到安装目录内的暂存目录，再执行同等签名与公证校验。在替换前再次检查 DontsTool 是否运行；正在运行时要求用户先保存草稿并正常退出。
6. 暂存旧应用，移动新应用到目标位置，并复核最终安装位置的签名与公证票据。失败或中断时尝试恢复旧应用；恢复失败则保留备份并打印位置。

安装目录内的原子锁会阻止两个脚本同时安装，锁从检查目标前一直持有到清理完成。进程被强制杀死留下锁时，脚本会提示位置；确认没有安装任务后可手动删除该空目录。

仅替换 `DontsTool.app`，不操作设置、便笺或钥匙串。目标位置已有其他应用、文件或符号链接时拒绝覆盖。安装后由用户手动打开应用。

SHA256 用于检查发布文件一致性；`0.2.10` 及之后版本的 Developer ID 签名与 Apple 公证可直接由系统 Gatekeeper 验证，脚本仍不删除隔离标记或修改 Gatekeeper 策略。`0.2.9` 及更早历史版本使用 ad-hoc 签名，首次打开方式见 [README](../README.md#签名与公证说明)。应用内的 Sparkle 更新另有 Ed25519 签名验证。

## 验证

`make test-installer` 在临时目录创建并签名最小 macOS 应用，使用真实 ZIP、SHA256、plist 和签名检查，只替换下载、进程查询和系统版本查询。覆盖首次安装、指定版本更新、运行中拒绝（含下载期间启动）、文件损坏、缺失校验记录、签名损坏、错误应用、危险路径、替换失败及中断恢复和并发安装。测试不会改动 `/Applications` 或启动 Gemini / DontsTool。
