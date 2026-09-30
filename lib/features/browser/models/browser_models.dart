/// WebSocket / SSE 会话里的一条上下行消息。
class WsMessage {
  WsMessage({
    required this.sent,
    required this.text,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final bool sent;
  final String text;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'sent': sent,
        'text': text,
        'at': at.toIso8601String(),
      };
}

/// 浏览器内核抓到的一条请求。
///
/// 只覆盖页面里 `fetch` / `XMLHttpRequest` 发出的请求——这正是"要数据"时
/// 关心的那一类（接口返回的 JSON）。图片、CSS 这些子资源不记，噪音太大。
class CapturedRequest {
  CapturedRequest({
    required this.id,
    required this.method,
    required this.url,
    this.kind = 'fetch',
    this.status = 0,
    this.ok = false,
    this.ms = 0,
    this.requestBody = '',
    this.responseBody = '',
    this.requestHeaders = '',
    this.responseHeaders = '',
    this.contentType = '',
    this.error = '',
    this.mutation = '',
    this.connId = '',
    this.live = false,
    this.wsMessages = const [],
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  final int id;
  final String method;
  final String url;

  /// fetch / xhr / doc（文档导航）。
  final String kind;

  int status;
  bool ok;
  int ms;
  String requestBody;
  String responseBody;

  /// 请求头 / 响应头，一行一个 `k: v`。
  ///
  /// 抓包不给头基本等于没抓包：鉴权在 Authorization、签名在自定义头、
  /// 返回为什么被缓存要看 Cache-Control，光有 body 一个都查不了。
  String requestHeaders;
  String responseHeaders;
  String contentType;
  String error;

  /// 被抓包脚本改写了什么（'改请求体、改请求头'）。空 = 原样放过。
  String mutation;

  /// WebSocket/SSE 连接标识，用于向这条连接继续发数据/关闭。
  String connId;

  /// 会话还活着（WebSocket 已连接 / SSE 连接中）。
  bool live;

  /// WebSocket/SSE 会话的上下行消息列表（一个会话只占一条抓包记录）。
  List<WsMessage> wsMessages;

  final DateTime startedAt;

  bool get pending => status == 0 && error.isEmpty;

  /// 只取路径，列表里显示得下。
  String get shortUrl {
    try {
      final uri = Uri.parse(url);
      final path = uri.path.isEmpty ? '/' : uri.path;
      return uri.hasQuery ? '$path?${uri.query}' : path;
    } catch (_) {
      return url;
    }
  }

  String get host {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return '';
    }
  }

  Map<String, dynamic> toJson() => {
        'method': method,
        'url': url,
        'kind': kind,
        'status': status,
        'ms': ms,
        if (contentType.isNotEmpty) 'contentType': contentType,
        if (requestBody.isNotEmpty) 'requestBody': requestBody,
        if (responseBody.isNotEmpty) 'responseBody': responseBody,
        if (requestHeaders.isNotEmpty) 'requestHeaders': requestHeaders,
        if (responseHeaders.isNotEmpty) 'responseHeaders': responseHeaders,
        if (error.isNotEmpty) 'error': error,
        if (mutation.isNotEmpty) 'mutation': mutation,
        if (connId.isNotEmpty) 'connId': connId,
        if (live) 'live': live,
        if (wsMessages.isNotEmpty)
          'wsMessages': wsMessages.map((m) => m.toJson()).toList(),
      };
}

/// 浏览器代理配置。
///
/// 支持 http / https / socks5 三种 scheme，保存用户名密码后按
/// `scheme://user:pass@host:port` 生成内核规则（部分 WebView 内核可能
/// 不支持 URL 里的账号密码，遇到鉴权代理建议先用无鉴权测试）。
class BrowserProxy {
  BrowserProxy({
    String? id,
    required this.name,
    required this.scheme,
    required this.host,
    required this.port,
    this.username = '',
    this.password = '',
    this.bypass = '',
  }) : id = id ?? 'p${DateTime.now().microsecondsSinceEpoch}';

  final String id;
  String name;
  String scheme;
  String host;
  int port;
  String username;
  String password;
  String bypass;

  String get url {
    final auth = username.isEmpty
        ? ''
        : '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}@';
    return '$scheme://$auth$host:$port';
  }

  String get label {
    final auth = username.isEmpty ? '' : '$username@';
    return '$name（$scheme://$auth$host:$port）';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'scheme': scheme,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'bypass': bypass,
      };

  factory BrowserProxy.fromJson(Map<String, dynamic> json) => BrowserProxy(
        id: json['id']?.toString(),
        name: json['name']?.toString() ?? '',
        scheme: json['scheme']?.toString() ?? 'http',
        host: json['host']?.toString() ?? '',
        port: (json['port'] as num?)?.toInt() ?? 8080,
        username: json['username']?.toString() ?? '',
        password: json['password']?.toString() ?? '',
        bypass: json['bypass']?.toString() ?? '',
      );
}

/// 页面里 console.* 的一行输出。注入脚本调试时看它。
/// 页面里 console.* 的一行输出。注入脚本调试时看它。
class ConsoleLine {
  ConsoleLine({required this.level, required this.text, DateTime? at})
      : at = at ?? DateTime.now();

  final String level;
  final String text;
  final DateTime at;
}

/// 重发抓包请求后拿到的原始结果。
class ReplayResult {
  ReplayResult({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.ms,
    this.error = '',
  });

  final int statusCode;
  final Map<String, String> headers;
  final String body;
  final int ms;
  final String error;

  bool get ok => error.isEmpty && statusCode >= 200 && statusCode < 300;
}
