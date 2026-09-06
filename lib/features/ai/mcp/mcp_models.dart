import 'dart:convert';

/// MCP 服务器配置。
class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.token = '',
    this.enabled = true,
    this.headerName = 'Authorization',
    this.headerPrefix = 'Bearer ',
    this.toolPrefix = '',
  });

  final String id;
  final String name;

  /// streamable HTTP 端点，例如 http://192.168.1.10:8787/mcp
  final String url;

  /// 鉴权凭据（可空）。
  final String token;
  final bool enabled;

  /// 鉴权头名与前缀，兼容各家实现（Authorization: Bearer xxx / X-Token: xxx）。
  final String headerName;
  final String headerPrefix;

  /// 工具名前缀，避免多个服务器的同名工具互相覆盖。留空则用 name 生成。
  final String toolPrefix;

  String get effectivePrefix {
    if (toolPrefix.isNotEmpty) return toolPrefix;
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return slug.isEmpty ? 'mcp' : slug;
  }

  Map<String, String> get headers {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
    };
    if (token.isNotEmpty) h[headerName] = '$headerPrefix$token';
    return h;
  }

  McpServerConfig copyWith({
    String? name,
    String? url,
    String? token,
    bool? enabled,
    String? headerName,
    String? headerPrefix,
    String? toolPrefix,
  }) {
    return McpServerConfig(
      id: id,
      name: name ?? this.name,
      url: url ?? this.url,
      token: token ?? this.token,
      enabled: enabled ?? this.enabled,
      headerName: headerName ?? this.headerName,
      headerPrefix: headerPrefix ?? this.headerPrefix,
      toolPrefix: toolPrefix ?? this.toolPrefix,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'token': token,
        'enabled': enabled,
        'headerName': headerName,
        'headerPrefix': headerPrefix,
        'toolPrefix': toolPrefix,
      };

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    return McpServerConfig(
      id: json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? 'MCP',
      url: json['url']?.toString() ?? '',
      token: json['token']?.toString() ?? '',
      enabled: json['enabled'] as bool? ?? true,
      headerName: json['headerName']?.toString() ?? 'Authorization',
      headerPrefix: json['headerPrefix']?.toString() ?? 'Bearer ',
      toolPrefix: json['toolPrefix']?.toString() ?? '',
    );
  }
}

/// MCP 服务器上的一个工具。
class McpToolInfo {
  const McpToolInfo({
    required this.serverId,
    required this.name,
    required this.localName,
    required this.description,
    required this.schema,
  });

  final String serverId;

  /// 服务器上的原始工具名。
  final String name;

  /// 暴露给模型的名字（带前缀）。
  final String localName;
  final String description;
  final Map<String, dynamic> schema;

  /// 猜这个外部工具是不是只读。
  ///
  /// MCP 协议本身不声明副作用，全当危险操作会让"查一下电量"这种事也弹确认，
  /// 体验很糟。于是按名字与描述做保守判断：明显是查询的放行，其余按写操作处理。
  bool get looksReadOnly {
    final n = name.toLowerCase();
    const writeHints = [
      'write',
      'delete',
      'remove',
      'set',
      'put',
      'update',
      'create',
      'add',
      'send',
      'exec',
      'run',
      'install',
      'uninstall',
      'kill',
      'stop',
      'start',
      'restart',
      'reboot',
      'move',
      'copy',
      'rename',
      'clear',
      'click',
      'tap',
      'input',
      'swipe',
      'call',
      'edit',
      'mkdir',
      'touch',
      'chmod',
      'chown',
      'control',
      'act',
      'record',
      'photo',
      'vibrate',
      'launch',
      'open',
    ];
    for (final hint in writeHints) {
      if (n.contains(hint)) return false;
    }
    const readHints = [
      'get',
      'list',
      'read',
      'status',
      'info',
      'dump',
      'stat',
      'search',
      'find',
      'query',
      'scan',
      'check',
      'probe',
      'log',
      'watch',
      'wait',
      'screenshot',
      'permissions',
    ];
    for (final hint in readHints) {
      if (n.contains(hint)) return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'name': name,
        'localName': localName,
        'description': description,
        'schema': jsonEncode(schema),
      };

  factory McpToolInfo.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> schema = const {};
    final raw = json['schema'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) schema = decoded;
      } catch (_) {
        // 坏数据忽略，工具仍可无参调用。
      }
    } else if (raw is Map<String, dynamic>) {
      schema = raw;
    }
    return McpToolInfo(
      serverId: json['serverId']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      localName: json['localName']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      schema: schema,
    );
  }
}

/// 一台服务器的连接状态。
class McpServerStatus {
  const McpServerStatus({
    this.connecting = false,
    this.ok = false,
    this.error = '',
    this.serverInfo = '',
    this.toolCount = 0,
    this.checkedAt,
  });

  final bool connecting;
  final bool ok;
  final String error;
  final String serverInfo;
  final int toolCount;
  final DateTime? checkedAt;

  McpServerStatus copyWith({
    bool? connecting,
    bool? ok,
    String? error,
    String? serverInfo,
    int? toolCount,
    DateTime? checkedAt,
  }) {
    return McpServerStatus(
      connecting: connecting ?? this.connecting,
      ok: ok ?? this.ok,
      error: error ?? this.error,
      serverInfo: serverInfo ?? this.serverInfo,
      toolCount: toolCount ?? this.toolCount,
      checkedAt: checkedAt ?? this.checkedAt,
    );
  }
}
