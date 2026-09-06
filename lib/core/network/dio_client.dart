import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../debug/api_debug_log.dart';
import 'api_exception.dart';
import 'auth_interceptor.dart';
import 'error_handler.dart';

/// 全局 Dio 实例。
///
/// Token 与 401 处理由 AuthInterceptor 动态注入；切换面板时调用 [configure] 更新。
class DioClient {
  DioClient._();

  static Dio? _dio;
  static Future<String?> Function()? _tokenProvider;
  static Future<bool> Function()? _unauthorizedHandler;

  /// 信任自签名 HTTPS 证书。
  ///
  /// ## 这里原来是个死开关
  ///
  /// 设置页早就有"允许自签名 HTTPS"这个 Switch，值也存进了
  /// shared_preferences，但**全项目没有一个地方读它**——Dio 用的是默认
  /// HttpClient，`badCertificateCallback` 从来没设过，于是自签证书一律握手失败。
  /// 用户把开关打开、重启、再试，现象一模一样：内网自签名的 LLM 网关
  /// （`https://127.0.0.1:8766/v1` 这种，证书 CN=…Local API、自己签自己）
  /// 既列不出模型，也测不通，而 curl -k / 浏览器点"继续访问"都是好的。
  ///
  /// 现在这个静态量就是那个开关的落点：[SettingsNotifier] 加载和保存设置时
  /// 都会写它，Dio 的 badCertificateCallback 每次握手都读它的当前值
  /// （所以改完立刻生效，不用重启 APP、也不用重建 Dio）。
  static bool allowSelfSigned = false;

  static Dio get dio {
    if (_dio == null) {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          headers: {'Content-Type': 'application/json'},
        ),
      );
      // 自签名证书的放行点。回调里读静态量而不是捕获当时的值：
      // 用户在设置里拨动开关后，下一次请求就按新值走。
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient()
            ..badCertificateCallback = (cert, host, port) => allowSelfSigned;
          return client;
        },
      );
      dio.interceptors.add(AuthInterceptor(
        tokenProvider: () => _tokenProvider?.call() ?? Future.value(null),
        retryDio: dio,
        unauthorizedHandler: () =>
            _unauthorizedHandler?.call() ?? Future.value(false),
      ));
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          ApiDebugLog.instance.add(
            kind: ApiDebugKind.request,
            method: options.method,
            uri: _requestUri(options),
            message: '${options.method} ${_requestPath(options)}',
            detail: _requestDetail(options),
          );
          handler.next(options);
        },
        onResponse: (response, handler) {
          final data = response.data;
          ApiDebugLog.instance.add(
            kind: ApiDebugKind.response,
            method: response.requestOptions.method,
            uri: _requestUri(response.requestOptions),
            statusCode: response.statusCode,
            message: 'HTTP ${response.statusCode}',
            detail: _responseDetail(data),
          );
          handler.next(response);
        },
        onError: (error, handler) {
          final detail = StringBuffer();
          detail.write('type=${error.type}');
          if (error.message != null) detail.write(' message=${error.message}');
          if (error.response != null) {
            detail.write(' status=${error.response!.statusCode}');
            // 4xx/5xx 的真正原因在响应体里，摘要不够，要原文。
            detail.write('\nresponse: ${_bodyText(error.response!.data)}');
          }
          final reqBody = _bodyText(error.requestOptions.data);
          if (reqBody.isNotEmpty) detail.write('\nrequest: $reqBody');
          ApiDebugLog.instance.add(
            kind: ApiDebugKind.error,
            method: error.requestOptions.method,
            uri: _requestUri(error.requestOptions),
            statusCode: error.response?.statusCode,
            message: readableError(error),
            detail: detail.toString(),
          );
          handler.next(error);
        },
      ));
      _dio = dio;
    }
    return _dio!;
  }

  static void configure({
    Future<String?> Function()? tokenProvider,
    Future<bool> Function()? unauthorizedHandler,
  }) {
    _tokenProvider = tokenProvider;
    _unauthorizedHandler = unauthorizedHandler;
  }
}

