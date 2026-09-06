import 'package:dio/dio.dart';

import 'api_exception.dart';

/// 自动注入 Bearer Token；401 时尝试回调重登，重登成功则原请求重试一次。
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.tokenProvider,
    required this.retryDio,
    this.unauthorizedHandler,
  });

  final Future<String?> Function() tokenProvider;
  final Dio retryDio;
  final Future<bool> Function()? unauthorizedHandler;
  Future<bool>? _unauthorizedFuture;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // 登录/换取 token 的请求不注入旧 token，避免旧 token 干扰登录接口。
    if (options.extra['isAuthRequest'] == true) {
      handler.next(options);
      return;
    }
    final token = await tokenProvider();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // 登录请求本身失败时绝不递归触发重新登录。
    if (err.requestOptions.extra['isAuthRequest'] == true) {
      handler.next(err);
      return;
    }
    if (err.response?.statusCode == 401) {
      // 并发 401 共享同一次刷新，避免重复登录风暴。
      final ok = await _refreshUnauthorized();
      if (ok) {
        final token = await tokenProvider();
        if (token != null && token.isNotEmpty) {
          final options = err.requestOptions;
          options.headers['Authorization'] = 'Bearer $token';
          try {
            final response = await retryDio.fetch(options);
            return handler.resolve(response);
          } catch (_) {
            // 重试仍然失败，继续走原始错误路径。
          }
        }
      }
      handler.next(
        DioException(
          requestOptions: err.requestOptions,
          response: err.response,
          type: DioExceptionType.badResponse,
          error: const ApiException(
            message: '登录已失效，请重新登录',
            type: ApiExceptionType.unauthorized,
          ),
        ),
      );
      return;
    }
    handler.next(err);
  }

  Future<bool> _refreshUnauthorized() {
    final pending = _unauthorizedFuture;
    if (pending != null) return pending;
    final future = (unauthorizedHandler?.call() ?? Future.value(false))
        .whenComplete(() => _unauthorizedFuture = null);
    _unauthorizedFuture = future;
    return future;
  }
}
