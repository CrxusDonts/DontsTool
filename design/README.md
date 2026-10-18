# DontsTool 界面设计稿

2026-10-18，使用 Stitch 生成的原生 macOS 启动器 V1 浅色目标设计。打开 `index.html` 浏览五个场景及动效，使用“重播呼出”“收起 / 呼出”和“减少动态效果”观察交互。

## 稿件

| 文件 | 场景 |
| --- | --- |
| [01-launcher.html](01-launcher.html) | 空查询：常用应用、工具关键词 |
| [02-search.html](02-search.html) | 应用与文件的分组搜索结果、键盘选中态 |
| [03-text-tools.html](03-text-tools.html) | JSON 输入、结果摘要、复制与压缩操作 |
| [04-translation.html](04-translation.html) | 系统翻译入口、目标语言、网页兜底 |
| [05-settings.html](05-settings.html) | 独立设置窗口、通用设置和应用索引 |

## 项目理解与范围

DontsTool 是个人自用的原生 macOS 效率启动器，技术栈为 Swift / AppKit，设置及系统翻译使用 SwiftUI。默认 `⌥ Space` 呼出，搜索应用与文件，通过关键词调用文本转换、网页搜索及翻译，界面为简体中文。

当前 `Sources/DontsTool/App/AppController.swift` 只向注册表接入了 `AppProvider`；热键、面板、应用扫描、应用搜索与执行已经有实现。文本转换函数、设置存储及查询核心也已有代码，但文件搜索、文本工具 Provider、网页搜索、翻译和完整设置 UI 尚未全部接线。本目录展示 V1 目标外观，不代表这些能力已经在主程序中实现。

交互与功能范围以 [V1 详细设计](../docs/superpowers/specs/2026-10-18-dontstool-design.md) 为依据。启动器以 `640 × 420pt` 为基准，搜索、结果和底栏三段布局，键盘优先；文本工具采用结果行摘要，不扩展为编辑器。设置使用独立窗口。稿件中的应用、文件名及索引数量是示例数据。

## 设计与来源

- [Stitch 项目](https://stitch.withgoogle.com/projects/17734721049138626585)
- [设计系统与组件规范](DESIGN.md)
- [动效时长、缓动与无障碍规则](MOTION.md)
- `motion.css` / `motion.js`：导出稿统一的浅色选中态、键盘交互和动效演示。
- `../.stitch/designs/`：未修改的 Stitch HTML 原始导出。`design/*.html` 在此基础上加入本地交互演示，并去除重复事件处理。
- `previews/01-*.png` 至 `05-*.png`：Stitch 原始预览图；HTML 另统一了选中态与交互动效。
- `previews/overview-light.png` 与 `settings-light.png`：本地最终 HTML 的浏览器检查截图。
- `stitch-export.json`：项目、设计系统、屏幕标识与导出来源。
- `prompts.json`：生成时使用的结构化提示词。

HTML 是可交互的界面与动效参考稿。打开、复制、翻译、设置开关及重新扫描均为本地演示，不接入本机应用、Spotlight、系统 Translation、UserDefaults 或真实剪贴板。主程序保持原生 Swift；不会把 HTML 作为 WebView 页面嵌入。导出文件可能引用 Tailwind、字体或图标 CDN，直接预览时需要联网。

## 验证

已在浏览器检查五个场景的布局，以及复制反馈、翻译进行中状态、设置开关、收起与重播、减少动态效果开关、输入筛选及单页跳转。设置页在 1280 × 720 视口内完整显示。共享脚本与各 HTML 内联脚本通过语法检查，本地资源链接已逐一核对。
