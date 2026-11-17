# 文件搜索超时与中文输入法验证

用户报告多次文件搜索超时，并指出拼音组词停顿不应触发防抖后的文件查询。

## 发现

- 原文件查询硬上限为 300ms，低于正常慢查询所需时间。真实子进程空闲采样为 37–132ms；全量回归时完整搜索链路为 300–1510ms。未取得用户之前的现场日志，不将所有历史超时归为同一原因。
- 原代码只在文本变化时检查 marked text，没有主动取消组词之前已排队的查询。
- `doCommandBy` 回调未检查 marked text，候选词方向键、回车和 Esc 可能触发启动器动作。
- 原进程取消可能发生在启动之前而被忽略；运行中取消返回普通结果，并被服务误报为失败。忽略 TERM 和 INT 的进程无法及时退出。

## 修改

- 保留已确认输入的 120ms 防抖；查询上限放宽为 2 秒，正常完成立即返回，超时继续保留部分结果。
- 取消前后均检查 Task 状态，已取消任务不启动进程；运行中取消和超时先发 TERM，200ms 后仍运行则发 KILL。
- 取消不设置“文件搜索不可用”，过期请求不修改新查询状态。
- `LauncherFieldEditor` 报告组合态开始与结束；组词开始立即取消旧查询、清掉旧可执行结果，底栏提示输入完成后搜索。
- 提交候选词后才重新计时；覆盖 unmarkText 和 insertText 的提交路径，忽略内部嵌套编辑的中间态。
- 组合期间外部刷新也不能重新发起旧查询，候选词按键交给输入法。

## 验证

- 慢查询、预取消、运行中取消、忽略终止信号的进程回归先出现八项失败，修复后通过。
- 使用真实 AppKit field editor 的 marked text 测试先出现十四项失败；修复后确认组词期间零查询，最终只查询“报告”，候选词按键不触发动作。
- Core 全量 450 项通过，bridge 全量 145 项通过，应用 Debug 构建成功，独立审查未发现重要问题。
- 再次以生产 FileSearchService 抽样，以下五次均正常完成、返回 12 项、timedOut=false：readme 175ms、swift 61ms、png 528ms、notes 41ms、config 136ms。未记录命中文件路径。
- 没有重建 Spotlight 索引。自动化使用真实 marked-text API，未将真人操作特定中文输入法候选窗口计为本次验收。

改动位于 `codex/file-search-timeout`，尚未安装、推送或发布。工作区原有的 ResultRowView.swift 和 LauncherPanelView.swift 改动保留，未纳入本次提交。

参考：[Apple hasMarkedText](https://developer.apple.com/documentation/appkit/nstextinputclient/hasmarkedtext())、[Apple didChangeText](https://developer.apple.com/documentation/appkit/nstextview/didchangetext())。
