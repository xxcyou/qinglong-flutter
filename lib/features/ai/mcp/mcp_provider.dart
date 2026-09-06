import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/logger.dart';
import 'mcp_client.dart';
import 'mcp_models.dart';

class McpState {
  const McpState({
    this.servers = const [],
    this.tools = const [],
    this.status = const {},
    this.loading = false,
  });

  final List<McpServerConfig> servers;

  /// 所有启用服务器的工具，扁平后直接喂给 Agent。
  final List<McpToolInfo> tools;
  final Map<String, McpServerStatus> status;
  final bool loading;

  McpState copyWith({
    List<McpServerConfig>? servers,
    List<McpToolInfo>? tools,
    Map<String, McpServerStatus>? status,
    bool? loading,
  }) {
    return McpState(
      servers: servers ?? this.servers,
      tools: tools ?? this.tools,
      status: status ?? this.status,
      loading: loading ?? this.loading,
    );
  }

  List<McpToolInfo> toolsOf(String serverId) =>
      tools.where((t) => t.serverId == serverId).toList();
}

class McpNotifier extends Notifier<McpState> {
  static const _serversKey = 'mcp_servers_v1';
  static const _toolsKey = 'mcp_tools_cache_v1';

  final _clients = <String, McpClient>{};

  @override
  McpState build() {
    Future.microtask(load);
    return const McpState();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawServers = prefs.getString(_serversKey);
      final servers = <McpServerConfig>[];
      if (rawServers != null && rawServers.isNotEmpty) {
        final decoded = jsonDecode(rawServers);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              servers.add(McpServerConfig.fromJson(item));
            }
          }
        }
      }
      // 工具清单缓存下来，冷启动时 AI 就已经"带着"这些工具，
      // 不必等用户手动点刷新。
      final rawTools = prefs.getString(_toolsKey);
      final tools = <McpToolInfo>[];
      if (rawTools != null && rawTools.isNotEmpty) {
        final decoded = jsonDecode(rawTools);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              tools.add(McpToolInfo.fromJson(item));
            }
          }
        }
      }
      final enabledIds =
          servers.where((s) => s.enabled).map((s) => s.id).toSet();
      state = state.copyWith(
        servers: servers,
        tools: tools.where((t) => enabledIds.contains(t.serverId)).toList(),
      );
    } catch (e) {
      Logger.e('mcp', 'load config failed', e);
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _serversKey,
        jsonEncode([for (final s in state.servers) s.toJson()]),
      );
      await prefs.setString(
        _toolsKey,
        jsonEncode([for (final t in state.tools) t.toJson()]),
      );
    } catch (e) {
      Logger.e('mcp', 'persist failed', e);
    }
  }

  Future<void> upsert(McpServerConfig config) async {
    final list = [...state.servers];
    final index = list.indexWhere((s) => s.id == config.id);
    if (index < 0) {
      list.add(config);
    } else {
      list[index] = config;
    }
    _clients.remove(config.id);
    state = state.copyWith(servers: list);
    await _persist();
    if (config.enabled) await refreshServer(config.id);
  }

  Future<void> remove(String id) async {
    _clients.remove(id);
    state = state.copyWith(
      servers: state.servers.where((s) => s.id != id).toList(),
      tools: state.tools.where((t) => t.serverId != id).toList(),
      status: {...state.status}..remove(id),
    );
    await _persist();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final list = [
      for (final s in state.servers)
        if (s.id == id) s.copyWith(enabled: enabled) else s,
    ];
    state = state.copyWith(
      servers: list,
      tools: enabled
          ? state.tools
          : state.tools.where((t) => t.serverId != id).toList(),
    );
    await _persist();
    if (enabled) await refreshServer(id);
  }

  McpClient _clientFor(McpServerConfig config) {
    return _clients.putIfAbsent(config.id, () => McpClient(config));
  }

  /// 握手 + 拉工具。失败时保留旧工具，只更新状态，避免一次网络抖动
  /// 就让 AI 突然"失去"这些能力。
  Future<void> refreshServer(String id) async {
    final matched = state.servers.where((s) => s.id == id);
    if (matched.isEmpty) return;
    final config = matched.first;
    _setStatus(id, const McpServerStatus(connecting: true));
    try {
      // 每次刷新用新客户端，避免旧 session 失效。
      _clients.remove(id);
      final client = _clientFor(config);
      final info = await client.initialize();
      client.markHandshaked();
      final tools = await client.listTools();
      state = state.copyWith(
        tools: [
          ...state.tools.where((t) => t.serverId != id),
          ...tools,
        ],
      );
      _setStatus(
        id,
        McpServerStatus(
          ok: true,
          serverInfo: info,
          toolCount: tools.length,
          checkedAt: DateTime.now(),
        ),
      );
      await _persist();
    } catch (e) {
      _setStatus(
        id,
        McpServerStatus(
          ok: false,
          error: e.toString(),
          toolCount: state.toolsOf(id).length,
          checkedAt: DateTime.now(),
        ),
      );
    }
  }

  Future<void> refreshAll() async {
    state = state.copyWith(loading: true);
    for (final server in state.servers.where((s) => s.enabled)) {
      await refreshServer(server.id);
    }
    state = state.copyWith(loading: false);
  }

  void _setStatus(String id, McpServerStatus status) {
    state = state.copyWith(status: {...state.status, id: status});
  }

  /// 供 Agent 调用：按暴露给模型的名字执行。
  Future<String> callTool(String localName, Map<String, dynamic> args) async {
    final matched = state.tools.where((t) => t.localName == localName);
    if (matched.isEmpty) {
      throw StateError('未知的 MCP 工具：$localName');
    }
    final tool = matched.first;
    final servers = state.servers.where((s) => s.id == tool.serverId);
    if (servers.isEmpty) {
      throw StateError('MCP 服务器已被删除：${tool.serverId}');
    }
    final config = servers.first;
    if (!config.enabled) {
      throw StateError('MCP 服务器「${config.name}」已停用');
    }
    return _clientFor(config).callTool(tool.name, args);
  }

  bool isMcpTool(String localName) =>
      state.tools.any((t) => t.localName == localName);

  /// 读回某个服务器的最新状态。
  ///
  /// 给 AI 的 mcp_add / mcp_refresh 工具用：它们 await 完刷新后要立刻知道成没成，
  /// 而外部拿不到 Notifier.state（那是 protected 的）。
  McpServerStatus? statusOf(String id) => state.status[id];
}

final mcpProvider = NotifierProvider<McpNotifier, McpState>(McpNotifier.new);