String _requestUri(RequestOptions options) {
  final base = options.baseUrl.replaceAll(RegExp(r'/+$'), '');
  return '$base${options.path}';
}

String _requestPath(RequestOptions options) {
  final base = options.baseUrl.replaceAll(RegExp(r'/+$'), '');
  if (options.path.startsWith(base)) return options.path.substring(base.length);
  return options.path;
}

String _requestDetail(RequestOptions options) {
  final parts = <String>[];
  final query = options.queryParameters;
  if (query.isNotEmpty) {
    parts.add(
      'query: ${query.entries.map((e) => '${e.key}=${e.value}').join('&')}',
    );
  }
  // 请求体必须记下来：4xx 时不看 body 根本判断不出面板在挑哪个字段。
  final body = _bodyText(options.data);
  if (body.isNotEmpty) parts.add('body: $body');
  return parts.join('\n');
}

/// 请求体转文本，并对凭据字段脱敏。
String _bodyText(dynamic data) {
  if (data == null) return '';
  try {
    final masked = _maskSensitive(data);
    final text = masked is String ? masked : jsonEncode(masked);
    return text.length > 1200 ? '${text.substring(0, 1200)}…' : text;
  } catch (_) {
    final text = data.toString();
    return text.length > 400 ? '${text.substring(0, 400)}…' : text;
  }
}

const _sensitiveKeys = {
  'token',
  'password',
  'apikey',
  'api_key',
  'authorization',
  'client_secret',
  'clientsecret',
  'secret',
  'value',
};

dynamic _maskSensitive(dynamic data) {
  if (data is Map) {
    return {
      for (final e in data.entries)
        e.key.toString(): _sensitiveKeys.contains(
          e.key.toString().toLowerCase(),
        )
            ? _maskValue(e.value)
            : _maskSensitive(e.value),
    };
  }
  if (data is List) return [for (final v in data) _maskSensitive(v)];
  return data;
}

String _maskValue(dynamic value) {
  final text = value?.toString() ?? '';
  if (text.length <= 6) return '***';
  return '${text.substring(0, 6)}…(${text.length})';
}

String _responseDetail(dynamic data) {
  final buffer = StringBuffer()..write('type=${data.runtimeType}');
  if (data is Map) {
    buffer.write(' keys=${data.keys.take(30).join(',')}');
    final inner = data['data'];
    if (inner != null) {
      buffer.write(' data=${_dataSummary(inner)}');
    }
  } else if (data is List) {
    buffer.write(' length=${data.length}');
  } else if (data is String) {
    buffer.write(' length=${data.length}');
  }
  return buffer.toString();
}

String _dataSummary(dynamic data) {
  if (data == null) return 'null';
  if (data is String) {
    final v = data.length > 80 ? data.substring(0, 80) : data;
    return 'String(${data.length}) "$v"';
  }
  if (data is Map) {
    return 'Map keys=${data.keys.take(20).join(',')}';
  }
  if (data is List) return 'List(${data.length})';
  return '$data.runtimeType';
}

/// 统一解析青龙接口响应。格式：{ code, data, message? }，code != 200 抛业务异常。
dynamic parseQlResponse(Response<dynamic> response) {
  final statusCode = response.statusCode;
  if (statusCode != null && statusCode >= 400 && statusCode < 600) {
    throw ApiException(
      message: 'HTTP $statusCode：${response.statusMessage ?? '请求失败'}',
      statusCode: statusCode,
      type: statusCode == 401
          ? ApiExceptionType.unauthorized
          : ApiExceptionType.business,
    );
  }

  final body = response.data;
  if (body is Map<String, dynamic>) {
    final code = body['code'];
    final message = body['message'] ?? body['msg'] ?? '未知错误';
    if (code != null && code != 200) {
      throw ApiException(
        message: '$message（业务码 $code）',
        code: code is int ? code : null,
      );
    }
    return body['data'];
  }
  return body;
}
