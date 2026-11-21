# 右键长按划词翻译

用户目标：在其他应用选中文字后，长按右键，或在妙控板上双指保持接触至设定时间（默认 2 秒），即可在鼠标旁查看译文。继续阅读时无需经过启动器，不创建一串工具窗口。

## 设置和交互

- 设置 → 翻译 → 右键长按翻译，默认关闭。
- 全局右键拦截及向源应用发送复制指令需要辅助功能授权。只有点击「授权辅助功能」才请求系统提示；启动器的组合键、双击修饰键不增加授权要求。
- 使用用户配置的模型服务进行翻译，需在「设置 → 模型服务」添加模型配置并填写 API 密钥（支持 OpenAI Responses、Gemini 原生与 OpenAI Chat Completions，并可为「翻译与划词」绑定独立模型）；密钥保存在本机钥匙串。缺少配置时显示填写提示和设置入口，不发送请求。只在明确翻译时发送原文，不自动切换服务。
- 设置 → 翻译 → 唤起时间，可选 300ms、500ms、1 秒、2 秒；默认 2 秒，修改立即生效并取消正在等待的手势。鼠标或妙控板双指保持至阈值后触发；双指入口不要求触发物理点击或让系统持续报告右键按下。短按在释放时恢复右键菜单。长按只在仍按住时触发；松开本身不会启动翻译。触发后原始按下和松开均不交给源应用，避免同时显示菜单。
- 右键拖动超过 8pt 恢复源应用操作；修饰键、滚动或其他点击会取消尚未触发的手势。带修饰键的右键不参与取词。
- 通过系统鼠标命中检测确定目标，透明区域和忽略鼠标的覆盖层不作为目标；只在目标属于前台应用且为普通窗口时处理，后台窗口、菜单或无法确认目标时放行。
- 一张 380×330pt 卡片重复使用。原文预览最多四行，长译文可以滚动。编辑原文打开带选区内容的独立翻译窗口。
- 卡片不主动激活 DontsTool，不抢走源应用的焦点。标题区可拖动，固定后外部点击与应用切换不关闭；Esc 或关闭按钮始终可关闭。

## 实现边界

`TrackpadContactSource` 直接接收内置触控板和外接 Magic Trackpad 的触点，按设备分别识别双指保持。枚举所有设备，不只使用默认触控板；通过传感器尺寸过滤 Touch Bar，通过设备类型排除 Magic Mouse。设备接入／移除及睡眠恢复时重新注册，关闭翻译时注销。使用 path callback 的单触点坐标和 frame callback 的帧边界，避免依赖 macOS 不同版本的触点数组步长。框架为运行时加载的私有 `MultitouchSupport`；符号不可用时保留原有鼠标右键入口。参考 MiddleClick 和 Hammerspoon 的触点接口定义，未引入其实现代码或依赖。

`TrackpadHoldGesture` 按两个固定触点计时，触点漂移超过归一化表面距离 0.025、指针移动超过 8pt、触点增减／替换、或帧间断超过 300ms 都会取消，需全部抬手才能重新识别。双指保持时允许累计至多 6pt 的滚动噪声，超过即取消；真正的双指滚动、缩放不触发。鼠标与触点两条入口共用一次取词请求；松手生成的辅助点按在原位置、原窗口内抑制 250ms，后续右键恢复正常。原始触点只在内存判断，不记录坐标或上传。

`RightPressGesture` 是独立于 macOS 的事件路由状态机；`RightPressMonitor` 只在开启并已授权时安装 active session event tap，处理鼠标及修饰键变化。普通键盘事件不会进入这个 tap。

原始右键按下暂存。用同一个单调时钟记录按下并判断已达到设定时间，且物理右键仍按下，随后才复制取词；不再要求 250ms 内预先成功。短按松开或阈值前移动时恢复原事件；松开不会补触发翻译。恢复通过当前 tap proxy 保证原始按下先于松开/拖动，带重放标记并校验前台 PID 与原窗口，避免发给别的应用。

焦点窗口和安全输入校验在后台执行，每个 AX 消息超时 150ms；主线程只负责复制事件与剪贴板访问。复制后每隔 10ms 检查一次更新，最多 60 次；卡片层仍保留三秒总超时。取词期间不弹面板，取得有效文字后才显示翻译卡片。失败、超时、空白或过长选区静默结束，只在设置的手势诊断中保留原因，不发送翻译请求。未固定的旧卡片在新取词开始时收起；已固定译文保持原样，直到新取词成功。关闭、Esc、编辑和切换应用取消等待结果，迟到结果不重弹或发请求；取消仍保留已触发手势的配对 mouse-up 消费状态。

