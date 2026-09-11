import 'dart:convert';

import '../knowledge/knowledge_store.dart';
import '../mcp/mcp_models.dart';
import '../mcp/mcp_provider.dart';
import '../memory/memory_models.dart';
import '../memory/memory_provider.dart';
import '../skills/skill_provider.dart';
import '../skills/skill_models.dart';
import 'external_tool.dart';
import 'web_fetch.dart';

/// 元能力工具：让 AI 管理自己的记忆、技能与 MCP 接入。
///
/// 这是"AI 自己进化"的入口——用户丢一个开源项目链接，AI 抓正文、提炼成技能装上；
/// 某个技能不好用，AI 改它或删它；某个 MCP 服务器要接进来，AI 自己填配置并握手验证。
/// 全部走 [ExternalTool]，因此照样受确认策略约束（写类都标 isWrite）。
class MetaTools {
  const MetaTools._();

  static List<ExternalTool> build({
    required MemoryNotifier memory,
    required SkillNotifier skills,
    required McpNotifier mcp,
    required McpState mcpState,
    required List<AiSkill> skillList,
  }) {
    return [
      ..._memoryTools(memory),
      ..._skillTools(skills, skillList),
      ..._mcpTools(mcp, mcpState),
      ..._knowledgeTools(),
      _webFetchTool(),
    ];
  }

  // ---------------------------------------------------------------- 记忆

