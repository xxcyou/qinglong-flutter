# 青龙面板 Flutter 客户端（含青龙专用 AI）

一个跑在 Android 手机上的 **青龙面板管理端 + 本地 Linux（PRoot Debian）+ 通用 AI Agent**。
不只是一个面板客户端，还是一个带着青龙工具、本地终端、浏览器内核、MCP、记忆和技能的随身 AI。

## 当前功能

### 面板管理
- 多面板：增删改、默认面板、一键切换
- 登录：账号密码 / OpenAPI Token
- Token 持久化、重启免登录、401 自动重登
- BaseURL / 自签名 HTTPS 开关

### 青龙核心业务
- **定时任务**：列表 / 搜索 / 筛选 / 分页 / 运行中轮询、新建 / 编辑（cron 实时校验、下次执行预览）、批量运行 / 停止 / 启用 / 禁用 / 删除、日志实时追更
- **脚本管理**：文件树 / 搜索 / 新建 / 上传 / 在线代码编辑器 / 运行 / 停止
- **环境变量**：搜索 / 状态筛选 / 新增 / 编辑 / 批量启停删
- **配置管理**：配置文件查看 / 编辑 / 保存，auth.json 敏感提示
- **依赖管理**：NodeJs / Python3 / Linux 三类型，安装 / 卸载 / 重装
- **日志中心**：日志文件列表 / 搜索 / 查看 / 复制 / 刷新
- **订阅管理**：订阅增删改、拉取、日志、私有仓库提示
- **系统管理**：版本信息、日志清理频率、更新按钮（二次确认）

### 本地 Linux（PRoot Debian）
- 手机上的 Debian 环境（Coomi Runtime V2）
- 一键下载 / SHA-256 校验 / 解包 / 激活
- xterm 终端：实时输入输出、停止、危险命令沙箱拦截
- APP 与 AI 共享同一份 `/workspace` 文件系统

### AI Agent
- **多提供商 LLM**：任意 OpenAI 兼容端点，每家独立 BaseURL / Key / 模型列表 / 上下文长度 / 超时 / 额外请求头与透传 Body
- **模型能力开关**：每个模型可单独设置
  - 支持图片：直接多模态发给主模型
  - 支持思考：是否发送 `reasoning_effort`
  - 支持工具：是否允许 function calling
  - 默认所有模型不支持图片；思考 / 工具默认开
- **图片识别**：
  - 主模型不支持图片时，自动把图片交给 `image_recognize` 工具，由配置的“图片识别模型”看图
  - `image_recognize` 支持 `focus` 焦点参数，可指定“看右上角”“第三行文字”等细节；无焦点则整体描述
  - 支持只发图片不写字；多图合并为同一条消息；撤回自动恢复全部附件
- **AI 截图与图片展示**：
  - `browser_screenshot`：截取内置浏览器当前画面，只返回图片路径
  - `show_image`：通用图片展示工具，传 `path` 或 `base64` 都能显示到聊天里并让 AI 知道
  - 主模型支持图片时 `show_image` 会把图片注入对话直接看图；不支持图片时用 `image_recognize` 识别
- **Agent 主线**：主模型始终驱动对话，工具由它按需调用
  - 青龙工具：任务 / 脚本 / 环境变量 / 依赖 / 配置 / 日志 / 订阅 / 系统
  - 本地 Shell：`shell_probe` / `shell_exec` / `shell_script` / 文件读写
  - 浏览器：内置 WebView 内核，可开窗、截图、注入、交互
  - 编辑器：与代码编辑器页联动
  - MCP：外部服务接入，工具名形如 `服务前缀__工具名`
  - 记忆与技能：跨会话长期记忆、操作手册技能库
  - 子代理：`task_worker` / `parallel_agents` 派工人并行干活
  - 确认策略：严格 / 仅危险 / 全部放行三档
- **聊天体验**：SSE 流式、任务计划卡片、确认 / 拒绝、执行过程卡片、会话持久化
- **悬浮 AI 窗**：任何页面可呼出，重发 / 撤回 / 附件都支持
- **页面一键发给 AI**：日志、脚本、环境变量、配置等可直接“发给 AI 分析”

### 其他
- 内置浏览器工具（页面截图 / 注入 / 交互）
- 外部跳转拦截：网页要拉起微信/QQ/支付宝等外部 App 时先弹确认框，AI 可用 `browser_jumps` / `browser_jump` 决定放行或拒绝
- 缓存专用目录 `/cache`：截图、临时文件等非长期数据统一放这里；App 启动自动清理超过 30 天的缓存，超过 200MB 按旧数据优先清理
- AI 可管理 APP：`settings_get/settings_set` 看/改主题、缓存策略、轮询等；`cache_info/cache_clear` 管缓存；`provider_manage` 配置 AI 提供商（含 API Key 安全保存）
- 主题方案系统：配置文件 `/workspace/.ql_themes/themes.json`，支持背景图路径、完整配色表、玻璃描边/阴影/圆角/动画效果；设置页带配色点预览；AI 可用 `theme_manage` 生成/应用/导入/导出主题
- ZIP 主题包：支持含 `theme.json` / `README.md` / `controller.js` / `css/` / `js/` / `image/background/` / `image/elements/` / `audio/` / `方案/` 的压缩包；包内带 `index.html` 时用 WebView 渲染 HTML/CSS/JS/视频动态背景；纯色主题只有脚本和 md，不耗额外渲染
- 代码编辑器（JetBrains Mono，等宽字体渲染）
- 三态主题（跟随系统 / 亮 / 暗）
- 输出整理插件：请求前 hook / 响应后 hook（自定义 JS）

## 运行

```bash
cd qinglong_flutter
flutter pub get
flutter run
```

Debug APK 构建：

```bash
cd qinglong_flutter/android
./gradlew assembleDebug
# 产物：build/app/outputs/flutter-apk/app-debug.apk
```

## 目录速览

```
lib/
├── main.dart / app.dart / router.dart
├── core/
│   ├── network/       # Dio、AuthInterceptor、错误处理
│   ├── storage/       # 安全存储 / SharedPreferences / Drift
│   ├── local_shell/   # PRoot 桥 + 沙箱
│   ├── llm/           # 多提供商 LLM 客户端、注册表、模型能力
│   ├── theme/         # 三态主题
│   └── utils/         # cron / 格式化 / 日志
├── features/
│   ├── panels/        # 多面板 + 登录
│   ├── crons/         # 定时任务
│   ├── scripts/       # 脚本管理 + 编辑器
│   ├── envs/          # 环境变量
│   ├── configs/       # 配置管理
│   ├── dependencies/  # 依赖管理
│   ├── logs/          # 日志中心
│   ├── subscriptions/ # 订阅管理
│   ├── system/        # 系统管理
│   ├── ai/            # AI 聊天、Agent、MCP、记忆、技能、悬浮窗、多模态
│   ├── browser/       # 内置浏览器
│   ├── editor/        # 代码编辑器
│   ├── terminal/      # PRoot Debian 终端
│   └── settings/      # 设置
└── shared/            # 通用组件
```

## 文档

- [AI 系统提示 / SKILL 全文](docs/qinglong_SKILL.md)：当前运行时内置的 Agent 提示词与工具规范

## 当前状态

- Debug APK 已可构建安装
- `flutter analyze` 无错误
- 发布版（签名 / 裁剪 / 商店包）仍在收尾
