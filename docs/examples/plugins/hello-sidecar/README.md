# Hello Sidecar 示例插件

这是一个最小化的外部 Sidecar 插件示例，演示 DontsTool 的 `manifest.json`（`schemaVersion: 1`）与 NDJSON over stdio 协议。

## 目录内容

- `manifest.json`：声明插件 ID、关键词 `hello`、`oneshot` 运行模式、权限与可配置项。
- `bin/run`：基于系统 `python3` 的无依赖示例脚本，处理 `search` 与 `execute` 请求。
- `catalog.json`：单插件/多插件仓库统一索引清单示例。

## 本地挂载与调试

1. 确认入口脚本具备可执行权限，且本机已安装 `python3`：

```bash
chmod +x docs/examples/plugins/hello-sidecar/bin/run
```

2. 软链接到 DontsTool 用户插件目录：

```bash
mkdir -p "$HOME/Library/Application Support/DontsTool/Plugins"
ln -s "$PWD/docs/examples/plugins/hello-sidecar" "$HOME/Library/Application Support/DontsTool/Plugins/com.example.hello-sidecar"
```

3. 打开 DontsTool **设置 → 工具 → 插件**，点击 **重新加载**。
4. 呼出启动器输入 `hello 世界`，回车直接复制结果；按 `⌘K` 可触发插件 `execute` 回调。
