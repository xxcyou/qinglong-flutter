class ApiException implements Exception {
  const ApiException({
    required this.message,
    this.code,
    this.statusCode,
    this.type = ApiExceptionType.business,
  });

  final String message;
  final int? code;
  final int? statusCode;
  final ApiExceptionType type;

  @override
  String toString() => message;
}

enum ApiExceptionType {
  network,
  timeout,
  unauthorized,
  business,

  /// 用户主动取消（点了停止）。不该重试，也不该当成错误弹给用户。
  cancelled,
  unknown,
}

/// 将 Dio 等底层异常映射为可读的 ApiException。
ApiException mapDioError(
  Object error, {
  String Function(dynamic data)? businessMessage,
}) {
  if (error is ApiException) return error;

  final name = error.runtimeType.toString();
  final text = error.toString();
  if (text.contains('timeout') || name.contains('Timeout')) {
    return const ApiException(
      message: '请求超时，请检查网络或面板地址',
      type: ApiExceptionType.timeout,
    );
  }
  if (text.contains('SocketException') ||
      text.contains('Connection refused') ||
      text.contains('Failed host lookup')) {
    return const ApiException(
      message: '网络连接失败，请检查面板地址和网络',
      type: ApiExceptionType.network,
    );
  }
  return ApiException(message: '网络异常：$text', type: ApiExceptionType.network);
}
