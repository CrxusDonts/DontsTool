# DontsTool Fluid Launcher

用户授权自主迭代，参考 Alfred 的键盘工作流与 uTools 的内容动作入口；保留 SwiftUI/AppKit、独立具名多窗口和本机设置。本文中的实现取舍由本轮开发提出。

第一轮完成：应用目录自动更新；中文拼音、英文简称与文件名检索；应用默认按最近使用排序，可切换使用频率和名称；明确粘贴后附加内容并推荐真实工具动作；统一石墨/暖灰与薄荷绿视觉及短转场。外部应用激活只更新最近时间，不重复累计启动频率。

内容来自用户主动粘贴，搜索框为空时才接收为上下文。筛选词与原文分离，原文不传给全局搜索，不自动转换、不自动发送网络请求。Esc 依次关闭动作、清空动作筛选、移除内容；普通搜索 Esc 收起面板。关闭面板释放附加内容。外部插件运行时、市场、Schema 提取不在本轮展示或实现。

动效包括窗口 200ms/8pt 进入、110ms/4pt 退出，连续选中背景、附加内容和动作面板展开；不得延迟键盘可用时机。遵循减少动态效果和减少透明度；快速重开不能被旧关闭回调隐藏。不变换 SwiftUI hosting layer，以避免既往裁剪故障。

设计来源：Stitch 项目 8779626504181051745，复用石墨与暖灰工作台令牌；原始 HTML 和适配的可交互版本导出到 design/fluid-launcher。生成文案中的虚构能力需删除。
# Motion refinement after native feedback

The installed version felt less fluid than the HTML reference. The current display reports 160 Hz, while the first native window driver used a fixed 60 Hz timer. Use a window-bound CADisplayLink during transitions, request the screen's supported refresh range, and invalidate it after completion or cancellation. Keep the current no-layer-transform approach to avoid clipping the AppKit field editor.

Render one persistent selection surface behind the list using row anchors, matching the HTML's single translated background. Use the same cubic-bezier(.2,.8,.2,1), 160 ms selection glide, 140 ms palette expansion with a 4 pt offset and .985 scale, and subtle press feedback. Reserve the action column to prevent text moving as selection changes. Reduce Motion removes spatial transitions; input focus and search remain immediate.
