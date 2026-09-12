import 'dart:convert';

/// 技能里的一个附属文件（代码脚本 / 参考资料 / 资源）。
///
/// 市面技能是「文件夹」：SKILL.md 之外往往还有 `scripts/*.py|*.js`、
/// `references/*.md` 等。完整支持就得把这些文件随技能一起存下来，
/// 让 AI 既能读到内容，也能落盘到终端实际运行。
class SkillFile {
  const SkillFile({
    required this.path,
    required this.content,
    this.binary = false,
  });

  /// 技能内相对路径，如 `scripts/check.py`、`references/guide.md`。
  final String path;

  /// 文本内容；[binary] 为 true 时是 base64 编码的二进制内容。
  final String content;

  /// 是否二进制文件（tarball/zip/图片等）。二进制内容以 base64 存。
  final bool binary;

  /// 是不是脚本（.py/.js/.sh 等），决定能否直接跑。
  bool get isScript => RegExp(r'\.(py|js|jsx|ts|sh|bash|pl|rb|go)$')
      .hasMatch(path.toLowerCase());

  /// 相对路径是不是常见二进制（tarball/zip/可执行等）。
  static bool isBinaryPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.tar') ||
        lower.endsWith('.tar.gz') ||
        lower.endsWith('.tgz') ||
        lower.endsWith('.gz') ||
        lower.endsWith('.zip') ||
        lower.endsWith('.jar') ||
        lower.endsWith('.bin') ||
        lower.endsWith('.dat') ||
        lower.endsWith('.exe') ||
        lower.endsWith('.so') ||
        lower.endsWith('.dll') ||
        lower.endsWith('.pdf') ||
        lower.endsWith('.docx') ||
        lower.endsWith('.xlsx') ||
        lower.endsWith('.pptx');
  }

  /// 文本文件的原始内容（二进制时返回空/提示）。
  String? get textContent => binary ? null : content;

  Map<String, dynamic> toJson() =>
      {'path': path, 'content': content, 'binary': binary};

  factory SkillFile.fromJson(Map<String, dynamic> json) => SkillFile(
        path: json['path']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        binary: json['binary'] == true,
      );
}

/// 一个「技能」= 一份 SKILL.md 手册 + 可选的一批代码/资源文件。
///
/// 兼容市面 Agent Skills（Anthropic 标准）：
/// - `name` / `description` 来自 SKILL.md 的 YAML frontmatter；
/// - `instructions` 是 SKILL.md 正文；
/// - `files` 是同目录下的 scripts/references/resources 等附属文件。
///
/// 渐进披露：系统提示里只放名字 + 一句话描述 + 触发场景，
/// AI 判断需要时用 skill_read 工具把正文/代码读出来。这样装几十个技能
/// 也不会把上下文撑爆。
class AiSkill {
  const AiSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.instructions,
    this.whenToUse = '',
    this.enabled = true,
    this.builtin = false,
    this.license = '',
    this.sourceUrl = '',
    this.files = const [],
  });

  final String id;

  /// 供 AI 引用的名字，kebab-case，与 SKILL.md frontmatter 的 name 一致。
  final String name;
  final String description;

  /// 什么时候该用它——写清楚 AI 才知道何时加载。
  final String whenToUse;

  /// SKILL.md 正文：步骤、注意事项、模板代码。
  final String instructions;
  final bool enabled;

  /// 内置技能不可删除，可以停用。
  final bool builtin;

  /// SKILL.md frontmatter 里的 license（可选）。
  final String license;

  /// 来源（GitHub 仓库/URL），便于追踪更新。
  final String sourceUrl;

  /// 随技能一起导入的附属文件（scripts/references/resources…）。
  final List<SkillFile> files;

  /// 相对某目录展开标题时，直接从正文里提取一级标题当名字。
  bool get hasCode => files.any((f) => f.isScript);

  AiSkill copyWith({
    String? name,
    String? description,
    String? whenToUse,
    String? instructions,
    bool? enabled,
    String? license,
    String? sourceUrl,
    List<SkillFile>? files,
  }) {
    return AiSkill(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      whenToUse: whenToUse ?? this.whenToUse,
      instructions: instructions ?? this.instructions,
      enabled: enabled ?? this.enabled,
      builtin: builtin,
      license: license ?? this.license,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      files: files ?? this.files,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'whenToUse': whenToUse,
        'instructions': instructions,
        'enabled': enabled,
        'builtin': builtin,
        'license': license,
        'sourceUrl': sourceUrl,
        'files': [for (final f in files) f.toJson()],
      };

  factory AiSkill.fromJson(Map<String, dynamic> json) => AiSkill(
        id: json['id']?.toString() ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name']?.toString() ?? '未命名技能',
        description: json['description']?.toString() ?? '',
        whenToUse: json['whenToUse']?.toString() ?? '',
        instructions: json['instructions']?.toString() ?? '',
        enabled: json['enabled'] as bool? ?? true,
        builtin: json['builtin'] as bool? ?? false,
        license: json['license']?.toString() ?? '',
        sourceUrl: json['sourceUrl']?.toString() ?? '',
        files: [
          for (final f in (json['files'] as List? ?? const []))
            if (f is Map<String, dynamic>) SkillFile.fromJson(f),
        ],
      );

  static String encodeList(List<AiSkill> skills) =>
      jsonEncode([for (final s in skills) s.toJson()]);

  static List<AiSkill> decodeList(String raw) {
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map<String, dynamic>) AiSkill.fromJson(item),
      ];
    } catch (e) {
      return const [];
    }
  }
}

