# 青龙面板 Flutter APP（含青龙专用 AI）

本仓库是 v6 终版规格的 **完整工程骨架 + P0/P1/P2/P3 核心实现**，代码位于 `qinglong_flutter/`。

已生成 `android/` 与 `ios/` 平台目录，可直接 `flutter pub get` / `flutter run` 编译运行。

## 已实现（P0-P3）

- 工程骨架：`pubspec.yaml`、analysis、路由、主题、底栏导航、多面板切换条。
- `core/`
  - `network/`：Dio 单例、Bearer token 注入、401 自动重登回调、统一业务错误解析。
  - `storage/`：`flutter_secure_storage` 保存 token/密码/API Key，`shared_preferences` 保存面板元数据与设置。
  - `theme/`：跟随系统 / 亮 / 暗三态 Material 3 主题。
  - `utils/`：cron 解析（5 段/6 段、下次执行时间）、格式化、脱敏日志。
- 多面板管理：
  - 面板增删改、设置默认、切换；BaseURL 校验；账号密码 / OpenAPI 两种登录；连接测试。
  - token 持久化、重启免登录；账号密码模式 401 自动重登。
- 定时任务：
  - 列表搜索 / 筛选 / 下拉刷新 / 上拉分页 / 运行中轮询。
  - 新建 / 编辑：cron 实时校验与下次执行预览、标签、前置/后置命令。
  - 批量运行 / 停止 / 启用 / 禁用 / 删除；滑动删除。
  - 日志页：轮询追日志、自动滚动、关键字高亮、复制全部。
- 脚本管理：
  - 文件树浏览 / 搜索 / 新建 / 上传。
  - 编辑器：读取、保存、运行、停止、未保存离开确认。
- 环境变量：
  - 列表搜索 / 状态筛选 / 值打码与点看。
  - 新增 / 编辑 / 批量启用 / 禁用 / 删除。
- 配置管理：配置文件列表 / 查看 / 编辑 / 保存，auth.json 敏感提示。
- 依赖管理：NodeJs / Python3 / Linux 三类型 Tab、安装 / 卸载 / 重装、状态徽标。
- 日志中心：日志文件列表 / 搜索 / 查看 / 复制 / 刷新。
- 系统管理：版本信息、日志删除频率、检测更新、更新面板（二次确认）。
- 设置：主题三态、轮询间隔、LLM 配置（Base URL / Model / API Key）、自签名 HTTPS 开关。
- AI（精简版 Agent）：
  - OpenAI 兼容 LLM 客户端（完整请求 + SSE 流式接口）。
  - QL 工具注册表：任务 / 脚本 / 环境变量 / 依赖 / 配置 / 系统 / 日志。
  - 只读工具自动执行；写操作 confirm 硬拦截 + 计划确认卡片。
  - 聊天页：消息气泡、示例引导、计划确认 / 拒绝、审计窗（SharedPreferences 持久化）。
  - 已注入完整 `docs/qinglong_SKILL.md`，并新增 `shell_probe` / `shell_exec` 本地 Debian 工具。
  - 上下文一键发送：任务 / 脚本 / 环境变量列表可直接“发给 AI 分析”并切换到 AI Tab。
- 本地 PRoot Debian（P4）：
  - 采用 Coomi Runtime V2 的官方 manifest：PRoot host + Debian Bookworm rootfs，SHA-256/大小双重校验。
  - Android 原生桥：下载 / 校验 / 解包 / 激活 Runtime V2、一次性 exec、交互式 bash。
  - xterm 终端页：启动 Debian、实时输入输出、停止；命令沙箱拦截危险破坏命令。
- `shared/`：空态 / 错误态 / 加载态 / 搜索框 / 二次确认等通用组件。
- 单元测试：`test/cron_parser_test.dart`、`test/widget_test.dart`、`test/tool_registry_test.dart`、`test/sandbox_test.dart`。

## 尚未实现（P7/P8 剩余/P5增强）

- P5 增强：嵌入 coomi-rs 完整能力版引擎（当前为 Dart 精简版 Agent）。
- P7 剩余：审计进一步落库、AI×终端联动增强。
- P8 剩余：真机联调、发布包（release/签名/裁剪体积）。Debug APK 已验证可构建。

## 运行步骤

```bash
cd qinglong_flutter
flutter pub get
flutter run
```

已通过 `flutter analyze`（无问题）、`flutter test`（9 个测试全部通过），并已用 Gradle 成功构建 `build/app/outputs/flutter-apk/app-debug.apk`（约 153MB debug 包）。

若使用真实 Android 真机，请配置允许访问面板的 BaseURL（内网 http 或自签名 https 需在设置中显式开启）。

## 目录速览

```
lib/
├── main.dart / app.dart / router.dart
├── core/
│   ├── network/       # Dio、AuthInterceptor、错误处理
│   ├── storage/       # 安全存储 / SharedPreferences
│   ├── local_shell/   # PRoot 桥 + 沙箱（P4 已实现）
│   ├── llm/           # LLM 客户端骨架（P5）
│   ├── theme/         # 三态主题
│   └── utils/         # cron / 格式化 / 日志
├── features/
│   ├── panels/        # 多面板 + 登录（已实现）
│   ├── crons/         # 定时任务（已实现）
│   ├── home/          # 底栏导航 + 多面板切换条
│   ├── scripts/       # 脚本（已实现）
│   ├── envs/          # 环境变量（已实现）
│   ├── configs/       # 配置（已实现）
│   ├── dependencies/  # 依赖（已实现）
│   ├── logs/          # 日志中心（已实现）
│   ├── system/        # 系统（已实现）
│   ├── ai/            # AI 聊天 + Dart Agent + 工具 confirm（精简版已实现）
│   ├── terminal/      # Debian 终端（P4 已实现）
│   └── settings/      # 设置（已完善）
└── shared/            # 通用组件
```

## 后续实现顺序建议

1. P5 增强：按需嵌入 coomi-rs 完整能力版（Agent 记忆/子代理/SKILL/MCP）。
2. P7：上下文感知、审计落库、AI×终端联动。
3. P8：真机联调与 APK 打包。