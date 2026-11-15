# 网站多环境快捷入口参考

2026-11-15 通过 Stitch 生成，沿用 DontsTool 石墨工作台设计系统。此目录仅包含设计参考，没有修改原生应用实现。

- `index.html`：无外部依赖的本地交互演示。输入 `ops 订单` 显示两行，`ops test` 仅显示 TEST，`ops prod` 仅显示 PROD。支持上下选择；Enter 和点击只展示目的地址，不打开网址。
- `stitch-reference.html`：Stitch 原始 HTML，未修改，依赖 Tailwind CDN 与 Google Fonts。
- `stitch-reference.png`：使用 Stitch `download_file` 下载的原始截图，2560×2048 画布中展示 700×480 逻辑像素面板。
- `stitch-export.json`：项目、设计系统、屏幕、文件资源名、增强提示词、Stitch 说明与建议。

Stitch 项目：`8779626504181051745`；设计系统：`assets/1366425092952266023`；屏幕：`261d0c76fc7a4781a5cabe63454b5bee`。

面板搜索头 72px、结果行 54px、底栏 38px。相同网站按环境展开为独立结果，标题后显示 TEST / PROD，下一行展示完整虚构目的地址。省略环境时显示全部环境，查询环境关键词时筛选；不增加全局环境切换器。

离线演示从既有设计系统的 graphite tokens 提取表面层级，保持原生字体。TEST 使用蓝色、PROD 使用琥珀色，用于区分环境（原生实现的 PROD 使用红色），原始 Stitch 稿保持不改。它是便于预览的派生稿，不声称与 Stitch 原稿逐像素一致；实际启动器交互及能力以 Swift 源码为准。全部网址使用虚构 `.example` 域名。

Stitch 返回的说明：紧凑原生浮动启动器、行内 TEST/PROD 标识、完整 URL 与环境过滤提示。返回的可选建议为：生成 `ops test` 单项结果状态、增加上下文动作抽屉、生成暖灰版本。这些建议没有自动成为功能需求。
