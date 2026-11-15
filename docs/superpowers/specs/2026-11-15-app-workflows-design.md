# Application workflows

用户授权一起实现划词翻译修复、Gemini新对话、IDEA项目启动，并允许直接安装重启。继续原生SwiftUI/AppKit与现有启动器。IDEA与Gemini仅关键词路由（idea、gm/gemini），普通搜索不增加文件/项目扫描。翻译只保留译文卡片。

## IDEA

读取已安装IDE当前版本最近项目配置，后台解析、签名缓存、过滤不存在/远程目录；idea空参列最近、带参模糊过滤，完整目录允许手动打开。调用官方本地启动方式传递项目路径，不用辅助功能或IDE插件。窗口行为交给IDE。独立provider与discover/launcher边界由idea_projects_impl负责。

## Gemini

本机AskGemini AppIntent无问题参数。静态发现本版本googlegemini://newchat，需实机验证；不猜prompt参数。输入gm问题，明确回车后打开已安装Gemini并新建、核对空白会话、填入、验证文本、按提交。AX写入/按键属于可选授权能力，基础打开不强制授权。缺权限给出明确反馈与只打开Gemini的次动作。

AppKit接入层使用指定applicationURL，防止挂载DMG同bundleID歧义。AX访问在actor后台，限定目标PID/窗口和控件；不盲Return，不写旧会话，不覆盖已有草稿，用户切应用/取消/文本验证失败立即终止，不重复提交。问题不进日志、URL或剪贴板。仅安全固定测试问题用于Gemini实机验收。

Core边界GeminiAppControlling(open/newConversation/readComposer/setPrompt/submit)，GeminiConversationService负责准备状态验证与失败关闭。provider仅生成操作，不逐字发送问题，不接API密钥。

## Translation

取词不再受250ms必须完成的门限约束。先满足连续右键两秒，再执行有界取词；小于两秒还原原菜单，拖动/滚动/修饰键/焦点变化取消。AX选区解析可注入，保持密码框、跨窗口与长度约束；取词失败显示译文卡片内明确原因。仍不模拟复制、不轮询剪贴板、不做OCR。必须实机核实卡片/网络及短按行为，单元测试不等同硬件已验收。

## Delivery

新增Provider启用迁移仅执行一次，保留原禁用设置；设置显示gm/idea用法与权限边界。统一Core/Native测试、独立代码review、Universal Release、本地稳定证书签名、安装字节校验、CUA实机验收。不在本轮提交推送或发布公共Release。保留工作区其他改动。


## 翻译服务补齐

本机未配置翻译API。已异步询问系统翻译/继续自配API，等候超过60秒未答后明确按系统默认实施，API保留可选：完整remote配置优先，否则系统；失败不回退。使用macOS26 TranslationSession(installedSource:target:)只翻已安装语言；语言包准备是独立显式按钮，通过SwiftUI translationTask取得允许下载的session，不把headless prepare当下载。每个请求独立session与取消，26.4起显式lowLatency。界面验收因Mac锁屏待用户手动解锁。
