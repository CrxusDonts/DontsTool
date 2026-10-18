# 工具窗口 v2 设计稿

从 `index.html` 查看暖灰和石墨两个方向；也可直接打开 `linen.html`、`graphite.html`。

- Stitch 项目：https://stitch.withgoogle.com/projects/8779626504181051745
- 暖灰画面：`5f9443b9a7614a79b22f19902d56ea56`
- 石墨画面：`38315c157eb349a182970a914c891ec7`
- 参考来源与设计意图：`REFERENCES.md`
- 原始 HTML 与截图：项目根 `.stitch/designs/tool-workspaces-v2/`
- 生成结果及建议：项目根 `.stitch/tool-workspaces-v2.json`

本目录的 HTML 修正了原始导出中代码区多余空白、样例差异不一致及行号数量问题；内联编译后的 CSS，使用系统字体与内联 SVG，无 CDN、外部字体或运行时依赖。`*.png` 保留原始 Stitch 截图作溯源参考，HTML 是修正后版本。

这是视觉设计稿。主题切换、悬停与焦点样式可预览，工具动作尚未与原生程序连接。原生程序已实现对应的窗口与工具操作，实际行为以源码和原生验证记录为准；本稿本身不会执行工具转换。

## 最终交互收敛

用户进一步明确：启动器 → 选择工具 → 新独立窗口，每次执行都新开。`simple-linen.html` 与 `simple-graphite.html` 为去除额外窗口管理控件的版本；index 默认展示它们。`multi-*.html` 保留为已舍弃的窗口菜单/重命名浮层探索稿，不代表最终交互。
