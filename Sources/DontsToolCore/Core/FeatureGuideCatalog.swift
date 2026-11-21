import Foundation

public enum FeatureGuideCategory: String, CaseIterable, Identifiable, Sendable {
    case shortcuts = "快捷键"
    case productivity = "效率工具"
    case textAndNotes = "文本与便笺"
    case searchAndSync = "搜索与同步"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .shortcuts: "command"
        case .productivity: "bolt"
        case .textAndNotes: "note.text"
        case .searchAndSync: "magnifyingglass"
        }
    }
}

public struct FeatureGuideShortcut: Equatable, Identifiable, Sendable {
    public let id: String
    public let keyCap: String
    public let title: String
    public let detail: String

    public init(id: String, keyCap: String, title: String, detail: String) {
        self.id = id
        self.keyCap = keyCap
        self.title = title
        self.detail = detail
    }
}

public struct FeatureGuideExample: Equatable, Identifiable, Sendable {
    public let id: String
    public let query: String
    public let label: String
    public let canTryInLauncher: Bool

    public init(query: String, label: String, canTryInLauncher: Bool = true) {
        self.id = "\(query)|\(label)"
        self.query = query
        self.label = label
        self.canTryInLauncher = canTryInLauncher
    }
}

public struct FeatureGuideEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let category: FeatureGuideCategory
    public let title: String
    public let summary: String
    public let symbol: String
    public let tint: IconTint
    public let keywords: [String]
    public let examples: [FeatureGuideExample]
    public let tips: [String]
    public let providerID: ProviderID?

    public init(
        id: String,
        category: FeatureGuideCategory,
        title: String,
        summary: String,
        symbol: String,
        tint: IconTint,
        keywords: [String] = [],
        examples: [FeatureGuideExample] = [],
        tips: [String] = [],
        providerID: ProviderID? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.tint = tint
        self.keywords = keywords
        self.examples = examples
        self.tips = tips
        self.providerID = providerID
    }

    public var tryQuery: String? {
        examples.first(where: \.canTryInLauncher)?.query
    }
}

public enum FeatureGuideCatalog {
    public static func shortcutRows(hotKeyDisplay: String) -> [FeatureGuideShortcut] {
        [
            FeatureGuideShortcut(
                id: "toggle",
                keyCap: hotKeyDisplay,
                title: "呼出 / 收起启动器",
                detail: "可在「通用」设置中修改为组合键或双击修饰键"
            ),
            FeatureGuideShortcut(
                id: "primary",
                keyCap: "↵",
                title: "执行主动作",
                detail: "打开应用、切换标签页、复制结果或打开工作台"
            ),
            FeatureGuideShortcut(
                id: "secondary",
                keyCap: "⌘↵",
                title: "执行次动作",
                detail: "访达定位文件、强杀进程、独立便笺等快捷动作"
            ),
            FeatureGuideShortcut(
                id: "actions",
                keyCap: "⌘K",
                title: "打开更多操作面板",
                detail: "查看当前选中条目的全部可用动作（如在终端打开、无痕打开、复制链接）"
            ),
            FeatureGuideShortcut(
                id: "copy-path",
                keyCap: "⌘⇧C",
                title: "复制文件路径",
                detail: "选中文件搜索或路径结果时，一键复制完整路径"
            ),
            FeatureGuideShortcut(
                id: "paste-content",
                keyCap: "⌘V",
                title: "粘贴内容直接处理",
                detail: "在搜索框粘贴 JSON、网址或大段文本，自动进入内容模式匹配格式化、翻译或新建便笺"
            ),
            FeatureGuideShortcut(
                id: "selection-translate",
                keyCap: "右键长按",
                title: "全局划词翻译",
                detail: "在任意应用选中文本后按住鼠标右键（需在「翻译」设置中开启并授权辅助功能）"
            ),
            FeatureGuideShortcut(
                id: "dismiss",
                keyCap: "Esc",
                title: "返回或关闭面板",
                detail: "依次关闭操作面板、清空附加内容或隐藏启动器并恢复原应用焦点"
            )
        ]
    }

