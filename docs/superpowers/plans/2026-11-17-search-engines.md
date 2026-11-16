# 可配置搜索引擎实现计划

**目标：** 在现有启动器中配置搜索引擎并用自定义快捷词调用。
**设计：** [设计说明](../specs/2026-11-17-search-engines-design.md)
**技术：** Swift 6、Foundation、Combine、AppKit、SwiftUI。
**约束：** 沿用设置 UI；保留网址 `gh` 接管。

- [x] 配置模型与存储：SearchEngineDefinition、SearchEngineConfiguration、SearchEngineStore；测试 URL 编码、校验、旧默认迁移、持久化和损坏恢复。
- [x] 路由与集成：WebSearchProvider 动态快捷词、默认回退、名称入口和空查询提示；设置变更即时更新；禁止已占用快捷词；移除旧硬编码搜索引擎模型。
- [x] 设置界面与验收：手动表单、启用／默认、JSON 编辑和复制；检查原生深浅色布局，运行核心及原生回归、完整应用构建。验证通过后统一提交和推送。

验证：418 项核心测试、125 项原生测试通过；arm64/x86_64 Release 构建通过。独立审查发现的默认入口空操作与 gh 所有权不对称问题均有 RED→GREEN 回归。日志位于忽略目录 `build/search-engines/`。
