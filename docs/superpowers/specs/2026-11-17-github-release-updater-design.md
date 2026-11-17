# GitHub Releases 应用内更新设计

## 目标与已确认选择

用户已选择无需 GitHub 登录，以及应用内下载、安装并重启。更新面向 macOS 26+ 的 DontsTool，继续使用现有 Universal ZIP 和 GitHub Releases。

用户已授权的历史邮箱替换和强制推送已完成，独立于本功能：14 个提交、10 个注释标签已改写，提交代码树逐个核对不变，现有 9 个 Release 的附件未修改。

## 当前实现

- 应用使用 Swift 6、AppKit/SwiftUI 和 XcodeGen，没有更新客户端。
- `Resources/Info.plist` 的短版本为 `0.2.6`；构建号由 CI 运行号注入。
- Release 工作流从稳定标签构建，验证 Universal 架构与 ad-hoc 签名，上传 ZIP、manifest 和 SHA256SUMS，下载回验后发布。
- 当前 GitHub 仓库仍为 private，匿名客户端不能读取其 Release。
- 应用退出已通过 `AppDelegate.applicationShouldTerminate` 协调本地便笺和知识库窗口。

## 方案比较

1. **Sparkle + Release appcast（已选）**：成熟的 macOS 下载、校验、替换、权限处理和重启流程；增加框架依赖和独立更新签名。
2. **检查版本并打开 Release 页面**：实现较小，但需要手动替换应用。用户未选择。
3. **自行实现下载与替换进程**：需要自行维护安装事务、权限和恢复，收益不足，不采用。

Sparkle 的使用、独立更新签名和下列默认行为是实现方的设计选择，尚需用户审阅本设计。

## 使用体验

- 状态栏菜单、应用菜单和设置「关于」提供「检查更新…」。
- 「关于」显示当前版本和「自动检查更新」开关，默认每天检查一次。
- 首次版本保持用户确认后下载安装，不静默替换应用。
- 使用 Sparkle 标准中文界面显示更新说明、下载进度、取消及安装重启。
- 手动检查时明确显示无更新、网络失败或发布源不可访问；后台检查失败不弹窗打扰。
- 不上传使用记录、便笺、知识库内容或系统配置统计，不在客户端保存 GitHub token。
- 更新安装前沿用现有文档保存与关闭确认流程；取消关闭或保存失败时，不强行重启。
- 旧版 0.2.6 没有更新器；用户需手动安装一次首个含更新器的版本，之后可在应用内更新。

## 发布源与公开边界

默认发布源仍为 `CrxusDonts/DontsTool`，feed URL 为 `https://github.com/CrxusDonts/DontsTool/releases/latest/download/appcast.xml`，每个 enclosure 指向具体版本的 ZIP。

本次实现阶段保持仓库 private；不会因为“无需登录”的产品需求直接公开全部代码。正式上线匿名更新前，用户需选择公开此仓库，或改用单独的公开 Release 仓库。实现以发布源配置集中在一处为约束，允许在首次发布前切换来源，不嵌入认证凭据。

只有正式稳定版本进入 appcast，不推送草稿和预发布版本。appcast 存在于同一 Release 的附件中，发布后 `latest/download` 才指向新文件，避免提前发现尚未发布的安装包。

## 客户端结构

- 通过 XcodeGen 引入并固定 Sparkle 2.10.1，只有应用 target 依赖框架。
- 新增更新协调器，持有 `SPUStandardUpdaterController`，提供检查动作、可检查状态和自动检查开关。
- AppController 持有协调器并注入设置窗口，菜单入口复用同一协调器。
- 更新框架负责网络、系统兼容性、安装权限、安装和重启，不在业务代码重写安装器。
- 保留现有 CI 构建号。额外校验候选短版本必须高于当前短版本，防止本地构建号较小导致同版重装或降级。
- 只消费稳定版本，macOS 最低版本保持 26.0，安装包继续包含 arm64 和 x86_64。
- 开发测试允许注入本地测试 feed；正式配置只使用固定 HTTPS 发布源，不提供任意远程安装地址输入。

## 更新签名与发布流程

- 使用 Sparkle Ed25519 签名验证安装包，公钥随应用提交，私钥不入库。
- 本地私钥存于系统钥匙串或已忽略的受限目录；CI 私钥使用 GitHub Actions secret。命令和日志不输出私钥。
- 启用下载后、解压前的更新签名验证，不依靠 SHA256 文件替代来源认证。
- 保留 ad-hoc 应用签名，不新增 Apple Developer ID 或公证前提。
- 打包完成后生成带签名、大小、短版本、构建号和最低系统版本的 appcast。
- 发布脚本上传并下载回验 ZIP、manifest、SHA256SUMS 和 appcast；校验 appcast 引用、签名和文件长度后才公开 Release。
- 缺少签名私钥、签名不匹配、版本不匹配或 appcast 无效时拒绝发布。
- 只发布新版本，不重新构建、覆盖既有正式 Release；首个含更新器版本使用新的版本号。

## 验证与验收

- 先为版本比较、发布元数据生成和错误路径编写失败测试，再实现对应逻辑。
- 测试旧版本、同版本、较小本地构建号、非稳定版本、无效元数据和缺少签名等边界。
- 发布脚本在临时目录中使用固定输入执行，断言 appcast URL、版本、长度、签名和校验文件对应真实归档。
- 运行 Core、WebKit bridge 和编辑器现有测试，构建 Universal Release，检查嵌入框架、签名和解压后的两种架构。
- 使用隔离测试应用和本地测试 feed 演练检查、下载、签名拒绝和安装重启，不覆盖用户正在使用的正式应用。
- 如未能实际完成安装重启演练，报告具体验证边界，不将构建成功视作更新成功。
- 正式发布前验证 GitHub 发布源可在无认证请求下访问。仓库仍 private 时，不宣称匿名更新已上线。

## 不在本次范围

不增加自建更新服务器、GitHub 登录、用户 token 配置、差分更新、预发布频道、自动静默安装或 Apple 公证。开源许可证及其他审计项脱敏不在本功能中顺带修改。

## 参考

- [Sparkle 接入](https://sparkle-project.org/documentation/)
- [Sparkle 程序化接入](https://sparkle-project.org/documentation/programmatic-setup/)
- [Sparkle 发布与签名](https://sparkle-project.org/documentation/publishing/)
- [GitHub Releases API](https://docs.github.com/en/rest/releases/releases)
