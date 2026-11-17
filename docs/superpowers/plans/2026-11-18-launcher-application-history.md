# Launcher Application History Implementation Plan

**Goal:** 最近应用仅按从启动器成功打开的应用计算。

**Spec:** `docs/superpowers/specs/2026-11-18-launcher-application-history-design.md`

1. 添加并运行失败测试，覆盖旧激活记录迁移、旧次数保留、迁移幂等、未使用应用排除和打开失败。
2. 删除 AppController 的系统激活历史订阅及 UsageStore.recordActivation；实现限定于应用路径的一次性历史迁移。
3. 最近排序仅接受 count > 0 的历史应用；保留搜索、频率和名称排序。
4. 执行 Core/bridge 测试和构建，更新 README、架构与验证记录。
5. 独立审查并提交到独立分支，保持先前分支，暂不安装、推送或发布。
