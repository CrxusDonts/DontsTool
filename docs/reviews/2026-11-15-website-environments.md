# 网址多环境实现审查

范围：网址配置、匹配与打开动作、原生设置表单、结果环境标签、相关文档和设计参考。保留工作区中此前的其他功能改动；未提交或推送。

## 发现与处理

- 环境前缀 `pro` 没有筛选 `prod`；环境显示名可能抢占明确的 key。均先建立失败回归后修复。
- 不同系统的环境 key 精确匹配可能干扰当前系统的环境前缀匹配。增加跨系统回归，按当前系统决定环境优先级。
- 环境别名去重与搜索对连续空白的处理不一致。统一环境标识规范化，阻止语义相同的重复别名；旧版系统别名规则保持。
- 原生截图中重复的前缀/环境名称占用副标题宽度。多环境结果副标题改为实际 URL，环境 key 保留在标题旁徽标；悬停可查看完整地址。

## 验证

- 第一轮和第二轮 RED 通过实际 xcodebuild 复现；随后网址相关 31 项测试通过。
- 首次原生测试共 69 项，67 项通过；新增环境结果和设置页深浅色渲染、5 项表单草稿测试通过。两个既有显示帧动画测试等待超时；当前 Mac 锁屏、CUA 也报告无法解锁。尚未验证解锁后动效，未把这一轮报告为全绿。
- 独立复查确认上述两处 P2 已修复，无剩余阻断。最终 Core 全量 350 项 / 46 suites 通过（/tmp/dontstool-env-core-final.log）；包含全部新增环境回归。
- 最终受影响的 6 项原生测试通过（/tmp/dontstool-env-native-final.log），重新生成深浅色真实 Swift 视图截图。两个旧动画测试需解锁后另验，没有重复运行无关用例。
- 通用 Release 构建成功（/tmp/dontstool-env-release.log），arm64 / x86_64 均验证。
- 已沿用现有本地证书安装并启动 `/Applications/DontsTool.app`，版本 0.2.0 build 11；候选与旧安装 designated requirement 一致，安装文件逐个与候选进行 SHA-256 比对，严格签名检查通过。
- 安装后运行 PID 37857，实际可执行路径为 `/Applications/DontsTool.app/Contents/MacOS/DontsTool`；可执行文件 SHA-256 为 `7d578b5c2b8655f203ab680443d75264728bf12cfdefc4ae2bd93e3da8ada7d3`。
- 安装后再次 CUA 检查仍返回 Mac 锁屏。已记录界面验收阻挡，没有把进程启动等同于实际点击闭环。

## 实机验收边界

原生 NSHostingView 已生成实际 Swift 视图截图（build/launcher-previews/website-*.png），并目视检查布局。Stitch HTML 只作设计参考，全部示例为虚构 .example 站点；没有写入用户配置或访问公司站点。由于锁屏，尚未执行已安装应用中的配置点击、筛选与浏览器打开闭环。

[原生结果深色截图](assets/website-environments-dark.png) · [原生结果浅色截图](assets/website-environments-light.png) · [原生设置截图](assets/website-settings-dark.png)