监听因回调超时被系统暂停时会尝试重新启用；等待中的长按取消并按原目标恢复右键，已开始的选区读取继续完成。恢复后保持按下、拖动和松开的配对；系统主动停用或恢复失败时显示暂停状态。

`SelectedTextReader` 直接向源 PID 发送配对 Cmd-C。发送前及等待期间同时校验前台 PID、原鼠标窗口和 AX 聚焦窗口，避免同一应用窗口 A 的手势复制窗口 B 的文字；安全输入不参与。记录复制前的剪贴板 `changeCount`，只在其更新后读取新文字，并检查读前读后计数稳定。不主动清空或还原剪贴板；本次复制的文字保留，与普通 Cmd-C 一致。复制失败不使用原有内容。拒绝空文本和超过 8000 UTF-16 单元的选区，不截图、不 OCR、不记录文本或复制历史。

`SelectionTranslationController` 管理单个 nonactivating NSPanel、设置与授权状态、取消、固定和关闭。译文计算复用 `ToolSession` 和 `RemoteTranslationService`，与独立翻译窗口使用相同的大模型配置。旧请求不能覆盖新选区，关闭卡片取消在途结果。长按触发会让源应用复制原文；点击「复制译文」才以译文替换剪贴板。

单词和词汇性短语按词典方式回答：使用目标语言按适用词性分组，列出常见的不同义项，必要时给简短用法或例句，不编造词性或强凑多个意思。句子和段落仍按语境只给译文，保留原格式。两种结果均为纯文本，划词卡片与独立翻译窗口共用规则。

## 验证

### 2026-11-18 静默取词与多义释义

- 新增真实原生窗口测试，确认读取、失败及纯空白不会显示面板；固定的旧译文不会被失败取词清空。测试先观察到 10 项失败，修改后 bridge 全量 144 项通过。
- Core 全量 444 项通过，应用构建成功；深色与浅色长释义快照已检查，长内容在原有区域滚动。
- 使用本机现有翻译配置，以公开测试文本 `run` 和 `I run every morning.` 实际调用服务。单词返回动词、名词分组的多个常见义项和例句；句子仅返回“我每天早上跑步。”，没有附加词典内容。凭据未写入日志或仓库。
- 本轮没有重新进行鼠标硬件或跨应用 AX 验收，也没有安装、推送或发布。现有手势状态机和取词接口保持原路由。

- 核心测试：短按、阈值、单次触发、迟到选区、无选区、拖动、修饰键取消、应用切换和设置持久化。
- 原生测试：卡片复用时的响应乱序、关闭取消，以及真实 SwiftUI 浅／深色、未配置状态渲染。测试使用固定翻译响应，无外部 API 请求。
- 必须单独验证：通过本机安装的 App 授权后，在浏览器、IDE、普通文本应用中实际选词；鼠标及触控板短按／长按／拖动；输入监控权限保持未授权时是否可正常使用；睡眠恢复与多屏边缘位置。自动化状态机测试不能证明真实触控板和各应用 AX 兼容性。

### 妙控板双指入口（2026-11-16，本机候选构建）

旧版只从右键事件计时，未直接读取双指接触。本次补充原始触点入口，自动回归覆盖没有任何右键 down 的双指保持、HID 按钮状态为松开时的触点触发、两条入口去重、短按菜单恢复、抬手时的延迟点按、滚动和跨设备取消。本机原生探针直接运行生产 `TrackpadContactSource`，识别到一台外接触控板，收到真实的 began/cancelled/ended；这证明设备和触点回调接通。用户随后确认手势可唤起卡片；当前取词改为用户明确授权的直接复制，四档唤起时间和剪贴板新鲜度均有回归覆盖。

### 原生鼠标输入验收（2026-11-16，构建 21）

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

- [Hammerspoon 触点接口：单触点 path callback 和帧回调](https://github.com/asmagill/hs._asm.undocumented.touchdevice/blob/master/MultitouchSupport.h)
- [MiddleClick 触点监听与全部设备注册](https://github.com/artginzburg/MiddleClick/blob/main/MiddleClick/TouchHandler.swift)
