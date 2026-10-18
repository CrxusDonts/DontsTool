# 网址快捷入口实现与审查

## 范围

沿用用户已确认的设计：可配置前缀加项目简称（如 `gh a`），回车打开完整配置的网址；前缀列出组内条目，名称/别名过滤。支持手动表单和 JSON 编辑/导入/导出，两种方式共用一份本机持久化数据。只允许自定义 `gh` 覆盖对应内置网页搜索，其他功能前缀保留；不引入脚本、模板或云同步。

## 实现边界

- Core `WebsiteShortcutConfiguration` 负责版本化 JSON、未知字段检查、HTTP(S) 网址、重复与容量校验。
- `WebsiteShortcutStore` 在完整验证后一次提交 UserDefaults；加载失败保留原始文本。所有 UI 保存都走相同入口。
- `WebsiteShortcutProvider` 是本地快速 Provider，动态关键词注册，执行动作才调用现有 `URLOpening`。网址分组独立于内置网页搜索的开关，优先级接管 `gh`；未命中没有公共网页回退。独立结果分组避免网页搜索的单结果上限截断项目列表。
- App 组合层注册 Store/Provider，将 Store 注入设置，并在配置更改后刷新启动器。
- 设置沿用原生 820×620 窗口，JSON 使用模态编辑器保护草稿，复用现有 `ToolTextEditor` 的纯文本、Undo、查找和语法属性。Stitch HTML 是设计参考，最终运行的是 SwiftUI/AppKit。
- `LauncherPanelModel` 按原始查询变化重置选中项，同一查询刷新保留用户选择，避免显示首条精确匹配却执行旧行。

## 审查修复

独立只读代码复审指出两项 P2，均补充 RED → GREEN 回归：

1. 变更查询仍保留旧选择，会打开另一个项目。现在变更查询重置首条，原查询刷新不重置。
2. 通用模糊匹配会去除重音，把 `a` 与 `á` 都视为精确匹配。现在精确判断使用与去重相同的大小写/宽度归一化，模糊分数仅作后续排序。

另修复了简称精确命中与他项显示名称精确命中的排序冲突，以及 `aliases:null` 被静默当作空数组。最终独立复查未发现剩余确认的 P1/P2。

## 自动验证

- `/tmp/dontstool-shortcuts-final-tests.log`：203项 Core 测试、30个套件通过，含13项新功能测试（其中一个参数化覆盖10份无效配置）。
- `/tmp/dontstool-shortcuts-review-red.log`：上述两项复审发现的失败证据；最终全量运行已转绿。
- Debug 与 Release 构建通过。环境仅有已有的 Simulator 版本和未使用 AppIntents 元数据提示。
- `/tmp/dontstool-shortcuts-bridge-tests.log`：7项真实 WebKit/窗口桥接集成测试通过。退出 WebKit 测试进程时有已有的 RBS assertion 环境提示，测试结果成功。
- Release 签名严格校验通过，打包产物 `build/DontsTool-0.1.0.zip`。可执行文件 SHA256：`d2b0cb715c8a62cbce34b54a401e9596ce15fdf4e22571bf0bf203aa271dead3`。

## 原生界面检查

独立 bundle ID `com.donts.DontsTool.ShortcutReview` 的测试副本使用虚构域名，未修改日常安装版的真实网址配置。

CUA 已实际验证空状态、手动添加分组、内置 json 前缀阻止保存、手动添加网址和中文别名、手动修改同步到 JSON、错误 JSON 禁用保存。后续界面操作期间检测到用户切换/操作应用，暂停交互；其余检查与交付状态追加于后文。未访问公司站点。


## 本机安装状态

新 Release 已复制到 `/Applications/.DontsTool-shortcuts-next.app` 并通过签名与构建 SHA256 一致性校验，旧安装包已备份。当前 `/Applications/DontsTool.app` 的旧进程仍运行，尚未替换。CUA 多次连接旧进程超时，未强制结束它，以保护可能存在的内存草稿。已请用户正常退出后继续完成原位替换和启动。记录在 `/tmp/dontstool-shortcuts-install.json`。

独立原生验收副本、临时 HTTP 测试服务器均已停止。没有完成真实浏览器跳转、系统文件选择器导入/导出的端到端界面验收；核心动作 URL、持久化、JSON 往返和整份拒绝已由自动测试验证。额外读取隔离副本偏好文件确认手动保存的前缀、中文别名及完整网址正确落盘，未读取日常安装版的网址数据。


### 用户要求重试后的安装结果

已重新尝试按完整路径、应用名连接及通过修饰键交互唤起，CUA 仍超时。未强制结束旧进程。

确认新旧 bundle 仅 `Contents/MacOS/DontsTool` 不同，其余资源与签名资源封套逐文件一致后，将旧 bundle 整体保留至安装备份目录，再安装已校验的新 bundle。没有原地修改旧进程映射的可执行文件；旧进程及内存窗口保留。`/Applications/DontsTool.app` 新二进制 SHA256 与上述 Release 一致，`codesign --verify --deep --strict` 成功，LaunchServices 已重新注册。当前为“新版已安装、旧进程仍运行、待正常退出后重开”，不能声称新版已启动。状态见 `/tmp/dontstool-shortcuts-install.json`。


### 新版启动验证完成

用户再次要求重试时，确认旧进程已退出。已启动 `/Applications/DontsTool.app --show-settings`，确认唯一运行进程的可执行映射来自该安装目录，文件 SHA256 与前述 Release 一致，签名严格校验通过。

CUA 成功连接新版，实际点击「网址快捷入口」，确认添加分组、JSON 配置、导入、导出及 JSON 示例入口均显示。保持该页面打开供用户配置，没有写入虚构网址。截图：`assets/website-shortcuts-installed.jpg`。安装状态已更新为 restartPending=false、installedUIVerified=true。
