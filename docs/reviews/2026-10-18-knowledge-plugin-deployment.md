# 知识库插件生产部署

用户在本地实现完成后明确授权“你部署啊”。于 2026-10-18T10:51:06Z 完成提交、推送、Actions 部署和线上验证。

- 发布提交：`8cf2cfa3768d36db7c4a7e98ee0dc86fb8e5b854`
- Actions：[39120074779](https://github.com/CrxusDonts/DontsKb/actions/runs/39120074779)，verify/deploy 均 success。
- 服务器 `/home/ubuntu/dontskb/deployed-commit` 与该 SHA 一致，生产 checkout 为对应提交。
- API、Web、Caddy、Blog 四个容器均 healthy。
- 公网 `/health/live`、`/health/ready` 均返回 `{"status":"ok"}`。
- 公网 `/tool?mode=search` 的 HTML SHA-256 与运行中 Web 容器 `/srv/index.html` 一致：`19039f914ab2105f55df7fe64de14194632ed5cf1643e46d5066435b0c4bb9e0`。

使用原生生产 `KnowledgeWebBridge.swift` 编译临时独立 WKWebView 探针，直接连接 `https://kb.ddonts.com/tool?mode=search`，实际结果：

```text
production_protocol_v1_ready=true
anonymous_search_authenticated=false items=0
prepare_close_lock=true canClose=true
resume_interaction=true
```

探针不登录、不回报文章内容、不执行知识库内容写入。结果位于 `/tmp/dontstool-live-plugin-probe-result.log`。它补充了线上 WKWebView/React 协议互操作证据；不替代真实账户的多窗口、图钉或物理中文输入法验收。

DontsTool 设置 → 知识库中填写 `https://kb.ddonts.com`，在插件窗口内登录后使用 `kb 关键词`、`collect 内容` 和 `inbox`。DontsTool 原生构建仍为本地开发产物，本次发布的是 DontsKb Web。

本次只提交知识库插件相关的16个文件，DontsKb 工作区在推送后干净。沿用现有日常部署脚本，没有数据库结构变更，没有手动删除数据或绕过 CI。
