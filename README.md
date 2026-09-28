# 青龙AI

一个跑在 Android 手机上的 **青龙面板管理端 + 本地 Linux（PRoot Debian）+ 内置浏览器抓包/调试 + 通用 AI Agent**。

青龙AI 不只是一个面板客户端，还是一台随身 AI 工作站：能管青龙定时任务、跑本地 Debian、开内置浏览器抓 WebSocket/SSE、把浏览器和终端交给 AI 协作。

## 当前功能

### 面板管理
- 多面板：增删改、默认面板、一键切换
- 登录：账号密码 / OpenAPI Token
- Token 持久化、重启免登录、401 自动重登
- BaseURL / 自签名 HTTPS 开关

### 青龙核心业务
- **定时任务**：列表 / 搜索 / 筛选 / 分页 / 运行中轮询、新建 / 编辑（cron 实时校验、下次执行预览）、批量运行 / 停止 / 启用 / 禁用 / 删除、日志实时追更
- **脚本管理**：文件树 / 搜索 / 新建 / 上传 / 在线代码编辑器 / 运行 / 停止
- **环境变量**：搜索 / 状态筛选 / 新增 / 编辑 / 批量启停删；修正 Qinglong 状态语义（0=启用，1=禁用）
- **配置管理**：配置文件查看 / 编辑 / 保存，auth.json 敏感提示
- **依赖管理**：NodeJs / Python3 / Linux 三类型，安装 / 卸载 / 重装
- **日志中心**：日志文件列表 / 搜索 / 查看 / 复制 / 刷新
- **订阅管理**：订阅增删改、拉取、日志、私有仓库提示
- **系统管理**：版本信息、日志清理频率、更新按钮（二次确认）

### 内置浏览器与抓包调试
- 内置 WebView 内核：开窗、多标签、页面截图、注入脚本、与 AI 交互
- **请求抓包**：注入式 hook 捕获 `fetch` / `XHR` / `WebSocket` / `EventSource`（SSE）
- **WebSocket 完整捕获**：
  - 实例级 + 原型级 send/close 包装，`WeakMap` 保存会话元数据
  - `document-start` 原生早期注入（AndroidX `WebViewCompat.addDocumentStartJavaScript`），能抓到页面 `new WebSocket` 立刻建立的早期连接
- **SSE 自定义事件捕获**：不仅监听 `message`，还包装页面任意命名事件（如 `tick`），完整记录推送流
- **会话详情页**：
  - 长消息默认折叠，可一键展开完整内容
  - 右侧消息结构预览图（Minimap）：色块表示发送/接收/系统，消息长短映射块高度，支持拖动跳转、固定放大块指示当前轴位置
- **AI 调试工具**：
  - `browser_ws`：预览 WebSocket 连接、深读消息、主动发送、主动断开
  - `browser_sse`：预览 SSE 会话、深读消息、主动断开
  - `browser_hook`：加载自定义 JS 钩子；支持自启动脚本（不必提供 `onRequest/onResponse`）
  - `browser_fetch`：用独立请求重发抓到的请求，排除面板鉴权干扰
- 外部跳转拦截：网页要拉起微信/QQ/支付宝等外部 App 时先弹确认框，AI 可决定放行或拒绝

### 本地 Linux（PRoot Debian）
- 手机上的 Debian 环境（Coomi Runtime V2）
- 一键下载 / SHA-256 校验 / 解包 / 激活
- xterm 终端：实时输入输出、停止、危险命令沙箱拦截
- **PRoot 会话管理器**：
  - `shell_session_start/list/status/stop`：AI 可创建、查看、停止后台 Linux 会话
  - 支持 guest 路径（如 `/workspace`）自动解析到宿主真实路径
- 无边框悬浮终端：浮在任意页面上，随时叫出终端
- APP 与 AI 共享同一份 `/workspace` 文件系统

