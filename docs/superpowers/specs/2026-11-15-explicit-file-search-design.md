# Explicit file search

用户确认：普通输入不再搜索文件，仅 `file 关键词` 查询系统 Spotlight 文件名索引；直接输入完整路径仍由 QuickOpen 打开。保留现有文件搜索开关，关闭时关键词也不启动文件查询。复用现有关键词路由、120 ms 防抖、300 ms 查询预算、取消和超时提示；不改索引服务或网址分组路由优先级。

采用 Provider 的 supportsGlobalSearch 能力标识（默认 true，文件为 false），聚合层在全局模式排除文件 Provider，而非仅在结果中隐藏文件。FileProvider 同时校验目标关键词模式，避免直接调用绕过限制。`file` 无参数显示输入提示，不创建进程。设置和 README 同步说明按需搜索。用户已授权实现、本机安装和重启，不提交或推送现有混合改动。
