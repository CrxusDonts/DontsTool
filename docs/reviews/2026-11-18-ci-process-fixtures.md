# CI 子进程测试超时

CI [44134835842](https://github.com/CrxusDonts/DontsTool/actions/runs/44134835842) 中，450 项 Core 测试只有 `ordinaryHalfSecondQueryFinishesWithoutFalseTimeout` 失败：运行约 2 秒后没有得到预期文件，并报告超时。

该测试通过 `/usr/bin/python3` 启动解释器，再等待 500ms。进程启动也占用生产代码的 2 秒查询预算，因此它同时依赖解释器启动速度。CI 系统日志中，对应 Python 进程从 17:17:20.998 到 17:17:23.023 UTC 一直存在，直到查询期限结束；不能将这个夹具的 500ms 等待当成整个进程的耗时。

慢查询改用系统 `/bin/sh`、`/bin/sleep` 和 `printf`。取消及强制终止测试也使用原生进程；忽略 TERM/INT 后用 `exec` 启动 sleep，并断言最终终止信号是 SIGKILL。保留真实进程、启动标记和取消测试，没有修改应用查询期限，也没有增加重试来掩盖失败。

验证：26 项相关测试各重复 10 次通过；全量 Core 450 项、原生集成 145 项通过。独立代码审查未发现待修复问题。线上 CI 和发布流程仍需验证同一提交。
