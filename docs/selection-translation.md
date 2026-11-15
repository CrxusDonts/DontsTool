# 右键长按划词翻译

用户目标：在其他应用选中文字后，长按右键／双指按下触控板 2 秒，即可在鼠标旁查看译文。继续阅读时无需经过启动器，不创建一串工具窗口。

## 设置和交互

- 设置 → 翻译 → 右键长按翻译，默认关闭。
- 跨应用读取选中文字需要辅助功能授权。只有点击「授权辅助功能」才请求系统提示；启动器的组合键、双击修饰键不增加授权要求。
- 使用用户配置的大模型翻译服务，需在「设置 → 翻译」填写 Responses 兼容接口地址、模型和 API 密钥；密钥保存在本机钥匙串。缺少配置时显示填写提示和设置入口，不发送请求。只在明确翻译时发送原文，不自动切换服务。
- 持续按住约 2 秒触发；短按在释放时恢复右键菜单。长按只在仍按住时触发；松开本身不会启动翻译。触发后原始按下和松开均不交给源应用，避免同时显示菜单。
- 右键拖动超过 8pt 恢复源应用操作；修饰键、滚动或其他点击会取消尚未触发的手势。带修饰键的右键不参与取词。
- 通过系统鼠标命中检测确定目标，透明区域和忽略鼠标的覆盖层不作为目标；只在目标属于前台应用且为普通窗口时处理，后台窗口、菜单或无法确认目标时放行。
- 一张 380×330pt 卡片重复使用。原文预览最多四行，长译文可以滚动。编辑原文打开带选区内容的独立翻译窗口。
- 卡片不主动激活 DontsTool，不抢走源应用的焦点。标题区可拖动，固定后外部点击与应用切换不关闭；Esc 或关闭按钮始终可关闭。

## 实现边界

`RightPressGesture` 是独立于 macOS 的事件路由状态机；`RightPressMonitor` 只在开启并已授权时安装 active session event tap，处理鼠标及修饰键变化。普通键盘事件不会进入这个 tap。

原始右键按下暂存。用同一个单调时钟记录按下并判断连续两秒，且物理右键仍按下，随后才开始 AX 取词；不再要求 250ms 内预先成功。短按松开或阈值前移动时恢复原事件；松开不会补触发翻译。恢复通过当前 tap proxy 保证原始按下先于松开/拖动，带重放标记并校验前台 PID 与原窗口，避免发给别的应用。

AX 读取在串行 actor 执行，不阻塞 tap，每个消息超时 150ms，整次取词等待最多三秒。长按触发后先显示读取状态；失败、超时或过长选区显示译文卡片内的具体原因，提供编辑原文入口而不联网。关闭、Esc、编辑和切换应用取消等待结果，迟到结果不重弹或发请求；取消仍保留已触发手势的配对 mouse-up 消费状态。

监听因回调超时被系统暂停时会尝试重新启用；等待中的长按取消并按原目标恢复右键，已开始的选区读取继续完成。恢复后保持按下、拖动和松开的配对；系统主动停用或恢复失败时显示暂停状态。

`SelectedTextReader` 先对鼠标位置做辅助功能命中测试，要求命中元素与焦点元素属于同一 AX 窗口，再读取命中、焦点元素及有限父级的 `AXSelectedText`，空字符串会继续尝试后续候选；这样不会把同一应用窗口 A 的选区翻译到窗口 B 旁。拒绝安全文本输入框、空文本和超过 8000 UTF-16 单元的选区。不模拟复制、不读取或监控剪贴板、不截图、不 OCR、不记录内容。

`SelectionTranslationController` 管理单个 nonactivating NSPanel、设置与授权状态、取消、固定和关闭。译文计算复用 `ToolSession` 和 `RemoteTranslationService`，与独立翻译窗口使用相同的大模型配置。旧请求不能覆盖新选区，关闭卡片取消在途结果。显式复制才写入剪贴板。

## 验证

- 核心测试：短按、阈值、单次触发、迟到选区、无选区、拖动、修饰键取消、应用切换和设置持久化。
- 原生测试：卡片复用时的响应乱序、关闭取消，以及真实 SwiftUI 浅／深色、未配置状态渲染。测试使用固定翻译响应，无外部 API 请求。
- 必须单独验证：通过本机安装的 App 授权后，在浏览器、IDE、普通文本应用中实际选词；鼠标及触控板短按／长按／拖动；输入监控权限保持未授权时是否可正常使用；睡眠恢复与多屏边缘位置。自动化状态机测试不能证明真实触控板和各应用 AX 兼容性。

### 原生输入验收（2026-11-16，构建 21）

使用同一签名的 `/Applications/DontsTool.app --verify-right-press`，长按回调只显示测试卡片，不启动选区读取、密钥查询或翻译请求。通过 `scripts/verify-right-press-input.swift` 从系统 HID 事件入口发送按下／松开；浏览器打开 `Tests/Fixtures/right-press.html`，同时核对应用日志、原生菜单和页面收到的事件。

- 连续两轮 2500ms 按压：在满 2 秒后出现成功卡片，松开后卡片保留；浏览器未收到右键事件，也未显示右键菜单。
- 长按后的 150ms 按压：浏览器收到配对的 down/up 和一个 contextmenu，显示原生右键菜单。
- 退出验收模式、正常启动后再发送 150ms 按压：原生菜单仍正常。
- 46 项相关原生回归测试通过，包括无位移滚动阶段、实际滚动取消、短按恢复、窗口变化、超时恢复及事件配对。

对照实验确认：吞掉 down 后，`combinedSessionState` 显示松开，`hidSystemState` 仍显示按住。因此长按的实时按钮检查使用 HID 状态。触控板的零位移滚动阶段不取消长按；实际位移仍取消。设置密钥只在首次进入翻译页时加载，避免隐藏设置视图在启动时读取钥匙串并阻塞主线程。

本机证据位于忽略构建目录 `build/gesture-acceptance/`：`results.json`、`long-hold.jpg`、`short-after-long.jpg`。这是系统输入注入验收，不代表所有触控板硬件和各应用取词兼容性均已验证。

设计来源及可交互 HTML 见 [design/selection-translation](../design/selection-translation/README.md)。

## 来源

- [Apple：全局 NSEvent monitor 只能观察，不能阻止原事件](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)
- [Apple：AXSelectedText](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute)
- [Apple：触控板双指辅助点按与 Force Click 是不同操作](https://support.apple.com/en-au/102482)
- [Apple：双指接触触控板会先产生 mayBegin 阶段，滚动尚未真正开始](https://developer.apple.com/documentation/appkit/nsevent/phase-swift.property)
- [Hammerspoon：CGEventTap 的事件放行和超时恢复](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/libeventtap.m)
- [Mac Mouse Fix：ClickCycle 的按下、计时和松开处理](https://raw.githubusercontent.com/noah-nuebling/mac-mouse-fix/master/Helper/Core/Buttons/ClickCycle.swift)
