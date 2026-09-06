import '../mcp/mcp_provider.dart';
import 'external_tool.dart';

/// MCP 工具网关：把几十个 MCP 工具收成 3 个入口，省掉巨额 tools schema 开销。
///
/// 为什么必须这么做：OpenAI 兼容协议里 tools 数组要**每一轮**完整重发。
/// 接了 74 个 MCP 工具时，光工具表就有几万 token，一个简单问题跑 5 轮就是十几万
/// token——这正是"一个简单问题也很贵"的主因。
///
/// 折叠后：
/// - 提示词里给一份紧凑目录（一行一个工具，只有名字 + 一句话）；
/// - 需要参数细节时调 mcp_describe 拿单个工具的 schema；
/// - 执行分两个入口：mcp_query（只读，直接执行）与 mcp_invoke（有副作用，按策略确认）。
///
/// 这样既不丢能力，也把常驻开销从"几万"压到"几百"。
class McpGateway {
  const McpGateway._();

  /// 超过这个数量才折叠。工具少的时候直接暴露原生 schema，模型用起来更准。
  static const collapseThreshold = 10;

  /// 目录里最多列多少个工具，避免提示词也被撑爆。
  static const catalogLimit = 120;

  static bool shouldCollapse(int toolCount) => toolCount > collapseThreshold;

  /// 紧凑目录：一行一个工具。比 JSON schema 省一个数量级。
  static String promptCatalog(McpState state) {
    final enabledServers = {
      for (final s in state.servers)
        if (s.enabled) s.id: s.name,
    };
    final tools = [
      for (final t in state.tools)
        if (enabledServers.containsKey(t.serverId)) t,
    ];
    if (tools.isEmpty) return '';
    final lines = <String>[
      '## 扩展工具目录（MCP，共 ${tools.length} 个）',
      '为省上下文，这些工具没有逐个展开 schema，统一走三个入口：',
      '- mcp_describe(name)：拿某个工具的参数说明。**参数不确定时必须先 describe，别猜字段名。**',
      '- mcp_query(name, args)：执行只读类工具（查询、读取、截图等），直接执行不用确认。',
      '- mcp_invoke(name, args)：执行有副作用的工具（写入、控制、发送等），按确认策略挂起。',
      '目录：',
    ];
    for (final t in tools.take(catalogLimit)) {
      final server = enabledServers[t.serverId] ?? '';
      final desc = t.description.isEmpty ? t.name : t.description;
      final short = desc.length > 90 ? '${desc.substring(0, 90)}…' : desc;
      lines.add(
        '- ${t.localName}${t.looksReadOnly ? '' : ' [写]'}（$server）：'
        '${short.replaceAll('\n', ' ')}',
      );
    }
    if (tools.length > catalogLimit) {
      lines
          .add('（还有 ${tools.length - catalogLimit} 个未列出，用 mcp_describe 按名字查。）');
    }
    return lines.join('\n');
  }

  /// 三个网关工具。
  static List<ExternalTool> build({
    required McpState state,
    required McpNotifier notifier,
  }) {
    final enabledIds = {
      for (final s in state.servers)
        if (s.enabled) s.id,
    };
    final tools = [
      for (final t in state.tools)
        if (enabledIds.contains(t.serverId)) t,
    ];
    if (tools.isEmpty) return const [];

    Map<String, dynamic> byName(String name) {
      for (final t in tools) {
        if (t.localName == name || t.name == name) {
          return {
            'localName': t.localName,
            'description': t.description,
            'schema': t.schema,
            'readOnly': t.looksReadOnly,
          };
        }
      }
      return const {};
    }

    String suggest(String name) {
      final key = name.toLowerCase();
      final hits = [
        for (final t in tools)
          if (t.localName.toLowerCase().contains(key) ||
              t.name.toLowerCase().contains(key))
            t.localName,
      ].take(8).toList();
      return hits.isEmpty
          ? '目录里没有名字包含「$name」的工具。'
          : '没有叫「$name」的工具。名字接近的有：${hits.join('、')}';
    }

    const nameParam = {
      'name': {'type': 'string', 'description': '工具名，取自扩展工具目录（形如 前缀__工具名）'},
    };

    return [
      ExternalTool(
        name: 'mcp_describe',
        description: '查一个扩展工具的完整参数说明（JSON schema）。'
            '不确定字段名或必填项时先调它，别凭猜测传参。'
            '也可以传关键词模糊搜索工具名。',
        parameters: const {
          'type': 'object',
          'properties': nameParam,
          'required': ['name'],
        },
        origin: 'MCP 网关',
        invoke: (args) async {
          final name = args['name']?.toString().trim() ?? '';
          if (name.isEmpty) return '要查哪个工具？传 name。';
          final info = byName(name);
          if (info.isEmpty) return suggest(name);
          return [
            '工具：${info['localName']}',
            '类型：${info['readOnly'] == true ? '只读（用 mcp_query 执行）' : '有副作用（用 mcp_invoke 执行）'}',
            '说明：${info['description']}',
            '参数 schema：',
            _encode(info['schema']),
          ].join('\n');
        },
      ),
      ExternalTool(
        name: 'mcp_query',
        description: '执行一个**只读**扩展工具（查询/读取/状态/截图）。'
            '不确定参数就先 mcp_describe。写类工具会被拒绝，请改用 mcp_invoke。',
        parameters: const {
          'type': 'object',
          'properties': {
            ...nameParam,
            'args': {
              'type': 'object',
              'description': '传给该工具的参数对象，没有参数就传 {}',
            },
          },
          'required': ['name'],
        },
        origin: 'MCP 网关',
        invoke: (args) async {
          final name = args['name']?.toString().trim() ?? '';
          final info = byName(name);
          if (info.isEmpty) return suggest(name);
          if (info['readOnly'] != true) {
            return '「$name」有副作用，不能用 mcp_query。改用 mcp_invoke 调用它。';
          }
          return notifier.callTool(
            info['localName'] as String,
            _asMap(args['args']),
          );
        },
      ),
      ExternalTool(
        name: 'mcp_invoke',
        description: '执行一个**有副作用**的扩展工具（写入/控制/发送/安装等）。'
            '不确定参数就先 mcp_describe。只读工具请用 mcp_query，省一次确认。',
        parameters: const {
          'type': 'object',
          'properties': {
            ...nameParam,
            'args': {
              'type': 'object',
              'description': '传给该工具的参数对象，没有参数就传 {}',
            },
          },
          'required': ['name'],
        },
        origin: 'MCP 网关',
        isWrite: true,
        danger: true,
        invoke: (args) async {
          final name = args['name']?.toString().trim() ?? '';
          final info = byName(name);
          if (info.isEmpty) return suggest(name);
          return notifier.callTool(
            info['localName'] as String,
            _asMap(args['args']),
          );
        },
      ),
    ];
  }

  static Map<String, dynamic> _asMap(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return const {};
  }

  static String _encode(Object? schema) {
    if (schema is Map && schema.isEmpty) return '（无参数）';
    return schema.toString();
  }
}
