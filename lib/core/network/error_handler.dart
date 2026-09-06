import 'package:dio/dio.dart';

import 'api_exception.dart';

/// 把 Dio 异常转换成用户可读信息。
String readableError(Object error) {
  if (error is ApiException) return error.message;
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return '请求超时，请检查网络或面板地址';
      case DioExceptionType.connectionError:
        return '无法连接到面板，请检查 BaseURL 与网络';
      case DioExceptionType.badCertificate:
        return certHint;
      case DioExceptionType.badResponse:
        // 面板会在 body 里说明到底哪个字段不合法，只报状态码等于没报错。
        final reason = _serverReason(error.response?.data);
        final code = error.response?.statusCode;
        return reason.isEmpty
            ? '面板返回异常（HTTP $code）'
            : '面板拒绝请求（HTTP $code）：$reason';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.unknown:
        // 自签名证书握手失败落在 unknown 里（底层是 HandshakeException），
        // 只报"网络异常"会让人一路去查网络/端口/防火墙，方向全错。
        if (isCertError(error)) return certHint;
        if (isPlaintextToTlsError(error)) return schemeHint;
        return '网络异常：${error.message ?? '未知错误'}';
    }
  }
  return error.toString();
}

/// 证书不被信任时统一给这句话——**必须点到那个开关**。
///
/// 内网自建的 HTTPS 服务（LLM 网关、青龙面板）基本都是自签证书，
/// 报"网络异常"会让人去查网络和端口，白折腾半天。
const certHint = 'HTTPS 证书不被信任（自签名证书）。'
    '内网自建服务基本都是这种，去「设置 → 允许自签名 HTTPS」打开开关再试；'
    '也可以把地址换成 http:// 走明文。';

/// 明文打在 HTTPS 端口上时给这句话。
///
/// 现场：设置里填的是 `http://127.0.0.1:8766/v1`，而 8766 只说 TLS。
/// 服务端一看不是握手包就直接关连接，Dart 抛
/// `HttpException: Connection closed before full header was received`，
/// Dio 归到 unknown，界面只显示"AI 请求失败：unknown"——完全看不出是协议写错了。
const schemeHint = '对方端口只接受 HTTPS，但地址写的是 http://。'
    '把 Base URL 的 http 改成 https 再试（自签证书还要开「设置 → 允许自签名 HTTPS」）。';

/// 这个异常是不是"把明文发到了 TLS 端口"。
bool isPlaintextToTlsError(Object error) {
  final text = error is DioException
      ? '${error.message ?? ''} ${error.error ?? ''}'
      : error.toString();
  final url = error is DioException ? error.requestOptions.uri.toString() : '';
  if (!text.contains('Connection closed before full header') &&
      !text.contains('Connection closed while receiving data') &&
      !text.contains('HttpException: Connection reset by peer')) {
    return false;
  }
  // 只在 http:// 上给这个提示，https 出同样的错是别的原因。
  return url.startsWith('http://');
}

/// 这个异常是不是"证书不被信任"。
///
/// Dart 把自签名握手失败包成 HandshakeException 塞进 DioException.unknown，
/// 类型上分辨不出来，只能看文本里的 CERTIFICATE_VERIFY_FAILED / HandshakeException。
bool isCertError(Object error) {
  final text = error is DioException
      ? '${error.message ?? ''} ${error.error ?? ''}'
      : error.toString();
  return text.contains('CERTIFICATE_VERIFY_FAILED') ||
      text.contains('HandshakeException') ||
      text.contains('CERTIFICATE_UNKNOWN') ||
      text.contains('unable to get local issuer');
}

/// 从面板响应体里提取人类可读的失败原因。
String _serverReason(dynamic data) {
  if (data == null) return '';
  if (data is String) {
    final text = data.trim();
    if (text.isEmpty) return '';
    return text.length > 300 ? '${text.substring(0, 300)}…' : text;
  }
  if (data is Map) {
    for (final key in const [
      'message',
      'msg',
      'error',
      'errors',
      'detail',
      'validation',
    ]) {
      final v = data[key];
      if (v == null) continue;
      if (v is String && v.trim().isNotEmpty) return v.trim();
      if (v is List && v.isNotEmpty) {
        return v.map((e) => _describeItem(e)).join('；');
      }
      if (v is Map) return _describeItem(v);
    }
    final data2 = data['data'];
    if (data2 != null && data2 is! Map && data2 is! List) {
      return data2.toString();
    }
  }
  if (data is List && data.isNotEmpty) {
    return data.map((e) => _describeItem(e)).take(3).join('；');
  }
  return '';
}

String _describeItem(dynamic item) {
  if (item is Map) {
    final msg = item['message'] ?? item['msg'] ?? item['error'];
    final field = item['path'] ?? item['field'] ?? item['param'];
    if (msg != null) {
      return field == null ? msg.toString() : '$field: $msg';
    }
    return item.entries.map((e) => '${e.key}=${e.value}').join(', ');
  }
  return item.toString();
}
