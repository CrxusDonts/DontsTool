# 右键长按划词翻译

用户目标：在其他应用选中文字后，长按右键／双指按下触控板 2 秒，即可在鼠标旁查看译文。继续阅读时无需经过启动器，不创建一串工具窗口。

## 设置和交互

- 设置 → 翻译 → 右键长按翻译，默认关闭。
- 跨应用读取选中文字需要辅助功能授权。只有点击「授权辅助功能」才请求系统提示；启动器的组合键、双击修饰键不增加授权要求。
- 默认使用系统翻译，语言包未准备时提供翻译设置入口；完整配置自定义 API 地址、模型和钥匙串密钥后优先使用该服务。API 出错不自动回退。系统后端在本机翻译，API 后端只在明确翻译时发送原文。
- 持续按住约 2 秒触发；短按在释放时恢复右键菜单。长按只在仍按住时触发；松开本身不会启动翻译。触发后原始按下和松开均不交给源应用，避免同时显示菜单。
- 右键拖动超过 8pt 恢复源应用操作；修饰键、滚动或其他点击会取消尚未触发的手势。带修饰键的右键不参与取词。
- 只在鼠标所在窗口属于前台应用且为普通窗口时处理，后台窗口、菜单或无法确认目标时放行。
- 一张 380×330pt 卡片重复使用。原文预览最多四行，长译文可以滚动。编辑原文打开带选区内容的独立翻译窗口。
- 卡片不主动激活 DontsTool，不抢走源应用的焦点。标题区可拖动，固定后外部点击与应用切换不关闭；Esc 或关闭按钮始终可关闭。

## 实现边界

`RightPressGesture` 是独立于 macOS 的事件路由状态机；`RightPressMonitor` 只在开启并已授权时安装 active session event tap，处理鼠标及修饰键变化。普通键盘事件不会进入这个 tap。

原始右键按下暂存。按原始事件时间判断连续两秒且物理右键仍按下，随后才开始 AX 取词；不再要求 250ms 内预先成功。短按松开或阈值前移动时恢复原事件；松开不会补触发翻译。恢复通过当前 tap proxy 保证原始按下先于松开/拖动，带重放标记并校验前台 PID 与原窗口，避免发给别的应用。

AX 读取在串行 actor 执行，不阻塞 tap，每个消息超时 150ms，整次取词等待最多三秒。长按触发后先显示读取状态；失败、超时或过长选区显示译文卡片内的具体原因，提供编辑原文入口而不联网。关闭、Esc、编辑和切换应用取消等待结果，迟到结果不重弹或发请求；取消仍保留已触发手势的配对 mouse-up 消费状态。

`SelectedTextReader` 先对鼠标位置做辅助功能命中测试，要求命中元素与焦点元素属于同一 AX 窗口，再读取命中、焦点元素及有限父级的 `AXSelectedText`，空字符串会继续尝试后续候选；这样不会把同一应用窗口 A 的选区翻译到窗口 B 旁。拒绝安全文本输入框、空文本和超过 8000 UTF-16 单元的选区。不模拟复制、不读取或监控剪贴板、不截图、不 OCR、不记录内容。

`SelectionTranslationController` 管理单个 nonactivating NSPanel、设置与授权状态、取消、固定和关闭。译文计算复用 `ToolSession` 和 `PreferredTranslationService`（完整 API 配置优先，否则系统翻译），旧请求不能覆盖新选区，关闭卡片取消在途结果。显式复制才写入剪贴板。

## 验证

- 核心测试：短按、阈值、单次触发、迟到选区、无选区、拖动、修饰键取消、应用切换和设置持久化。
- 原生测试：卡片复用时的响应乱序、关闭取消，以及真实 SwiftUI 浅／深色、未配置状态渲染。测试使用固定翻译响应，无外部 API 请求。
- 必须单独验证：通过本机安装的 App 授权后，在浏览器、IDE、普通文本应用中实际选词；鼠标及触控板短按／长按／拖动；输入监控权限保持未授权时是否可正常使用；睡眠恢复与多屏边缘位置。自动化状态机测试不能证明真实触控板和各应用 AX 兼容性。

设计来源及可交互 HTML 见 [design/selection-translation](../design/selection-translation/README.md)。

## 来源

- [Apple：全局 NSEvent monitor 只能观察，不能阻止原事件](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)
- [Apple：AXSelectedText](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute)
- [Apple：触控板双指辅助点按与 Force Click 是不同操作](https://support.apple.com/en-au/102482)
