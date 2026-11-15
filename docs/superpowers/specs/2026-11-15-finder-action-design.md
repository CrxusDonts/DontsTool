# Finder reveal entry

用户要在搜到文件后直接定位到访达。已有文件/路径结果的第二动作会调用 NSWorkspace.activateFileViewerSelecting，但菜单入口不明显。

保留回车打开文件，在选中或悬停文件行的右侧增加独立文件夹按钮，提示“在访达中显示（⌘Enter）”。按钮是主打开按钮的兄弟，避免嵌套按钮误执行打开。保留原有⌘K全部操作和⌘Enter第二动作，统一中文文案。通过现有 ResultRowView→onExecute(index,true) 调用原有动作，不新增取词权限、不重新开启普通文件查询。用户已授权本机安装与重启；不提交或推送现有混合修改。
