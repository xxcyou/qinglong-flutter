import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/glass_scaffold.dart';
import '../mcp/mcp_client.dart';
import '../mcp/mcp_models.dart';
import '../mcp/mcp_provider.dart';
import '../../../shared/mono_text.dart';

/// MCP 服务器管理：接入外部工具，让 AI 具备青龙之外的能力
/// （联网搜索、控制其他系统、调第三方 API…）。
class McpServerPage extends ConsumerWidget {
  const McpServerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(mcpProvider);
    final notifier = ref.read(mcpProvider.notifier);

    return GlassScaffold(
      title: 'MCP 扩展',
      subtitle: state.servers.isEmpty
          ? '接入外部工具服务器'
          : '${state.servers.length} 台服务器 · ${state.tools.length} 个工具',
      actions: [
        IconButton(
          tooltip: '全部重连',
          onPressed: state.loading ? null : notifier.refreshAll,
          icon: state.loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              : const Icon(Icons.refresh, size: 20),
        ),
        IconButton(
          tooltip: '添加服务器',
          onPressed: () => _edit(context, ref, null),
          icon: const Icon(Icons.add, size: 22),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 54),
        children: [
          const _Intro(),
          if (state.servers.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(
                child: Text(
                  '还没有 MCP 服务器\n点右上角 + 添加',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
          for (final server in state.servers) ...[
            const SizedBox(height: 10),
            _ServerCard(
              server: server,
              status: state.status[server.id] ?? const McpServerStatus(),
              tools: state.toolsOf(server.id),
              onEdit: () => _edit(context, ref, server),
              onToggle: (v) => notifier.setEnabled(server.id, v),
              onRefresh: () => notifier.refreshServer(server.id),
              onDelete: () async {
                final ok = await showConfirmDialog(
                  context,
                  title: '删除服务器',
                  message: '删除「${server.name}」后，AI 将失去它提供的工具。',
                  confirmText: '删除',
                  destructive: true,
                );
                if (ok) await notifier.remove(server.id);
              },
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    McpServerConfig? server,
  ) async {
    final result = await Navigator.of(context).push<McpServerConfig>(
      MaterialPageRoute(builder: (_) => _McpEditPage(server: server)),
    );
    if (result != null) {
      await ref.read(mcpProvider.notifier).upsert(result);
    }
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      child: Row(
        children: [
          Icon(Icons.extension_outlined, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'MCP 服务器提供的工具会自动出现在 AI 的工具列表里。'
              '外部工具的副作用无法预判，因此默认按"危险操作"处理：'
              '除了"全部放行"策略，调用前都会先问你。',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.status,
    required this.tools,
    required this.onEdit,
    required this.onToggle,
    required this.onRefresh,
    required this.onDelete,
  });

  final McpServerConfig server;
  final McpServerStatus status;
  final List<McpToolInfo> tools;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRefresh;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color dot;
    final String stateText;
    if (!server.enabled) {
      dot = scheme.outline;
      stateText = '已停用';
    } else if (status.connecting) {
      dot = scheme.tertiary;
      stateText = '连接中…';
    } else if (status.ok) {
      dot = Colors.green;
      stateText = '已连接 · ${status.serverInfo}';
    } else if (status.error.isNotEmpty) {
      dot = scheme.error;
      stateText = '连接失败';
    } else {
      dot = scheme.outline;
      stateText = '未连接';
    }

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
      onTap: onEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  server.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Switch(
                value: server.enabled,
                onChanged: onToggle,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 19),
                onSelected: (v) {
                  if (v == 'refresh') onRefresh();
                  if (v == 'edit') onEdit();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'refresh', child: Text('重新连接')),
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
          Text(
            server.url,
            style: TextStyle(
              fontSize: 11.5,
              fontFamily: kMonoFamily,
              fontFamilyFallback: kMonoFallback,
              color: scheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            stateText,
            style: TextStyle(
              fontSize: 12,
              color:
                  status.ok ? Colors.green.shade700 : scheme.onSurfaceVariant,
            ),
          ),
          if (status.error.isNotEmpty && !status.ok)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                status.error,
                style: TextStyle(fontSize: 11.5, color: scheme.error),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (tools.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in tools)
                  Tooltip(
                    message: [
                      t.description.isEmpty ? t.name : t.description,
                      t.looksReadOnly ? '（只读，直接执行）' : '（写操作，按策略确认）',
                    ].join('\n'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: t.looksReadOnly
                            ? scheme.primaryContainer.withValues(alpha: 0.5)
                            : scheme.errorContainer.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            t.looksReadOnly
                                ? Icons.visibility_outlined
                                : Icons.edit_outlined,
                            size: 11,
                          ),
                          const SizedBox(width: 3),
                          Text(t.name, style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _McpEditPage extends StatefulWidget {
  const _McpEditPage({this.server});

  final McpServerConfig? server;

  @override
  State<_McpEditPage> createState() => _McpEditPageState();
}

class _McpEditPageState extends State<_McpEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _token;
  late final TextEditingController _headerName;
  late final TextEditingController _headerPrefix;
  late final TextEditingController _prefix;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    final s = widget.server;
    _name = TextEditingController(text: s?.name ?? '');
    _url = TextEditingController(text: s?.url ?? '');
    _token = TextEditingController(text: s?.token ?? '');
    _headerName = TextEditingController(text: s?.headerName ?? 'Authorization');
    _headerPrefix = TextEditingController(text: s?.headerPrefix ?? 'Bearer ');
    _prefix = TextEditingController(text: s?.toolPrefix ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    _headerName.dispose();
    _headerPrefix.dispose();
    _prefix.dispose();
    super.dispose();
  }

  McpServerConfig _build() {
    return McpServerConfig(
      id: widget.server?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _name.text.trim(),
      url: _url.text.trim(),
      token: _token.text.trim(),
      enabled: widget.server?.enabled ?? true,
      headerName: _headerName.text.trim().isEmpty
          ? 'Authorization'
          : _headerName.text.trim(),
      headerPrefix: _headerPrefix.text,
      toolPrefix: _prefix.text.trim(),
    );
  }

  Future<void> _test() async {
    if (_formKey.currentState?.validate() != true) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    // 直接用一次性客户端试连，不落库，免得测坏的地址污染配置。
    final result = await _testConnection(_build());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = result.$1;
      _testResult = result.$2;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassScaffold(
      title: widget.server == null ? '添加 MCP 服务器' : '编辑 MCP 服务器',
      showBack: true,
      actions: [
        IconButton(
          tooltip: '保存',
          onPressed: () {
            if (_formKey.currentState?.validate() != true) return;
            Navigator.of(context).pop(_build());
          },
          icon: const Icon(Icons.check, size: 22),
        ),
      ],
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 54),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '例如 联网搜索',
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? '请填名称' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: '端点 URL',
                hintText: 'http://192.168.1.10:8787/mcp',
              ),
              validator: (v) {
                final text = v?.trim() ?? '';
                if (text.isEmpty) return '请填 URL';
                final uri = Uri.tryParse(text);
                if (uri == null || !uri.hasScheme) return 'URL 格式不对';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _token,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '凭据（可空）',
                hintText: 'token / api key',
              ),
            ),
            const SectionLabel('高级'),
            TextFormField(
              controller: _headerName,
              decoration: const InputDecoration(labelText: '鉴权头名'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _headerPrefix,
              decoration: const InputDecoration(
                labelText: '凭据前缀',
                hintText: 'Bearer （含末尾空格）',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _prefix,
              decoration: const InputDecoration(
                labelText: '工具名前缀（可空）',
                hintText: '留空则按名称自动生成',
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering),
              label: Text(_testing ? '连接中…' : '测试连接'),
            ),
            if (_testResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: GlassPanel(
                  radius: 14,
                  blur: 10,
                  padding: const EdgeInsets.all(12),
                  tint: _testOk ? Colors.green : scheme.error,
                  child: Text(
                    _testResult!,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 独立试连：避免把未保存的配置写进 provider。
Future<(bool, String)> _testConnection(McpServerConfig config) async {
  try {
    final client = McpClient(config);
    final info = await client.initialize();
    final tools = await client.listTools();
    final names = tools.map((t) => t.name).take(8).join('、');
    return (
      true,
      '连接成功：$info\n发现 ${tools.length} 个工具${tools.isEmpty ? '' : '：$names'}',
    );
  } catch (e) {
    return (false, '连接失败：$e');
  }
}
