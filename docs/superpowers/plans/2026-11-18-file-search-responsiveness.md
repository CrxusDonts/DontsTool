# File Search Responsiveness Implementation Plan

**Spec:** `docs/superpowers/specs/2026-11-18-file-search-responsiveness-design.md`

1. 采样真实 mdfind，仅记录耗时、状态和结果数，不记录文件名。
2. 用慢进程、预取消、运行中取消和忽略信号的进程复现失败，修复查询预算和清理。
3. 用真实 AppKit field editor 复现组合态期间旧查询仍运行、候选词按键被拦截和提交无搜索。
4. 增加组合态开始/结束回调，取消旧查询，提交后恢复防抖；覆盖 unmarkText 与 insertText。
5. 执行完整 Core/bridge 回归、构建及独立审查，记录真实索引查询的验证边界。
6. 仅提交本次改动，保留原有界面工作区改动，暂不安装、推送或发布。
