import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/utils/logger.dart';
import 'mcp_models.dart';

/// 最小可用的 MCP 客户端（Streamable HTTP + JSON-RPC 2.0）。
///
/// 只实现 Agent 需要的三件事：initialize / tools/list / tools/call。
/// 响应可能是纯 JSON，也可能是 SSE（`data: {...}`），两种都解析。
class McpClient {
  McpClient(this.config)
      : _dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 12),
            receiveTimeout: const Duration(seconds: 120),
            sendTimeout: const Duration(seconds: 20),
            // 自己判断状态码，便于把服务端错误正文带给模型。
            validateStatus: (_) => true,
            responseType: ResponseType.plain,
          ),
        );

  final McpServerConfig config;
  final Dio _dio;

  String? _sessionId;
  int _id = 0;
  bool _handshaked = false;
  Future<String>? _handshake;

  static const _protocolVersion = '2024-11-05';

  /// 确保握手过一次。冷启动时工具清单来自本地缓存，此时并没有会话，
  /// 直接调用工具会被服务端以 "session required" 拒绝——所以每次调用前
  /// 都走这里，已握手就直接返回，不会重复请求。
  Future<void> ensureSession() async {
    if (_handshaked) return;
    _handshake ??= initialize();
    try {
      await _handshake;
      _handshaked = true;
    } catch (_) {
      // 失败要清掉，下次调用才能重试。
      _handshake = null;
      rethrow;
    }
  }

  /// 外部（provider 刷新流程）已经完成握手时告知一声，省掉一次重复请求。
  void markHandshaked() => _handshaked = true;

  /// 会话失效（服务端重启、超时）后重来一遍。
  void resetSession() {
    _handshaked = false;
    _handshake = null;
    _sessionId = null;
  }

  /// 握手。返回服务器自述信息（name + version）。
  Future<String> initialize() async {
    final result = await _call(
      'initialize',
      {
        'protocolVersion': _protocolVersion,
        'capabilities': {'tools': <String, dynamic>{}},
        'clientInfo': {'name': 'qinglong-flutter', 'version': '1.0.0'},
      },
      expectSession: true,
    );
    // 通知服务端握手结束，部分实现要求这一步。
    try {
      await _notify('notifications/initialized');
    } catch (_) {
      // 可选步骤，失败不影响后续调用。
    }
    final info = result['serverInfo'];
    if (info is Map) {
      return '${info['name'] ?? 'mcp'} ${info['version'] ?? ''}'.trim();
    }
    return 'mcp';
  }

  /// 列出工具。
  Future<List<McpToolInfo>> listTools() async {
    final result = await _call('tools/list', const {});
    final raw = result['tools'];
    if (raw is! List) return const [];
    final prefix = config.effectivePrefix;
    return [
      for (final item in raw)
        if (item is Map<String, dynamic>)
          McpToolInfo(
            serverId: config.id,
            name: item['name']?.toString() ?? '',
            localName: '${prefix}__${item['name']}',
            description: item['description']?.toString() ?? '',
            schema: item['inputSchema'] is Map<String, dynamic>
                ? item['inputSchema'] as Map<String, dynamic>
                : const {'type': 'object', 'properties': {}},
          ),
    ].where((t) => t.name.isNotEmpty).toList();
  }

  /// 调用工具，返回拼好的文本结果。
  Future<String> callTool(String name, Map<String, dynamic> args) async {
    await ensureSession();
    Map<String, dynamic> result;
    try {
      result = await _call('tools/call', {'name': name, 'arguments': args});
    } on StateError catch (e) {
      // 会话过期：重新握手后再试一次，避免让模型看到内部错误。
      if (!_isSessionError(e.message)) rethrow;
      resetSession();
      await ensureSession();
      result = await _call('tools/call', {'name': name, 'arguments': args});
    }
    _handshaked = true;
    final isError = result['isError'] == true;
    final content = result['content'];
    final buffer = StringBuffer();
    if (content is List) {
      for (final part in content) {
        if (part is! Map) continue;
        final type = part['type']?.toString();
        if (type == 'text') {
          buffer.writeln(part['text']?.toString() ?? '');
        } else if (type == 'image') {
          buffer.writeln('[图片内容，无法在文本里展示]');
        } else {
          buffer.writeln(jsonEncode(part));
        }
      }
    } else if (content != null) {
      buffer.writeln(jsonEncode(content));
    }
    final text = buffer.toString().trim();
    if (isError) {
      throw StateError(text.isEmpty ? 'MCP 工具返回错误' : text);
    }
    return text.isEmpty ? '（无返回内容）' : text;
  }

  static bool _isSessionError(String message) {
    final lower = message.toLowerCase();
    return lower.contains('session required') ||
        lower.contains('session not found') ||
        lower.contains('invalid session') ||
        lower.contains('mcp-session-id');
  }

  Future<void> _notify(String method) async {
    await _post({'jsonrpc': '2.0', 'method': method});
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> params, {
    bool expectSession = false,
  }) async {
    _id += 1;
    final response = await _post({
      'jsonrpc': '2.0',
      'id': _id,
      'method': method,
      if (params.isNotEmpty) 'params': params,
    });

    if (expectSession) {
      final sid = response.headers.value('mcp-session-id') ??
          response.headers.value('MCP-Session-Id');
      if (sid != null && sid.isNotEmpty) _sessionId = sid;
    }

    final status = response.statusCode ?? 0;
    final body = response.data?.toString() ?? '';
    if (status >= 400) {
      throw StateError('HTTP $status：${_clip(body)}');
    }
    final payload = _decode(body);
    if (payload == null) {
      throw StateError('无法解析 MCP 响应：${_clip(body)}');
    }
    final error = payload['error'];
    if (error is Map) {
      throw StateError(
        'MCP 错误 ${error['code']}：${error['message'] ?? ''} ${error['data'] ?? ''}'
            .trim(),
      );
    }
    final result = payload['result'];
    if (result is Map<String, dynamic>) return result;
    return const {};
  }

  Future<Response<dynamic>> _post(Map<String, dynamic> body) async {
    final headers = Map<String, String>.from(config.headers);
    if (_sessionId != null) headers['MCP-Session-Id'] = _sessionId!;
    try {
      return await _dio.post<dynamic>(
        config.url,
        data: jsonEncode(body),
        options: Options(headers: headers),
      );
    } on DioException catch (e) {
      Logger.e('mcp', 'post failed ${config.url}', e);
      throw StateError(_dioMessage(e));
    }
  }

  /// 兼容 SSE：取最后一条 data 行。
  Map<String, dynamic>? _decode(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return const {};
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // 落到 SSE 分支再试。
      }
    }
    Map<String, dynamic>? last;
    for (final line in const LineSplitter().convert(trimmed)) {
      if (!line.startsWith('data:')) continue;
      final chunk = line.substring(5).trim();
      if (chunk.isEmpty || chunk == '[DONE]') continue;
      try {
        final decoded = jsonDecode(chunk);
        if (decoded is Map<String, dynamic>) last = decoded;
      } catch (_) {
        // 跳过噪声行。
      }
    }
    return last;
  }

  static String _dioMessage(DioException e) {
    return switch (e.type) {
      DioExceptionType.connectionTimeout => 'MCP 连接超时，检查地址与端口',
      DioExceptionType.receiveTimeout => 'MCP 响应超时',
      DioExceptionType.connectionError =>
        'MCP 无法连接：${e.message ?? ''}（同一网络？地址写对了？）',
      _ => 'MCP 请求失败：${e.message ?? e.type.name}',
    };
  }

  static String _clip(String text, {int max = 400}) =>
      text.length <= max ? text : '${text.substring(0, max)}…';
}
