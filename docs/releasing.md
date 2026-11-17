# 构建与发布

## 版本来源

`Resources/Info.plist` 的 `CFBundleShortVersionString` 为版本唯一来源，使用稳定版本号 `MAJOR.MINOR.PATCH`。Release 标签必须为同版本的 `vMAJOR.MINOR.PATCH`。构建号通过 Xcode 的 `CURRENT_PROJECT_VERSION` 注入：本地默认1，CI 使用工作流运行号。

不把 `.xcodeproj`、`build/`、`dist/`、本机设置、钥匙串或证书提交进仓库。设计源文件、测试和通用配置示例可入库；包含生产知识库正文的本地截图已排除。

## 本地验证

```bash
make test
make test-bridge
make test-updater
make release
(cd dist && shasum -a 256 -c SHA256SUMS)
```

`make release` 调用 `scripts/package-release.sh`，重新生成 Xcode 工程，构建 arm64 / x86_64 Universal 应用，验证版本与构建号，使用 `codesign --sign - --timestamp=none` 签名。`lipo -verify_arch` 检查两种架构，`codesign --verify --deep --strict` 检查签名；ZIP 解压后再次验证并与构建二进制比对。

可通过 `DT_BUILD_NUMBER`、`DT_DERIVED_DATA`、`DT_DIST_DIR` 指定构建号和输出位置；`DT_RELEASE_TAG` 如提供则必须与源码版本一致。脚本不会安装或启动应用，也不会访问证书或钥匙串。

本地打包还需要更新签名私钥：默认读取已忽略的 `.signing/updater/private.key`，也可通过 `DT_UPDATE_KEY_FILE` 指定路径，或通过 `SPARKLE_PRIVATE_KEY` 环境变量提供。私钥应只对当前用户可读，不提交到 Git、不在命令行参数中传入密钥正文、不写入日志。

`Resources/Info.plist` 的 `SUPublicEDKey` 保存公钥，`SUFeedURL` 保存固定 HTTPS 更新源。Sparkle 固定为 2.10.1，签名工具取自 SwiftPM 校验过的同一依赖。打包脚本使用 `sign_update` 签名 ZIP，再用独立 CryptoKit 公钥校验器复核；私钥与公钥不匹配时拒绝生成 appcast。

## GitHub 发布

1. 提交源码版本和变更到 `main`，等待 CI 成功。
2. 创建并推送对应版本的注释标签。
3. Release 工作流只查询 `refs/tags` 命名空间，将注释标签解析到固定提交 SHA；测试、构建和打包都使用该 SHA，发布前再次核对远端标签未移动。
4. 创建草稿 Release，上传 Universal ZIP、`manifest.json`、`SHA256SUMS` 和 `appcast.xml`。
5. 使用 GitHub CLI 下载回验，检查 SHA256、Ed25519 签名及 appcast 版本/长度/下载 URL，并与刚构建的四个文件逐字节比较。
6. 验证通过才取消草稿状态并设为 Latest。

仓库和正式 Release 已公开，安装脚本、安装包和校验文件均可匿名下载。CI 只需读取仓库；只有发布 job 具有 `contents: write`，GitHub 令牌仅在发布步骤通过环境变量提供给 CLI。Actions 固定到具体提交 SHA。

0.2.7 起提供基于公开 Release 的应用内更新。仅公开仓库不会生成更新源，需正式发布包含签名安装包和 `appcast.xml` 的新版后才能使用。0.2.6 及更早版本需先手动安装含更新器的新版；客户端不需要 GitHub 登录或维护者凭据。

Release job 还需要仓库 Secret `SPARKLE_PRIVATE_KEY`，内容为 Sparkle 支持的 base64 Ed25519 私钥种子。现有密钥已在本次接入时生成并设置；公钥入库，私钥留在已忽略的本地目录与 Actions Secret 中。恢复构建环境时应恢复同一密钥；更换密钥需要单独安排迁移，不能直接用新私钥签名给旧客户端安装。

`appcast.xml` 跟随每个正式 Release 发布，客户端通过 `releases/latest/download/appcast.xml` 读取。短版本和 CI 构建号同时写入 appcast；客户端额外拒绝同短版本和更低短版本，避免本地构建号与 CI 运行号差异导致降级。

发布失败后可用工作流手动入口填写已有标签重跑。同一源码提交、包含脚本标识的草稿可恢复；其他草稿和正式发布不会被覆盖。已正式发布的版本需要递增版本号再发布，不移动已有标签。

## 安装边界

产物使用 ad-hoc 本地签名，非 Developer ID 签名、非 Apple 公证。签名校验验证包完整性，不提供 Apple 的开发者身份认证。首次打开可能需要在系统隐私与安全性设置中允许该应用，详见 [README 安装说明](../README.md#安装)。