  static List<ExternalTool> _memoryTools(MemoryNotifier memory) {
    return [
      ExternalTool(
        name: 'memory_write',
        description: '记住一条长期结论，跨会话有效。'
            '值得记的：用户偏好、面板/主机的既定事实、踩过的坑与正确做法、要跟进的事。'
            '不要记：一次性的临时变量、能随时查到的数据、任何明文凭据。'
            '内容高度相似的旧记忆会被自动覆盖。',
        parameters: {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description': '一句话结论，写成以后自己能直接用的形式',
            },
            'kind': {
              'type': 'string',
              'enum': [for (final k in MemoryKind.values) k.name],
              'description': '分类：'
                  '${MemoryKind.values.map((k) => '${k.name}=${k.hint}').join('；')}',
            },
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '检索用标签，如 京东、通知、依赖',
            },
            'importance': {
              'type': 'integer',
              'description': '1-5，越大越优先注入上下文，默认 3',
            },
            'pinned': {
              'type': 'boolean',
              'description': 'true=每轮都注入。只给真正的长期约束用，别滥用',
            },
          },
          'required': ['content'],
        },
        origin: '记忆库',
        isWrite: true,
        invoke: (args) async {
          final content = args['content']?.toString().trim() ?? '';
          if (content.isEmpty) return '内容为空，没有记录。';
          final saved = await memory.write(
            content: content,
            kind: MemoryKind.parse(args['kind']?.toString()),
            tags: [
              for (final t in (args['tags'] as List? ?? const []))
                t.toString().trim(),
            ].where((t) => t.isNotEmpty).toList(),
            importance: (args['importance'] as num?)?.toInt() ?? 3,
            pinned: args['pinned'] == true,
          );
          return '已记住 [${saved.id}]（${saved.kind.label}）：${saved.content}';
        },
      ),
      ExternalTool(
        name: 'memory_search',
        description: '检索长期记忆。系统提示里已注入相关记忆，'
            '只在需要更多历史结论时用它。',
        parameters: const {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '关键词，留空则返回最重要的几条'},
            'limit': {'type': 'integer', 'description': '返回条数，默认 10'},
          },
        },
        origin: '记忆库',
        invoke: (args) async {
          final results = memory.search(
            args['query']?.toString() ?? '',
            limit: (args['limit'] as num?)?.toInt() ?? 10,
          );
          if (results.isEmpty) return '没有匹配的记忆。';
          await memory.markHits(results.map((m) => m.id));
          return [
            '命中 ${results.length} 条：',
            for (final m in results)
              '- [${m.id}]（${m.kind.label}·重要度${m.importance}）${m.content}',
          ].join('\n');
        },
      ),
      ExternalTool(
        name: 'memory_delete',
        description: '删掉一条已经不成立或写错的记忆。发现记忆与现实不符时该主动清理。',
        parameters: const {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '记忆 id，形如 [xxxx] 里的内容'},
          },
          'required': ['id'],
        },
        origin: '记忆库',
        isWrite: true,
        invoke: (args) async {
          final id = args['id']?.toString().trim() ?? '';
          final ok = await memory.remove(id);
          return ok ? '已删除记忆 $id。' : '没有 id 为 $id 的记忆。';
        },
      ),
    ];
  }

  // ---------------------------------------------------------------- 知识库

  static List<ExternalTool> _knowledgeTools() {
    final store = KnowledgeStore();
    return [
      ExternalTool(
        name: 'kb_search',
        description: '检索知识库（标题+标签+正文的关键词全文匹配，不做向量嵌入）。'
            '知识库不会自动注入上下文，只有主动调 kb_search / kb_read 才看得到内容。'
            '遇到用户问题涉及历史经验、踩坑记录、方案模板之前，先搜知识库；'
            '搜到匹配项后用 kb_read 读完整内容。',
        parameters: const {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '检索词，多个词用空格分隔'},
            'limit': {'type': 'integer', 'description': '返回条数，默认 10'},
          },
        },
        origin: '知识库',
        invoke: (args) async {
          final query = args['query']?.toString() ?? '';
          final limit = (args['limit'] as num?)?.toInt() ?? 10;
          final hits = await store.search(query, limit: limit);
          if (hits.isEmpty) return '知识库没有匹配「$query」的条目。';
          return [
            '知识库命中 ${hits.length} 条（需要详细内容用 kb_read 读全文）：',
            for (final d in hits)
              '- ${d.title}\n'
                  '  路径：${d.path}\n'
                  '  标签：${d.tags.isEmpty ? '（无）' : d.tags.join(' / ')}\n'
                  '  摘要：${d.snippet}',
          ].join('\n');
        },
      ),
      ExternalTool(
        name: 'kb_read',
        description: '读取知识库某一条的完整内容。参数 path 从 kb_search 或'
            'kb_list 的结果里拿。知识库不塞进上下文，这条读取结果只看本轮。',
        parameters: const {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': '知识文档路径，如 /workspace/.knowledge/xxx.md'
            },
          },
          'required': ['path'],
        },
        origin: '知识库',
        invoke: (args) async {
          final path = args['path']?.toString().trim() ?? '';
          if (path.isEmpty) return '缺少 path。';
          try {
            final doc = await store.read(path);
            return '标题：${doc.title}\n标签：'
                '${doc.tags.isEmpty ? '（无）' : doc.tags.join(' / ')}\n'
                '路径：${doc.path}\n\n${doc.content}';
          } catch (e) {
            return '读取失败：$e';
          }
        },
      ),
      ExternalTool(
        name: 'kb_write',
        description: '写入/覆盖一条知识。这是给 AI 沉淀可复用经验的入口：'
            '当一轮里踩坑后查清了方案、发现了稳定的做法、写了一个可复用的模板/API 流程，'
            '就主动 kb_write 存进知识库，下次同类问题直接搜得到。'
            '与 memory_write 的区别：memory 是个人化短期结论（会自动注入相关度最高的），'
            '知识库是偏结构化、可检索的经验/资料，绝不自动注入。',
        parameters: const {
          'type': 'object',
          'properties': {
            'title': {'type': 'string', 'description': '标题，尽量一句话说清主题'},
            'content': {
              'type': 'string',
              'description': '正文：方案/步骤/代码/注意事项，写成以后能照着用的程度'
            },
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '检索标签，如 青龙、登录、JS插件',
            },
            'existingPath': {
              'type': 'string',
              'description': '更新已有条目时传它的 path；新建不用传',
            },
          },
          'required': ['title', 'content'],
        },
        origin: '知识库',
        isWrite: true,
        invoke: (args) async {
          try {
            final doc = await store.write(
              title: args['title']?.toString() ?? '',
              content: args['content']?.toString() ?? '',
              tags: [
                for (final t in (args['tags'] as List? ?? const []))
                  t.toString().trim(),
              ].where((t) => t.isNotEmpty).toList(),
              existingPath: args['existingPath']?.toString(),
            );
            return '已保存知识「${doc.title}」→ ${doc.path}';
          } catch (e) {
            return '保存知识失败：$e';
          }
        },
      ),
      ExternalTool(
        name: 'kb_delete',
        description: '删除一条过时/错误的知识。发现知识库里有不再成立或写错的条目时主动清理。',
        parameters: const {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': '知识文档路径'},
          },
          'required': ['path'],
        },
        origin: '知识库',
        isWrite: true,
        invoke: (args) async {
          final path = args['path']?.toString().trim() ?? '';
          final ok = await store.delete(path);
          return ok ? '已删除知识 $path' : '删除失败或路径不在知识库内：$path';
        },
      ),
      ExternalTool(
        name: 'kb_list',
        description: '列出知识库全部条目（标题/标签/摘要）。需要知道有什么知识、或找不着准确关键词时用。',
        parameters: const {
          'type': 'object',
          'properties': {
            'limit': {'type': 'integer', 'description': '返回条数，默认 30'},
          },
        },
        origin: '知识库',
        invoke: (args) async {
          final limit = (args['limit'] as num?)?.toInt() ?? 30;
          final docs = await store.list();
          if (docs.isEmpty) return '知识库还是空的。可以主动 kb_write 写入第一条经验。';
          final shown = docs.take(limit).toList();
          return [
            '知识库共 ${docs.length} 条，显示前 ${shown.length} 条：',
            for (final d in shown)
              '- ${d.title}｜${d.tags.isEmpty ? '（无标签）' : d.tags.join('/')}｜${d.snippet}',
            '需要全文用 kb_read，路径见 kb_search / kb_list。',
          ].join('\n');
        },
      ),
    ];
  }

  // ---------------------------------------------------------------- 技能

  static List<ExternalTool> _skillTools(
    SkillNotifier skills,
    List<AiSkill> skillList,
  ) {
    String describe(AiSkill s) =>
        '- ${s.name}（id=${s.id}${s.builtin ? '，内置' : ''}${s.enabled ? '' : '，已停用'}'
        '${s.files.isEmpty ? '' : '，${s.files.length} 个附件/${s.files.where((f) => f.isScript).length} 脚本'}）：${s.description}';

    return [
      ExternalTool(
        name: 'skill_list',
        description: '列出所有技能（含停用的），带 id 便于修改或删除。',
        parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
        origin: '本地技能库',
        invoke: (args) async {
          if (skillList.isEmpty) return '还没有任何技能。';
          return [
            '共 ${skillList.length} 个技能：',
            for (final s in skillList) describe(s)
          ].join('\n');
        },
      ),
      ExternalTool(
        name: 'skill_create',
        description: '新建或覆盖一个技能（操作手册）。'
            '正文要写成给自己看的步骤清单：先做什么、怎么判断、常见坑、禁忌。'
            '想从开源项目装技能时：先用 web_fetch 抓 README/SKILL.md，'
            '读懂后提炼成本 APP 能执行的步骤，再调用这个工具——不要把网页原文整段塞进来。',
        parameters: const {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': '技能名，kebab-case，如 jd-cookie-refresh',
            },
            'description': {'type': 'string', 'description': '一句话说明它能干什么'},
            'when_to_use': {'type': 'string', 'description': '什么场景该加载它'},
            'instructions': {
              'type': 'string',
              'description': '正文，Markdown，步骤化。可以包含模板代码',
            },
            'id': {
              'type': 'string',
              'description': '传已有 id 表示覆盖该技能；留空则新建',
            },
          },
          'required': ['name', 'description', 'instructions'],
        },
        origin: '本地技能库',
        isWrite: true,
        invoke: (args) async {
          final name = args['name']?.toString().trim() ?? '';
          final instructions = args['instructions']?.toString().trim() ?? '';
          if (name.isEmpty || instructions.isEmpty) {
            return '技能名与正文都不能为空。';
          }
          final rawId = args['id']?.toString().trim() ?? '';
          // 内置技能不允许被覆盖成用户技能，否则版本升级会打架。
          final existing = skillList.where((s) => s.id == rawId);
          if (existing.isNotEmpty && existing.first.builtin) {
            return '「${existing.first.name}」是内置技能，不能覆盖。'
                '可以新建一个同类技能，或用 skill_toggle 停用内置的那个。';
          }
          final id = rawId.isNotEmpty
              ? rawId
              : 'user-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
          await skills.upsert(
            AiSkill(
              id: id,
              name: name,
              description: args['description']?.toString().trim() ?? '',
              whenToUse: args['when_to_use']?.toString().trim() ?? '',
              instructions: instructions,
            ),
          );
          return '${rawId.isEmpty ? '已创建' : '已更新'}技能「$name」（id=$id），'
              '下一轮对话起生效。';
        },
      ),
      ExternalTool(
        name: 'skill_delete',
        description: '删除一个用户技能（内置技能删不掉，只能停用）。',
        parameters: const {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '技能 id，用 skill_list 查'},
          },
          'required': ['id'],
        },
        origin: '本地技能库',
        isWrite: true,
        danger: true,
        invoke: (args) async {
          final id = args['id']?.toString().trim() ?? '';
          final matched = skillList.where((s) => s.id == id);
          if (matched.isEmpty) return '没有 id 为 $id 的技能。';
          if (matched.first.builtin) {
            return '「${matched.first.name}」是内置技能，不能删除，只能用 skill_toggle 停用。';
          }
          await skills.remove(id);
          return '已删除技能「${matched.first.name}」。';
        },
      ),
      ExternalTool(
        name: 'skill_toggle',
        description: '启用/停用一个技能。停用后不再注入提示词，也读不到正文。',
        parameters: const {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
            'enabled': {'type': 'boolean'},
          },
          'required': ['id', 'enabled'],
        },
        origin: '本地技能库',
        isWrite: true,
        invoke: (args) async {
          final id = args['id']?.toString().trim() ?? '';
          final matched = skillList.where((s) => s.id == id);
          if (matched.isEmpty) return '没有 id 为 $id 的技能。';
          final enabled = args['enabled'] == true;
          await skills.setEnabled(id, enabled);
          return '技能「${matched.first.name}」已${enabled ? '启用' : '停用'}。';
        },
      ),
    ];
  }

  // ---------------------------------------------------------------- MCP

  static List<ExternalTool> _mcpTools(McpNotifier mcp, McpState mcpState) {
    return [
      ExternalTool(
        name: 'mcp_list',
        description: '列出已接入的 MCP 服务器及其连接状态、工具数。',
        parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
        origin: 'MCP 管理',
        invoke: (args) async {
          if (mcpState.servers.isEmpty) return '还没有接入任何 MCP 服务器。';
          final lines = ['共 ${mcpState.servers.length} 个服务器：'];
          for (final s in mcpState.servers) {
            final st = mcpState.status[s.id];
            final health = st == null
                ? '未检测'
                : st.connecting
                    ? '连接中'
                    : st.ok
                        ? '正常（${st.toolCount} 个工具）'
                        : '异常：${st.error}';
            lines.add(
              '- ${s.name}（id=${s.id}）${s.enabled ? '' : '[已停用]'} '
              '${s.url} → $health',
            );
          }
          return lines.join('\n');
        },
      ),
      ExternalTool(
        name: 'mcp_add',
        description: '接入一个 MCP 服务器（streamable HTTP 端点）并立刻握手验证。'
            '用户给了服务地址/文档链接时，先用 web_fetch 读文档确认端点与鉴权方式，再调这个。',
        parameters: const {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': '显示名，如 搜索服务'},
            'url': {
              'type': 'string',
              'description': '端点地址，如 http://192.168.1.10:8787/mcp',
            },
            'token': {'type': 'string', 'description': '鉴权凭据，没有就留空'},
            'header_name': {
              'type': 'string',
              'description': '鉴权头名，默认 Authorization',
            },
            'header_prefix': {
              'type': 'string',
              'description': '凭据前缀，默认 "Bearer "；有的服务要留空',
            },
            'tool_prefix': {
              'type': 'string',
              'description': '工具名前缀，避免与其它服务器撞名；留空自动生成',
            },
            'id': {'type': 'string', 'description': '传已有 id 表示改配置'},
          },
          'required': ['name', 'url'],
        },
        origin: 'MCP 管理',
        isWrite: true,
        danger: true,
        invoke: (args) async {
          final name = args['name']?.toString().trim() ?? '';
          final url = args['url']?.toString().trim() ?? '';
          if (name.isEmpty || url.isEmpty) return '名称与地址都不能为空。';
          final rawId = args['id']?.toString().trim() ?? '';
          final id = rawId.isNotEmpty
              ? rawId
              : 'mcp-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
          await mcp.upsert(
            McpServerConfig(
              id: id,
              name: name,
              url: url,
              token: args['token']?.toString() ?? '',
              headerName:
                  args['header_name']?.toString().trim().isNotEmpty == true
                      ? args['header_name'].toString().trim()
                      : 'Authorization',
              headerPrefix: args['header_prefix']?.toString() ?? 'Bearer ',
              toolPrefix: args['tool_prefix']?.toString().trim() ?? '',
            ),
          );
          // upsert 内部已经 refreshServer，这里读回状态直接告诉用户成没成。
          final st = mcp.statusOf(id);
          if (st == null) return '已保存服务器「$name」，但还没拿到连接状态。';
          if (st.ok) {
            return '已接入「$name」，握手成功，发现 ${st.toolCount} 个工具。'
                '这些工具下一轮对话起可用。';
          }
          return '已保存「$name」，但连接失败：${st.error}。'
              '检查地址、端口、鉴权头是否正确，改好后用 mcp_add 传同一个 id 更新。';
        },
      ),
      ExternalTool(
        name: 'mcp_remove',
        description: '移除一个 MCP 服务器及其全部工具。',
        parameters: const {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '服务器 id，用 mcp_list 查'},
          },
          'required': ['id'],
        },
        origin: 'MCP 管理',
        isWrite: true,
        danger: true,
        invoke: (args) async {
          final id = args['id']?.toString().trim() ?? '';
          final matched = mcpState.servers.where((s) => s.id == id);
          if (matched.isEmpty) return '没有 id 为 $id 的服务器。';
          await mcp.remove(id);
          return '已移除 MCP 服务器「${matched.first.name}」。';
        },
      ),
      ExternalTool(
        name: 'mcp_toggle',
        description: '启用/停用一个 MCP 服务器。停用后它的工具从工具表里消失。',
        parameters: const {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
            'enabled': {'type': 'boolean'},
          },
          'required': ['id', 'enabled'],
        },
        origin: 'MCP 管理',
        isWrite: true,
        invoke: (args) async {
          final id = args['id']?.toString().trim() ?? '';
          final matched = mcpState.servers.where((s) => s.id == id);
          if (matched.isEmpty) return '没有 id 为 $id 的服务器。';
          final enabled = args['enabled'] == true;
          await mcp.setEnabled(id, enabled);
          return 'MCP 服务器「${matched.first.name}」已${enabled ? '启用' : '停用'}。';
        },
      ),
      ExternalTool(
        name: 'mcp_refresh',
        description: '重新握手并拉取某个服务器的工具清单（连接异常或对方更新后用）。',
        parameters: const {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
        origin: 'MCP 管理',
        invoke: (args) async {
          final id = args['id']?.toString().trim() ?? '';
          if (mcpState.servers.every((s) => s.id != id)) {
            return '没有 id 为 $id 的服务器。';
          }
          await mcp.refreshServer(id);
          final st = mcp.statusOf(id);
          if (st == null) return '刷新完成，但没拿到状态。';
          return st.ok ? '刷新成功，${st.toolCount} 个工具可用。' : '刷新失败：${st.error}';
        },
      ),
    ];
  }

  // ---------------------------------------------------------------- 抓取

  static ExternalTool _webFetchTool() {
    return ExternalTool(
      name: 'web_fetch',
      description: '抓取一个网页/仓库文件的正文（自动把 GitHub/Gitee 网页地址转成 raw，'
          '只给仓库首页时自动找 SKILL.md / README.md）。'
          '用户丢开源项目链接让你装技能、或让你按某份文档接 MCP 时用它。',
      parameters: const {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': '链接'},
          'max_chars': {
            'type': 'integer',
            'description': '最多取多少字符，默认 20000',
          },
        },
        'required': ['url'],
      },
      origin: '网络抓取',
      invoke: (args) async {
        final url = args['url']?.toString().trim() ?? '';
        if (url.isEmpty) return '链接为空。';
        final (finalUrl, body) = await WebFetch.fetch(
          url,
          maxChars: (args['max_chars'] as num?)?.toInt() ?? 20000,
        );
        return '来源：$finalUrl\n\n$body';
      },
    );
  }

  /// 给系统提示用的元能力说明。
  static String promptBlock({
    required int memoryCount,
    required int skillCount,
    required int mcpServerCount,
  }) {
    return [
      '## 自我管理能力（元工具）',
      '- 记忆：memory_write / memory_search / memory_delete。当前 $memoryCount 条。'
          '每次学到跨会话有用的结论（用户偏好、环境事实、踩坑教训）就立刻 memory_write，'
          '别指望下次还记得；发现记忆过时就删掉重写。',
      '- 知识库：kb_search / kb_read / kb_write / kb_delete / kb_list。'
          '知识库**不会自动注入上下文**，只有主动调 kb_search 命中后再 kb_read 才看到；'
          '解决过有复用价值的方案/踩坑/模板，除 memory_write 外也要主动 kb_write 存成条目。',
      '- 技能：skill_list / skill_read / skill_install / skill_run / skill_create / skill_delete / skill_toggle。当前 $skillCount 个。'
          '用户要给市面上的技能仓库（含 SKILL.md 和 scripts 代码）时，直接用 skill_install 完整导入，'
          '不要 web_fetch 抓个 README 再魔改成简化版；带脚本的技能用 skill_run 在终端/青龙跑。'
          '用户说某技能不好用 → skill_read 看现状 → skill_create 传同一个 id 覆盖。'
          '重复踩同一个坑三次以上，主动提议把正确做法写成技能。',
      '- MCP：mcp_list / mcp_add / mcp_remove / mcp_toggle / mcp_refresh。当前 $mcpServerCount 个服务器。'
          '需要青龙以外的能力（联网搜索、控设备、第三方 API）时，先 mcp_list 看有没有，'
          '没有就问用户要端点地址，然后 mcp_add 接入并验证。',
      '- web_fetch：抓网页/仓库正文。装技能、接 MCP、查第三方文档都靠它，别凭记忆编 API。',
      '这些工具改的是你自己的能力，改完在**下一轮对话**生效（当前这一轮的工具表已经定死了）。'
          '所以装完技能/接完 MCP 要告诉用户"下一条消息起可用"，别在同一轮里假装已经能用了。',
    ].join('\n');
  }

  /// 调试用：把工具清单序列化，便于排查名字冲突。
  static String debugNames(List<ExternalTool> tools) =>
      jsonEncode([for (final t in tools) t.name]);
}