    public static let entries: [FeatureGuideEntry] = [
        // MARK: - 效率工具
        FeatureGuideEntry(
            id: "chrome",
            category: .productivity,
            title: "Google Chrome",
            summary: "统一搜索已打开标签页、多 Profile 书签与浏览历史，支持切换、关闭标签页及新建无痕窗口。",
            symbol: "globe",
            tint: .blue,
            keywords: ["chrome", "ch", "tab", "tabs", "bm", "书签", "标签页"],
            examples: [
                FeatureGuideExample(query: "chrome ", label: "统一搜索标签页（优先）、书签与历史，含新建标签页/无痕窗口"),
                FeatureGuideExample(query: "tab ", label: "只搜索已打开的 Chrome 标签页，回车切换、⌘K 关闭"),
                FeatureGuideExample(query: "bm ", label: "只搜索全部 Chrome Profile 中的书签（支持按目录名筛选）")
            ],
            tips: [
                "按 ⌘K 可选择「关闭标签页」「在无痕窗口打开」「复制网址」或「复制 Markdown 链接」",
                "首次读取标签页需允许系统「自动化」权限；若拒绝，书签与历史仍可正常搜索"
            ],
            providerID: .chrome
        ),
        FeatureGuideEntry(
            id: "terminal-finder",
            category: .productivity,
            title: "终端与访达（Terminal Finder）",
            summary: "根据唤起前的应用自动双向跳转：访达目录一键进终端，Ghostty / Warp / iTerm2 / 终端目录一键进访达。",
            symbol: "terminal",
            tint: .teal,
            keywords: ["tf", "ft", "term", "终端"],
            examples: [
                FeatureGuideExample(query: "tf ", label: "在访达中呼出优先跳终端，在终端中呼出优先跳访达"),
                FeatureGuideExample(query: "tf otty", label: "指定用 Ghostty（或 warp / iterm）打开当前访达目录"),
                FeatureGuideExample(query: "tf ~/Desktop", label: "直接在默认终端中打开指定路径（⌘K 可切换其他终端）")
            ],
            tips: [
                "可在「工具 → 终端与访达」固定默认终端，默认「自动」优先选择当前正在运行的终端",
                "文件搜索（file）、快速打开路径、IDEA 项目的 ⌘K 菜单均已打通「在终端中打开」"
            ],
            providerID: .terminalFinder
        ),
        FeatureGuideEntry(
            id: "kill-process",
            category: .productivity,
            title: "结束进程（Kill Process）",
            summary: "按进程名、PID、启动命令或占用端口查找运行中的进程，一键优雅结束或强制结束。",
            symbol: "xmark.octagon",
            tint: .red,
            keywords: ["kill", "kp", "进程"],
            examples: [
                FeatureGuideExample(query: "kill ", label: "按内存占用降序列出用户进程，实时查看内存/CPU 徽章"),
                FeatureGuideExample(query: "kill :3000", label: "按 :端口号 精确查找监听该端口的进程并一键释放"),
                FeatureGuideExample(query: "kp node", label: "按名称或命令行筛选，⌘K 可强制结束 (SIGKILL) 或结束全部同名进程")
            ],
            tips: [
                "回车默认发送 SIGTERM 优雅退出，⌘↵ 直接发送 SIGKILL 强制结束；结束进程后列表自动刷新",
                "为避免误伤，会自动保护系统关键进程与 DontsTool 自身"
            ],
            providerID: .killProcess
        ),
        FeatureGuideEntry(
            id: "idea-projects",
            category: .productivity,
            title: "IDEA 项目",
            summary: "读取 IntelliJ IDEA 最近打开的项目列表，支持模糊筛选并直接用 IDEA 或终端打开。",
            symbol: "folder.badge.gearshape",
            tint: .purple,
            keywords: ["idea"],
            examples: [
                FeatureGuideExample(query: "idea ", label: "列出最近打开的 IntelliJ IDEA 项目"),
                FeatureGuideExample(query: "idea server", label: "按项目名或路径片段筛选并直接打开")
            ],
            tips: [
                "按 ⌘K 可选择「在访达中显示」「复制路径」或「在终端中打开」"
            ],
            providerID: .ideaProjects
        ),
        FeatureGuideEntry(
            id: "quick-ai",
            category: .productivity,
            title: "AI 快问（插件）",
            summary: "复用宿主「模型服务」配置（支持 OpenAI Responses、Gemini 原生与 OpenAI Chat Completions，可按场景单独绑定），在原生流式窗口中即时问答、解释代码与排查报错。需从官方插件仓安装 com.donts.quick-ai。",
            symbol: "sparkles",
            tint: .blue,
            keywords: ["ai", "ask", "问"],
            examples: [
                FeatureGuideExample(query: "ai ", label: "新建 AI 对话或选择解释代码、排查报错、润色改写等预设场景"),
                FeatureGuideExample(query: "ai fix ", label: "按「排查报错」场景分析异常日志并流式给出建议"),
                FeatureGuideExample(query: "ai Swift 6 Sendable 怎么用", label: "直接发起提问并在原生流式窗口中查看实时回答")
            ],
            tips: [
                "请在「设置 → 插件」从官方插件仓（CrxusDonts/DontsTool-Plugins）安装「AI 快问（com.donts.quick-ai）」",
                "在「设置 → 模型服务」添加模型配置并绑定到 AI 快问即可使用；密钥仅存于宿主钥匙串，不会暴露给插件"
            ],
            providerID: nil
        ),
        FeatureGuideEntry(
            id: "calculator",
            category: .productivity,
            title: "计算器与单位换算",
            summary: "在搜索框直接输入数学表达式、进制或常见单位换算，实时预览结果，回车即复制。",
            symbol: "equal.square",
            tint: .green,
            keywords: [],
            examples: [
                FeatureGuideExample(query: "(128 + 64) * 3", label: "四则运算、括号与幂运算，实时给出结果"),
                FeatureGuideExample(query: "5 km to m", label: "支持长度、重量、温度、存储容量等单位换算")
            ],
            tips: [
                "无需输入任何前缀关键词，直接输入算式即可触发"
            ],
            providerID: .calculator
        ),

        // MARK: - 文本与便笺
        FeatureGuideEntry(
            id: "notes",
            category: .textAndNotes,
            title: "本地便笺与速记",
            summary: "离线所见即所得便笺工作台，支持 Markdown、代码块、粘贴图片、置顶、回收站与今日速记。",
            symbol: "note.text",
            tint: .amber,
            keywords: ["note", "便笺"],
            examples: [
                FeatureGuideExample(query: "note ", label: "浏览最近便笺，回车新建空白便笺"),
                FeatureGuideExample(query: "note 明天同步版本发布计划", label: "无匹配时回车直接追加到「今日速记」，⌘↵ 新建独立便笺")
            ],
            tips: [
                "选中已有便笺按 ⌘K 可复制纯文本/Markdown、列表置顶或移入最近删除",
                "开启云同步后，本地便笺与图片附件会自动跨设备双向同步"
            ],
            providerID: .notes
        ),
        FeatureGuideEntry(
            id: "text-tools",
            category: .textAndNotes,
            title: "开发文本工具箱",
            summary: "内置 JSON 格式化/折叠对比、Base64、URL 编解码、时间戳转换、UUID 批量生成与 MD5/SHA 哈希工作台。",
            symbol: "curlybraces",
            tint: .amber,
            keywords: ["json", "b64", "b64d", "url", "urld", "ts", "uuid", "md5", "sha256"],
            examples: [
                FeatureGuideExample(query: "json ", label: "打开 JSON 工作台（格式化、压缩、转义、折叠与 Diff 对比）"),
                FeatureGuideExample(query: "b64d aGVsbG8=", label: "直接带入内容进入 Base64 解码模式（urld 同理）"),
                FeatureGuideExample(query: "ts 1767225600", label: "时间戳与日期时间双向转换，支持秒与毫秒")
            ],
            tips: [
                "在搜索框直接粘贴（⌘V）JSON 或长文本，会自动弹出对应的格式化/编解码入口",
                "已打开的工具窗口可继续在全局搜索中按标题快速切回"
            ],
            providerID: .text
        ),
        FeatureGuideEntry(
            id: "translation",
            category: .textAndNotes,
            title: "翻译与全局划词翻译",
            summary: "支持 OpenAI Responses、Gemini 原生与 OpenAI Chat Completions 三种大模型接口格式，提供工作台多语言互译与全局鼠标右键长按划词翻译。",
            symbol: "character.bubble",
            tint: .teal,
            keywords: ["tr", "translate"],
            examples: [
                FeatureGuideExample(query: "tr hello world", label: "直接把原文送入翻译工作台并开始翻译"),
                FeatureGuideExample(query: "tr ", label: "打开独立翻译窗口，自由切换目标语言并复制译文")
            ],
            tips: [
                "API 密钥保存在 macOS 钥匙串中，不写入配置文件或日志，可在「设置 → 模型服务」为翻译单独绑定模型",
                "可在「设置 → 翻译」选择目标语言、开启「右键按住划词翻译」并调整触发时长"
            ],
            providerID: .translation
        ),

        // MARK: - 搜索与同步
        FeatureGuideEntry(
            id: "apps-and-recent",
            category: .searchAndSync,
            title: "应用搜索与最近工具",
            summary: "支持应用英文名、中文名、全拼与首字母极速搜索；首页顶部展示最近打开的应用与最近使用的工具。",
            symbol: "square.grid.2x2",
            tint: .blue,
            keywords: [],
            examples: [
                FeatureGuideExample(query: "wx", label: "支持中文拼音首字母与模糊匹配（如 wx → 微信）"),
                FeatureGuideExample(query: "", label: "空查询首页自动按最近使用顺序排列应用与 4×2 工具网格")
            ],
            tips: [
                "点击首页「最近打开 ⌄」可切换按「最近打开 / 使用频率 / 名称」排序",
                "选中应用按 ⌘K 可执行「在访达中显示」「退出应用」或「复制路径」"
            ],
            providerID: .app
        ),
        FeatureGuideEntry(
            id: "file-and-quickopen",
            category: .searchAndSync,
            title: "文件搜索与快速打开",
            summary: "通过 file 显式触发 Spotlight 文件搜索保持日常查询极速；直接输入网址或 ~/ 路径可一键直达。",
            symbol: "doc.text.magnifyingglass",
            tint: .sky,
            keywords: ["file", "open"],
            examples: [
                FeatureGuideExample(query: "file ", label: "显式触发本机 Spotlight 文件搜索（⌘↵ 访达定位，⌘⇧C 复制路径）"),
                FeatureGuideExample(query: "~/Desktop", label: "直接输入绝对路径或网址，回车打开、⌘K 可在终端打开")
            ],
            tips: [
                "普通查询不触发 Spotlight，确保每次按键即时响应"
            ],
            providerID: .file
        ),
        FeatureGuideEntry(
            id: "websites-and-web",
            category: .searchAndSync,
            title: "网址快捷入口与搜索引擎",
            summary: "自定义多环境网址分组（如 prod / test / dev）与专属搜索引擎关键词，未命中本地结果时自动回退默认搜索引擎。",
            symbol: "link",
            tint: .orange,
            keywords: [],
            examples: [
                FeatureGuideExample(query: "https://github.com", label: "直接输入网址即可打开或复制链接", canTryInLauncher: true)
            ],
            tips: [
                "在「网址快捷入口」和「搜索」标签页可添加自定义关键词，且自动优先于内置工具关键词"
            ],
            providerID: .web
        ),
        FeatureGuideEntry(
            id: "cloud-sync",
            category: .searchAndSync,
            title: "云同步与本地备份",
            summary: "通过自建 Cloudflare Worker + R2 同步设置、网址快捷入口、搜索引擎与本地便笺，并支持完整本地导出/恢复。",
            symbol: "icloud",
            tint: .blue,
            keywords: [],
            examples: [
                FeatureGuideExample(query: "help 同步", label: "在启动器输入 help 加关键词随时速查功能说明")
            ],
            tips: [
                "在「同步与备份」填入同步地址与密钥即可启用跨 Mac 自动同步，本地备份文件可随时离线恢复"
            ],
            providerID: nil
        )
    ]

