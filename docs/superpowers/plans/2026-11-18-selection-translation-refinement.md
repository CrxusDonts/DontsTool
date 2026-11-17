# Selection Translation Refinement Implementation Plan

> **For agentic workers:** Use native execution in this chat. The user has specified the required behavior; implement the small change directly.

**Goal:** 无文字不弹面板，单词提供词性与常见多义释义。

**Spec:** `docs/superpowers/specs/2026-11-18-selection-translation-refinement-design.md`

1. 更新真实窗口回归测试，先确认读取/失败和空白文本仍错误地显示面板。
2. 修改 SelectionTranslationController 的读取和失败展示路径，保留固定译文、取消及诊断，更新视图移除无效取词状态。
3. 修改 RemoteTranslationService 提示词，区分词典查询和语境翻译，不增加脆弱的语言/单词启发式判断。
4. 执行 Core/bridge 全量测试及应用构建，检查长释义在现有滚动区域渲染。
5. 记录验证边界；在新分支提交，保留上一更新器分支，不推送或发布。
