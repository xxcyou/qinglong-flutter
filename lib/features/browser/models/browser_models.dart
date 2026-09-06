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
      };
}

/// 页面里 console.* 的一行输出。注入脚本调试时看它。
class ConsoleLine {
  ConsoleLine({required this.level, required this.text, DateTime? at})
      : at = at ?? DateTime.now();

  final String level;
  final String text;
  final DateTime at;
}