### AI Agent
- **多提供商 LLM**：任意 OpenAI 兼容端点，每家独立 BaseURL / Key / 模型列表 / 上下文长度 / 超时 / 额外请求头与透传 Body
- **模型能力开关**：每个模型可单独设置
  - 支持图片：直接多模态发给主模型
  - 支持思考：是否发送 `reasoning_effort`
  - 支持工具：是否允许 function calling
- **图片识别**：
  - 主模型不支持图片时，自动交给 `image_recognize` 工具，由配置的“图片识别模型”看图
  - `image_recognize` 支持 `focus` 焦点参数，可指定“看右上角”“第三行文字”等细节
  - 支持只发图片不写字；多图合并为同一条消息；撤回自动恢复全部附件
- **Agent 主线**：主模型始终驱动对话，工具由它按需调用
  - 青龙工具：任务 / 脚本 / 环境变量 / 依赖 / 配置 / 日志 / 订阅 / 系统
  - 本地 Shell：`shell_probe` / `shell_exec` / `shell_script` / 文件读写
  - 浏览器：抓包、截图、注入、交互、Minimap 深读、WS/SSE 控制
  - 编辑器：与代码编辑器页联动
  - MCP：外部服务接入，工具名形如 `服务前缀__工具名`
  - 记忆与技能：跨会话长期记忆、操作手册技能库
  - 子代理：`task_worker` / `parallel_agents` 派工人并行干活
  - 确认策略：严格 / 仅危险 / 全部放行三档
- **聊天体验**：SSE 流式、任务计划卡片、确认 / 拒绝、执行过程卡片、会话持久化、失败消息重发保留原始用户内容
- **悬浮 AI 窗**：任何页面可呼出，重发 / 撤回 / 附件都支持
- **页面一键发给 AI**：日志、脚本、环境变量、配置等可直接“发给 AI 分析”

### 其他
- 代码编辑器（JetBrains Mono，等宽字体渲染）
- 三态主题（跟随系统 / 亮 / 暗）
- 主题方案系统：ZIP 主题包，`controller.js` 总控，支持图片/脚本/音频/CSS/JS/HTML/XML 组件与动态背景
- 缓存专用目录 `/cache`：截图、临时文件等非长期数据统一放这里；App 启动自动清理超过 30 天的缓存，超过 200MB 按旧数据优先清理
- AI 可管理 APP：`settings_get/settings_set` 看/改主题、缓存策略、轮询等；`cache_info/cache_clear` 管缓存；`provider_manage` 配置 AI 提供商
- 发布版已移除设置页调试入口，调试日志默认关闭

## 运行

```bash
cd qinglong_flutter
flutter pub get
flutter run
```

Release APK 构建：

```bash
cd qinglong_flutter
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

## 目录速览

```
lib/
├── main.dart / app.dart / router.dart
├── core/
│   ├── network/       # Dio、AuthInterceptor、错误处理
│   ├── storage/       # 安全存储 / SharedPreferences / Drift
│   ├── local_shell/   # PRoot 桥 + 沙箱 + 会话管理
│   ├── llm/           # 多提供商 LLM 客户端、注册表、模型能力
│   ├── theme/         # 三态主题 / ZIP 主题包
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
│   ├── browser/       # 内置浏览器、抓包、WS/SSE、Minimap、AI 工具
│   ├── editor/        # 代码编辑器
│   ├── terminal/      # PRoot Debian 终端 + 悬浮终端 + 会话管理
│   └── settings/      # 设置
└── shared/            # 通用组件
```

## 文档

- [AI 系统提示 / SKILL 全文](docs/qinglong_SKILL.md)：当前运行时内置的 Agent 提示词与工具规范

## 当前状态

- 版本：**1.0.0+1（青龙AI）**
- Release APK 可稳定构建安装
- `flutter analyze lib` 无错误
- 已上传 GitHub：`https://github.com/xxcyou/qinglong-flutter`