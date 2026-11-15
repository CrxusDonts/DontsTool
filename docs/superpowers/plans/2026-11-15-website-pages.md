# Website Pages Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans and dispatch independent configuration, matching, and UI tasks; root integrates and verifies.

**Goal:** 通过 `ops avatar management prod` 快速打开系统的子页面与指定环境。

**Architecture:** v3 在现有系统中增加 pages；统一 URL 解析和校验，provider 展开首页与页面地址。原生表单和 JSON 共用原子保存。

**Tech Stack:** Swift 6, AppKit, SwiftUI, Swift Testing, XcodeGen。

**Spec:** [网站子页面设计](../specs/2026-11-15-website-pages-design.md)

## Global Constraints

旧v1/v2不自动重写；100页面/系统，5000最终地址与1MiB全局限制；仅显式执行打开网址；保留现有脏工作区。

## Review Focus

- 页面路径保留百分号、查询和片段，且不会继承基础地址的旧查询。
- 子页面名与环境名碰撞时命令结果明确，未命中不跳到首页。
- 系统别名含多个词、环境名跨系统重叠不抢匹配。
- 编辑基础环境后仍保留页面覆盖，显示错误而不静默删数据。
- 首页与子页面、不同环境的稳定ID不同，默认首页在先。

### Task 1: 配置与解析

- [x] JSON-only用例先复现旧实现拒绝pages；增加页面模型、v3解码与校验、公共resolvedURL(baseURL:environmentKey:)。
- [x] 覆盖旧版往返、路径组成、完整地址、覆盖缺失/无效、唯一性和数量限制。

### Task 2: 匹配与执行

- [x] JSON fixture先复现无页面结果；实现系统→页面→环境匹配、主页保留和独立结果ID。
- [x] 验证页面别名、环境前缀、无匹配、取消/禁用、无网络查询及精确打开。

### Task 3: 原生设置和设计参考

- [x] 页面草稿/表单、覆盖高级区域与JSON计数；扩展dirty/proposal测试。
- [x] 用Stitch编辑已有参考并导出HTML；生成真实Swift深浅色截图并检查布局。

### Task 4: 复查与安装

- [x] 独立review，修复阻断，运行受影响测试及必要最终回归。
- [x] Universal Release、本地稳定签名安装与进程/版本/哈希验证，记录锁屏下未完成的实机验收。

交付证据：[实现审查与实机验收](../../reviews/2026-11-15-website-pages.md)。