    public static func entries(
        in category: FeatureGuideCategory? = nil,
        matching query: String = ""
    ) -> [FeatureGuideEntry] {
        let scoped = category.map { target in entries.filter { $0.category == target } } ?? entries
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return scoped }

        let lower = trimmed.lowercased()
        let scored: [(entry: FeatureGuideEntry, score: Double)] = scoped.compactMap { entry in
            var best: Double?
            func consider(_ candidate: String, weight: Double) {
                if candidate.lowercased().contains(lower) {
                    best = max(best ?? 0, weight + 400)
                } else if let fuzzy = FuzzyMatcher.score(query: trimmed, candidate: candidate) {
                    best = max(best ?? 0, weight + min(fuzzy, 300))
                }
            }

            consider(entry.title, weight: 1000)
            for keyword in entry.keywords {
                consider(keyword, weight: 950)
            }
            consider(entry.summary, weight: 700)
            for example in entry.examples {
                consider(example.query, weight: 850)
                consider(example.label, weight: 650)
            }
            for tip in entry.tips {
                consider(tip, weight: 500)
            }
            consider(entry.category.rawValue, weight: 400)

            guard let best else { return nil }
            return (entry, best)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.title.localizedStandardCompare(rhs.entry.title) == .orderedAscending
            }
            .map(\.entry)
    }
}
