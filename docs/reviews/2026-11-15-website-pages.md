# 网站子页面实现审查与验收

实现范围：系统 → 子页面 → 环境、v3 配置与 URL 解析、原生表单与 JSON、兼容旧版配置。现有其他未提交工作保持。设计参考见 [离线 HTML](../../design/website-pages/index.html)。

## 审查与修复

- 独立审查发现一处 P2：手动编辑环境 key 只有大小写变化时，覆盖编辑器与 Core 规范化不一致，可能新增重复覆盖而阻止保存。提取统一 trim/lowercase/去重函数，先观察新增回归失败，再修复并通过。
- 子页面和环境匹配、明确无匹配、根路径/完整网址/环境覆盖、编码及片段、稳定结果标识、模式切换与草稿保留复查未见剩余阻断。
- 旧版 `empty.version` 断言从2更新为3，旧v1/v2数据的 round-trip 与匹配回归仍保留。

## 自动验证

- Core：380项，48 suites全部通过，日志 `/tmp/dontstool-pages-core-final.log`。
- Native：78项，11 suites全部通过，日志 `/tmp/dontstool-pages-native-final.log`。本次机器可交互，两个此前锁屏超时的显示帧动画测试也通过。
- Universal Release构建成功（arm64/x86_64），日志 `/tmp/dontstool-pages-release.log`。
- 实际 Swift/AppKit/SwiftUI 视图生成深浅色截图，并目视检查输入框、结果徽标、完整示例URL、滚动表单和固定按钮。

## 安装后实机验收

使用临时 `qapagesd7bad` 分组和公开 example.com/example.org 地址，通过真正的 JSON 编辑器保存，再打开原生系统编辑表单修改页面路径，并填写 prod 环境特殊完整地址。

- `qapagesd7bad avatar` 展示两个首页和两个管理页，首页排前。
- `qapagesd7bad avatar management` 展示两种环境。
- `qapagesd7bad avatar management prod` 精确展示生产页面特殊地址。
- `qapagesd7bad avatar missing prod` 显示无匹配，没有首页或公共搜索回退。
- 页面别名 `managment` 同样命中；回车后默认 Edge 打开 `https://example.com/#dontstool-avatar-management-override`，浏览器当前URL和Example Domain页面均确认。

随后关闭验收网页，并通过 JSON 编辑器恢复原来的空网址配置，界面显示0分组/系统/页面/地址；没有留下虚构公司配置。此次没有验证真实公司域名的VPN、登录或页面权限。

## 本机产物

`/Applications/DontsTool.app` 版本 **0.2.0 build 12**，当前运行PID 46188。沿用已有本地证书，候选与旧版 designated requirement 一致；安装文件与候选逐文件比较，严格签名检查通过。可执行文件SHA-256：`9660754d7275a2d6cf9c49de2f5a9eb3894483de03c159176192afc41e45f414`。

[深色结果](assets/website-pages-dark.png) · [浅色结果](assets/website-pages-light.png) · [系统候选](assets/website-pages-list-dark.png) · [滚动表单](assets/website-pages-form-dark.png)
