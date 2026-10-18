# ADR 0005：双击修饰键仅监听修饰键变化

- 状态：已接受（2026-10-18）
- 取代：[ADR 0004](0004-double-tap-modifier-with-listen-only-event-tap.md)
- 相关：[V1 详细设计 6.2](../superpowers/specs/2026-10-18-dontstool-design.md)

## 背景

双击 Option 只需要识别修饰键的两次短按。早期方案用只读 CGEventTap 同时接收 flagsChanged 和 keyDown，因而把输入监控授权作为前置条件。普通按键监听只是为了防止 Option 组合输入被误判为双击。

Quicksilver 的实现提供了更窄的参考：仅订阅修饰键变化，用系统按键事件计数判断期间是否出现普通输入。本项目独立实现了这条路径。

## 决策

- `ModifierDoubleTapMonitor` 使用 `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` 及对应的本地监听。两者覆盖其他应用和本应用，原事件照常传递。
- 不创建 CGEventTap，不订阅全局 keyDown/keyUp，不检查或请求输入监控及辅助功能授权，移除相关权限设置入口。
- 在修饰键变化时查询 `CGEventSource.counterForEventType` 与 `secondsSinceLastEventType`。只比较事件计数和时间，不接收键码、字符或输入内容，也没有定时轮询。
- 两次短按间隔不超过 300ms，每次按住不超过 300ms；在第二次松开时触发，随后冷却 500ms。其他修饰键或普通输入会取消序列。
- 回调可能在主线程排队。若最近普通按键发生在该修饰键事件之后，取消该事件对应的序列；同时检查按住期间和两次短按之间的按键时间，宁可不触发，也不把普通输入当作双击。
- 录制器继续使用应用内 keyDown 识别组合键和 Esc；这是本应用内输入，不是全局键盘监听，不请求权限。
- 创建监听失败时，恢复上一个组合键或默认 Option+Space，并显示回退提示。菜单栏始终保留打开入口。

## 验证与边界

2026-10-18 使用独立、ad-hoc 签名的 App 验证。检查结果为 `AXIsProcessTrusted() == false`、`CGPreflightListenEventAccess() == false`；用户切到其他应用实际按下 Option 后，该 App 收到全局 flagsChanged 的按下/松开事件。全程未请求或变更系统授权。

直接从已授权的终端/宿主启动 CLI 会继承授权，不能作为免权限证据。此次自动化合成按键也没有到达已授权的对照进程，因此没有将合成输入当作实际键盘验收。

当前证据证明此路径在本机系统上可接收未授权的跨应用修饰键变化；不据此承诺所有历史或未来 macOS 版本的行为。监听句柄创建成功本身不能证明全局投递，后续平台升级需重复独立 App 验收。

回归测试覆盖短按、长按、冷却、普通按键计数变化、计数回绕、其他修饰键打断、排队回调和取消后的恢复。

## 来源

- [Quicksilver：修饰键监听与事件计数](https://github.com/quicksilver/Quicksilver/blob/main/Quicksilver/Code-App/QSModifierKeyEvents.m)
- [Apple：Monitoring Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)
- [Apple：CGEventSource.counterForEventType](https://developer.apple.com/documentation/coregraphics/cgeventsource/counterforeventtype(_:eventtype:))
- [Apple：CGEventSource.secondsSinceLastEventType](https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:))
