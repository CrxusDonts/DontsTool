# ADR 0004：双击修饰键采用只读事件监听，而非 Carbon 热键

- 状态：已被 [ADR 0005](0005-double-tap-modifier-with-flags-monitor.md) 取代（2026-10-18）
- 相关：[V1 详细设计 6.2](../superpowers/specs/2026-10-18-dontstool-design.md)、[ADR 0001](0001-native-swift-over-tauri.md)

> 本文保留早期方案与验证记录。当前实现和权限边界以 ADR 0005 为准。

## 背景

希望支持「双击 Option」这类修饰键双击作为全局呼出方式。现有 Carbon `RegisterEventHotKey` 只能注册「修饰键 + 普通键」的组合，无法表达单独的修饰键双击，也无法观察修饰键按下/松开的时序。

可选方案：

1. **Carbon 热键**：无法注册纯修饰键，也无法识别双击；排除。
2. **`NSEvent.addGlobalMonitorForEvents`**：需要辅助功能（Accessibility）权限，未授权时会静默失效；而且会把监听范围扩大到按键内容，权限更重。排除。
3. **只读 `CGEvent.tapCreate`（本方案）**：监听 `flagsChanged` 与 `keyDown`，由应用自己做双击状态机；只需要「输入监控」权限，不拦截事件。
4. **`IOHIDManager`**：同样需要输入监控，API 更底层且要处理设备匹配，复杂度更高；不选。

外部依据：Quartz 事件监听读取键盘需要 Input Monitoring 权限；`CGPreflightListenEventAccess` / `CGRequestListenEventAccess` 是配对的检查与请求 API。详见文末来源。

## 决策

双击修饰键由 `ModifierDoubleTapMonitor` 实现：

- 使用 `.cgSessionEventTap`、`.headInsertEventTap`、`.listenOnly`，订阅 `flagsChanged`（修饰键状态）与 `keyDown`（用于打断双击序列）。
- 监听只读取 `CGEvent.flags` 与事件类型；不读取 `keyboardEventKeycode` 对应的字符、不缓存按键、不记录日志、不拦截或修改事件。
- 纯状态机 `ModifierDoubleTapDetector` 放在 `DontsToolCore`，可单测；规则为两次短按、间隔 ≤ 300ms、期间没有其他按键/修饰键，触发后 500ms 冷却。
- 首次启用时调用 `CGRequestListenEventAccess()` 触发系统授权；设置页显示权限状态与系统设置入口。未授权时保留用户选择的双击配置，但不注册任何全局触发，菜单栏仍可打开启动器。
- 双击模式下不注册 Carbon 热键；组合键模式不创建事件监听，两者互斥。
- 录制期间临时停止两种触发，避免旧快捷键被系统吞掉。

## 后果

- 正面：无需辅助功能权限；不会吞键或改变其他应用输入；双击 ⌘/⌥/⌃/⇧ 都可用。
- 负面/约束：
  - 首次使用需要在「系统设置 → 隐私与安全性 → 输入监控」中授权，通常需要重启应用后生效。
  - ad-hoc 签名在重新构建后可能使授权失效，需要重新勾选。
  - 未授权时双击快捷键不可用；设置页会显示「输入监控权限」提示。
  - 与所有全局键盘监听一样，权限本身较敏感；本应用只在启用双击快捷键时创建监听，且只观察修饰键状态。

## 验证

- 单元测试覆盖双击时序、超时、普通按键打断、其他修饰键打断与冷却。
- 真机验证：录制器可保存 `kind=doubleTap`（keyCode 0，modifiers 为被双击的修饰键位），系统会弹出「输入监控」授权提示；授权后重启，监听启动。
- 只读事件监听已用独立小程序验证能够收到 `flagsChanged` 并识别合成双击。

## 来源

- [AeroSpace issue #1012：CGEventTap 与 Input Monitoring 权限](https://github.com/nikabobko/AeroSpace/issues/1012)
- [CGEvent Taps and Code Signing: The Silent Disable Race](https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/)
- [Apple Support：在 Mac 上控制对输入监视的访问](https://support.apple.com/zh-cn/guide/mac-help/mchl4cedafb6/mac)
- [swift-macos-tap-detection（辅助功能权限方案对照）](https://github.com/obra/swift-macos-tap-detection/)
