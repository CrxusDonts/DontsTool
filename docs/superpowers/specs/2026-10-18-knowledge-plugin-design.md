# DontsKb 官方插件

用户于 2026-10-18 确认：正式知识库文章编辑，接受知识库插件使用 WKWebView，启动器继续原生，并明确授权实现。复用 DontsKb 收集与编辑功能；本次不搭建第三方插件市场。

## 使用流程

启动器新增知识库、收集箱、快速收集三个入口。`kb 关键词` 查找文章；工作窗口内默认从搜索进入文章并在原窗编辑，返回搜索保留关键词。仅明确选择“新窗口打开”才创建另一篇文章窗口，可分别置顶。`inbox` 打开收集箱，`collect 文字` 预填收集编辑器，提交前不创建服务器记录。图钉、原生标题栏和关闭行为沿用工具窗口习惯。

正式文章使用现有 DocumentPage / DocumentEditor / useDocumentEditingSession，保留表格、代码、图片、链接、草稿恢复、保存状态与修订冲突。插件采用精简外壳，不缩放整个桌面工作区。知识库草稿依照原有持久化机制，不能套用本地文本工具退出丢弃的策略。

## 两侧边界

DontsTool 的 KnowledgeProvider 只提供入口与文章搜索。KnowledgeWindowManager 管理 WKWebView、原生窗口、置顶、可信导航和关闭协调；设置只保存服务 origin。知识库登录发生在同源 Web 插件内，不向启动器暴露登录凭据。所有插件 WebView 共用默认 WKWebsiteDataStore，利用现有同源认证、锁和草稿会话机制。

DontsKb 新增 `/tool?mode=search|editor|inbox|capture&documentId=…&blockId=…&q=…`。已有 API 不变，Web 页面复用现有认证客户端。任意收集原文不放 URL，由准备就绪后的单次 RPC 预填。未登录时沿用登录流程；服务器尚未部署插件路由或协议不匹配时明确提示连接失败，不假装已接入。

## 原生桥协议 v1

可信主框架调用 `window.webkit.messageHandlers.dontsTool.postMessage`：

- `{type:'ready',version:1}`：插件和 RPC 已注册。
- `{type:'title',title}`：同步原生窗口标题。
- `{type:'authChanged'}`：登录边界变化，仅重载隐藏搜索桥，不携带凭据。
- `{type:'openDocument',documentId,title?,blockId?}`：显式新窗口操作，打开独立文章窗口；普通点击只在 Web 当前路由跳转。
- `{type:'appearance',scheme:'light'|'dark'}`：同步实际正文主题与原生窗口外观；WebView 的系统主题来源与窗口外壳独立，避免反馈循环。

原生使用序列化参数调用 `window.dontsToolPlugin.request(object)`：

- `{type:'search',query}` → `{authenticated,items:[{id,title,excerpt?}]}`，最多8项。
- `{type:'prepareClose',lock?:true}` → `{canClose}`，先运行现有文章／收集 departure guards。
- `{type:'prefillCapture',text}` → `{applied}`，已有非空草稿不得无提示覆盖。
- `{type:'resumeInteraction'}`：退出取消后恢复已锁定页面；全局退出的 `prepareClose` 用 `lock:true`，通过后锁定交互。

桥消息验证主框架和已配置 origin，不接受任意导航页面的指令；外部 HTTP(S) 链接在系统浏览器打开，禁止 file/javascript/任意自定义协议与弹出窗口接管宿主。请求具有期限，关闭握手失败保留窗口并提供重试。退出应用先协商各窗口安全离开，不无条件销毁未确认草稿。

## 验证与交付

Core 测试入口、URL和消息边界、分组与禁用行为；原生验证连接、置顶、加载与错误状态。Web 针对桥调用、登录边界、搜索跳转、关闭 guard 做单测和隔离模拟浏览器验证，保留既有保存机制的回归。执行 Web 类型检查／受影响测试和 DontsTool 完整测试／Debug／Release。真实服务上线属于独立发布授权；本次不提交、推送、部署或操作真实知识库内容。

## 2026-10-18 交互收敛

用户看到实际多窗口后明确确认：默认同窗，只在明确选择新窗口时多开，文章去掉首页导航。原生品牌/域名栏删除，置顶、重连、设置移到标准标题工具栏；窗口按屏幕可用尺寸收敛，保留正常 resize。保存、收集、队列和关闭保护不变；同窗导航复用原有 guard，已确认正文链接不再二次询问。
