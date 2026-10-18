# ADR 0001：主程序采用原生 Swift，而非 Tauri/Electron

- 状态：已接受；知识库插件的 WebView 例外由 [ADR 0007](0007-first-party-knowledge-web-plugin.md) 部分取代
- 日期：2026-10-18
- 关联：[架构总览](../architecture.md)

## 背景

项目目标是做一个个人自用的 macOS 启动器，体验上对标 uTools/Raycast：全局热键呼出、输入即搜、键盘操作。

最初的候选包括：

1. Swift + AppKit/SwiftUI 的原生应用
2. Tauri 2（Rust + 系统 WebView）
3. Electron（未深入评估，因内存和体积直接排除）

Tauri 2 曾被短暂选中，原因是前端开发效率高、未来有跨平台可能，且比 Electron 轻得多。但进一步明确需求后，项目的第一优先级是 **原生流畅度与系统集成**，而不是跨平台或 Web 技术复用，因此重新评估。

## 决策

主程序采用 **Swift 6 + AppKit**：

- 浮动面板、搜索框、结果列表、键盘导航、焦点管理用 AppKit。
- 设置页使用 SwiftUI。
- Translation 框架所需的视图用 SwiftUI 承载。
- macOS 26+，无第三方运行时依赖。

## 为什么不是 Tauri/Electron

- Tauri 仍然使用系统 WebView 渲染界面，UI 不是原生控件；复杂键盘交互、焦点与窗口层级仍要跨 WebView 边界处理。
- Electron 内存与体积开销明显更高，与“个人常驻启动器”的定位不符。
- 本项目只面向 macOS，不需要跨平台能力；为跨平台潜力付出的复杂度没有回报。
- 扩展模型已确定为内置 Swift 模块（见 [ADR 0002](0002-built-in-modules-over-plugin-runtime.md)），不再需要 Web 技术栈来承载插件。

## 后果

正面：

- 热键呼出、列表滚动、焦点切换都是原生行为，性能上限最高。
- 可直接使用 Carbon、NSWorkspace、Spotlight、Translation、SMAppService 等系统能力。
- 无 WebView 和第三方运行时，常驻内存与启动开销更可控。
- 决策与业界实践一致：Raycast v1 是 Swift/AppKit 应用，扩展 UI 由原生应用渲染；Tinycast 等原生启动器也采用 Swift/AppKit + SwiftUI 混合。

负面：

- UI 代码量比 Web 前端大，列表、键盘导航需要自己实现。
- 仅支持 macOS；未来若要跨平台需要重写 UI 层。
- Swift/AppKit 的维护门槛高于 TypeScript。

## 依据

- [A Technical Deep Dive Into the New Raycast](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast)：Raycast v1 使用 Swift/AppKit，几乎不用 SwiftUI；扩展使用 React/TS/Node，UI 声明式渲染。
- [tinycast](https://github.com/abue-ammar/tinycast)：原生 macOS 启动器，SwiftUI + AppKit，常驻内存低于 100MB。
- [SwiftUI + AppKit 混合开发：打造 macOS 轻量启动器](https://bbs.csdn.net/weixin_29708043/article/details/100357268)：纯 SwiftUI 在浮动面板、焦点、键盘导航上的限制，以及 NSPanel 的实践。
- [Tauri 与 Electron：性能、包大小及真实权衡](https://tool.lu/fr_FR/article/78K/preview?locale=zh_CN)：Tauri 比 Electron 轻，但仍是 WebView 渲染。
