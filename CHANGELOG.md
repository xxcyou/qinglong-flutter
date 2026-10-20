# 更新日志

## v1.1.0+2（正式版）

首个正式版主线版本，在 v1.0.0 基础上合入 100+ 次提交。

### 系统级悬浮窗
- 基于 `TYPE_APPLICATION_OVERLAY` 的 APP 外悬浮窗，桌面/其它 APP 上层可用。
- 主 Activity 与悬浮窗服务共享同一个 FlutterEngine、Dart isolate 和 Riverpod 状态。
- 覆盖 AI 球、AI 对话、浏览器、终端、SSH、容器日志/文件、画布、快速提问、附件等全部浮窗。
- 桌面 ↔ APP 切换不中断任务、不丢会话，修复“切回 APP 误报任务中断”。
- 修复悬浮内容闪烁、流式输出不自动跟随、滚动跳位、容器窗只显示一半等问题。
- 悬浮窗并集 bounds 上报、IME 跟随、旋转/分屏/服务回收后的窗口重建。

### AI 与本地工具
- 修复 `shell_modify_range` 多行替换会把 content 与下一行粘连的问题，按原换行风格逐行拼接。
- 自动识别 UTF-8 / UTF-16 LE/BE / GBK 并保留 BOM；`shell_search_code` / `shell_read_range` / `shell_modify_range` 的字节偏移按真实编码计算。
- 修复 `script_search_code` 按文件数而不是匹配行数计上限的问题。
- 过程卡防卡死：内联最多 30 行 / 20 个流程步骤；完整过程页 `ListView.builder` 懒加载。
- 单条消息事件上限 400、实时事件上限 300，落盘和启动读取时自动压缩，重启不再重渲染几千张卡片。
- 增强 Markdown 补齐 `gold` / `amber` 颜色，支持 `**{c:gold}重要结论{/c}**` 加粗套色和 `{c:cyan}时间节点{/c}`。

### 设置与文档
- 新增“关于”页：动态版本信息、项目说明、GitHub 开源地址，一键复制/打开。
- 更新 README 功能清单、系统悬浮窗说明、API 兼容文档和主题开发文档。
- 同步 `docs/qinglong_SKILL.md` 至当前运行时技能提示。
- 正式版移除预览分支自动化 hook `qinglong_preview_enter_external`。

### 青龙接口兼容
- 接口按面板版本缓存，切换面板自动复用同版本适配。
- 新版 `/scripts/detail`、`/logs/detail` 自动适配，旧版 404/410 自动回退。
- 接口适配插件支持热更新，插件写错时自动回退内置接口。
- 脚本接口兼容多版本返回结构（data/tree/children/list），成功码同时接受 0 和 200。

## v1.0.0+1

- 首个公开发布版本：青龙面板管理、本地 Debian、内置浏览器抓包、AI Agent。