/// 内置技能：覆盖用户最常见的几类活儿。
const builtinSkills = <AiSkill>[
  AiSkill(
    id: 'builtin-script-debug',
    name: 'script-debug',
    description: '脚本报错定位与修复：从日志报错反推原因，本地复现后再改面板脚本',
    whenToUse: '用户贴了报错日志、说"任务失败/脚本跑不通"，或让你分析某个任务为什么不工作时',
    builtin: true,
    instructions: '''
# 脚本报错定位与修复

## 步骤
1. 先拿事实：cron_list 找到任务（看 isDisabled、last_execution_time、last_running_time），再 cron_log 读最近日志。
2. 日志是空的不代表脚本坏了：可能从没跑过。先确认有没有执行记录，必要时建议用户手动跑一次（或在确认策略允许时用 cron_run）。
3. 定位报错类型，按下面对号入座：
   - `ModuleNotFoundError` / `Cannot find module` → 缺依赖，用 dep_list 查是否装过，再 dep_install。
   - `KeyError` / `环境变量为空` / `undefined` → 缺环境变量，env_list 核对变量名（注意大小写、下划线）。
   - `401/403` → cookie/token 过期，告诉用户需要重新抓取，并指出是哪个环境变量。
   - `Timeout` / `ECONNRESET` / `getaddrinfo` → 网络问题，让用户确认服务器能不能访问目标站点，别急着改代码。
   - `SyntaxError` → 脚本被截断或编码问题，script_read 看真实内容。
4. 想改代码前先在本机 Debian 复现：shell_write_file 写一个最小可跑片段，shell_exec 跑一遍。注意声明"这是本地结果，服务器需再验证"。
5. 确认修法后再 script_write 覆盖面板脚本（这是危险操作，会挂起等确认）。改之前先 script_read 备份原文并把关键片段贴给用户。
6. 改完再 cron_run + cron_log 验证，然后 task_complete。

## 禁忌
- 没读过真实日志/脚本就猜原因。
- 直接大改整个脚本；优先最小改动，并说明改了哪几行、为什么。
''',
  ),
  AiSkill(
    id: 'builtin-new-task',
    name: 'new-task',
    description: '从零创建一个能跑的定时任务：写脚本 → 本地验证 → 建 cron → 核实',
    whenToUse: '用户说"帮我做个每天/每小时干某件事的任务"、"加个签到"之类的需求时',
    builtin: true,
    instructions: '''
# 新建定时任务

## 步骤
1. 把需求问清：干什么、多久跑一次、需要哪些账号/密钥、成功怎么判断。缺信息就问，别假设。
2. 写脚本：优先 Node.js（青龙原生支持）或 Python3。脚本必须自带：
   - 从 process.env / os.environ 读凭据，绝不硬编码；
   - 明确的成功/失败日志输出（用户就是靠日志判断的）；
   - 异常捕获，失败时打印足够的上下文。
3. 本地先验证语法与主流程：shell_write_file 写到 /workspace，shell_exec 用 `node --check` 或 `python3 -m py_compile` 检查，能跑的部分跑一遍。
4. script_write 上传到面板（危险操作，会挂起确认）。
5. env_create 补齐脚本需要的环境变量（值由用户提供，你不要编）。
6. cron_create 建任务：cron 表达式用大白话解释一遍给用户确认（"30 8 * * * 就是每天早上 8:30"）。
7. cron_run 试跑一次 + cron_log 看结果，确认真的能跑通再 task_complete。

## 输出
交付时说清：脚本文件路径、任务名、执行时间、依赖的环境变量清单、在哪看日志。
''',
  ),
  AiSkill(
    id: 'builtin-env-audit',
    name: 'env-audit',
    description: '环境变量体检：找出重复、失效、脚本要用但没配的变量',
    whenToUse: '用户问"我的变量配得对不对"、"为什么读不到变量"，或做整体检查时',
    builtin: true,
    instructions: '''
# 环境变量体检

## 步骤
1. env_list 拉全量。注意：值可能很长（cookie），不要整段回显，脱敏展示（前 6 字符 + …）。
2. 找问题：
   - 同名重复（青龙允许同名多条，脚本通常只读第一条或用 & 拼接，容易踩坑）；
   - 被禁用但脚本仍在用；
   - 值明显过期（cookie 里的 expires、token 长度异常、含 "null"/"undefined"）；
   - 名字大小写或下划线写错（对照脚本里 process.env.XXX 的实际拼写）。
3. 反向核对：script_read 关键脚本，把里面读取的变量名列出来，和 env_list 求差集，指出"脚本要用但没配"和"配了没人用"。
4. 输出一张表：变量名 / 状态 / 问题 / 建议动作。改动前逐条问用户。

## 禁忌
- 直接输出完整 cookie、token。
- 未经确认删除任何变量。
''',
  ),
  AiSkill(
    id: 'builtin-dep-fix',
    name: 'dep-fix',
    description: '依赖安装失败的排查与修复（npm/pnpm/pip/apk 常见坑）',
    whenToUse: '依赖装不上、脚本报缺模块、用户问"怎么装某个库"时',
    builtin: true,
    instructions: '''
# 依赖问题排查

## 步骤
1. dep_list 看这个依赖是否已存在、状态是什么（安装中/失败/成功）。已存在但失败的先看安装日志。
2. 常见原因与对策：
   - 网络/registry 超时 → 建议换镜像源（npm config set registry），或让用户确认服务器网络。
   - 编译型包（node-gyp、lxml、Pillow）缺构建工具 → 需要先装系统依赖，容器里通常是 apk add python3 make g++ 之类。
   - 版本冲突 → 指定明确版本号安装。
   - 明明装了脚本还报缺 → 大概率装在了错误的路径/不同的 node 环境，用 shell 侧或让用户在面板里确认依赖目录。
3. 修复动作：dep_install（新增）或 dep_reinstall（重装，危险操作需确认）。
4. 装完 dep_list 确认状态变成成功，再 cron_run 验证原脚本，然后 task_complete。

## 提醒
本机 Debian 装成功 ≠ 面板容器装成功，两边是不同环境，必须在面板侧验证。
''',
  ),
  AiSkill(
    id: 'builtin-api-probe',
    name: 'api-probe',
    description: '用 curl 在本机验证接口：抓包参数、鉴权、返回结构',
    whenToUse: '需要确认某个接口怎么调、返回什么，或写脚本前先摸清接口时',
    builtin: true,
    instructions: r'''
# 接口验证

## 步骤
1. 明确 URL / 方法 / 必需 Header / Body。缺的向用户要，不要瞎编 UA 和 cookie。
2. 先探活：
   shell_exec: curl -sS -o /dev/null -w 'HTTP:%{http_code} time:%{time_total}s\n' 'URL'
3. 再看正文（限制长度，别把上下文冲爆）：
   shell_exec: curl -sS 'URL' -H 'Header: v' | head -c 2000
4. 解读：状态码含义、关键字段路径、是否需要签名/时间戳、是否有反爬。
5. 结论里给出"脚本里应该这么调"的代码片段，并标注这是本地测试结果。

## 禁忌
- curl 命令里出现真实 token 时，回显给用户前要脱敏。
- 不做高频请求，不做压测。
''',
  ),
  AiSkill(
    id: 'builtin-theme-developer',
    name: 'theme-developer',
    description: '主题包开发与安装：从零生成/修改/导入导出主题 ZIP，把效果写进主题包',
    whenToUse: '用户要换主题、生成主题、做樱花树背景、导入/导出主题包时',
    builtin: true,
    instructions: r'''
# 主题包开发与安装

## 角色
你是主题包开发者，所有视觉/组件特效都由主题包自己实现，App 不内置固定特效。

## 主题包结构
- `controller.js`：总控，声明 theme/themeResources。
- `html/index.html`：背景 HTML。
- `css/`、`js/`：背景样式与脚本（兄弟目录，相对 html 用 `../css/`、`../js/`）。
- `image/elements/`：布偶、花瓣、角标等图片。
- `xml/`：动画/组件定义。

## 流程
1. `theme_manage create` 生成基础包。
2. shell 写 html/js/css/image，controller.js 声明资源。
3. `theme_manage export_zip` 导出。
4. `theme_manage import_zip` 导入安装并应用。

## 原则
- 高级组件特效用 DSHTheme（见 theme-effect-dev 技能），不要依赖 App 固定效果。
- 图片路径必须是主题包内 guest 路径。
''',
  ),
  AiSkill(
    id: 'builtin-theme-effect-dev',
    name: 'theme-effect-dev',
    description: 'DSHTheme 高级组件特效：落叶、浮动、发光、角标、布偶、气泡、组件背景弹跳',
    whenToUse: '用户要组件特效/落叶/布偶/气泡/边框发光/角标/组件浮动时',
    builtin: true,
    instructions: r'''
# DSHTheme 组件特效开发

## App 开放接口
- 主题包 js 调 `window.DSHTheme.*`，在 Flutter 组件上层绘制效果，不挡点击。
- GlassPanel/GlassCard 自动上报锚点，用 DSHTheme.queryComponents 查真实坐标。

## API
```javascript
DSHTheme.effect({
  id: 'petal_1',
  imagePath: '/workspace/.ql_themes/packages/x/image/elements/petal.png',
  x: 120, y: 300, width: 40, height: 40,
  animation: 'float' // none | float | bounce | spin
});
DSHTheme.queryComponents({ type: 'panel', callback: function(list) { console.log(list); } });
DSHTheme.remove('petal_1');
DSHTheme.clear();
```

## 常用字段
- id/imagePath/icon/text/x/y/width/height/color/animation/fontSize/speechTail。

## 标准套路
1. 落叶：多片 leaf 图，float 动画，定时更新 x/y。
2. 发光/角标：queryComponents 拿矩形，图片/文字贴角上，发光可用 css filter。
3. 布偶：布偶图放 image/elements，effect 挂组件上方，bounce 动作；互动 JS 监听触摸并更新气泡。
4. 组件背景弹跳：queryComponents 取矩形，JS 每帧限制布偶在矩形内弹跳。
5. 序号：用返回的 index 精确指定第几个组件，也支持 page/type/index 组合。
''',
  ),
];
