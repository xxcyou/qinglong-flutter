import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/error_handler.dart';
import '../models/panel_info.dart';

/// 登录 / 连接测试。
class AuthApi {
  AuthApi._();

  /// 登录类请求单独放宽超时。
  ///
  /// 青龙的 `/api/user/login` 自带约 10 秒的固定延时（防爆破），而全局
  /// receiveTimeout 恰好也是 10 秒——于是**每一次账号密码登录都必然超时**，
  /// 表现就是"青龙登录超时"、"登录已失效怎么都连不上"。这里给 30 秒。
  static const _authTimeout = Duration(seconds: 30);

  static Options _authOptions() => Options(
        extra: const {'isAuthRequest': true},
        receiveTimeout: _authTimeout,
        sendTimeout: _authTimeout,
      );

  static Future<PanelConnectionResult> loginWithPassword({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    try {
      final response = await DioClient.dio.post<dynamic>(
        '${baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}/api/user/login',
        data: {'username': username, 'password': password},
        options: _authOptions(),
      );
      final data = parseQlResponse(response);
      if (data is Map<String, dynamic>) {
        final token = data['token'] as String?;
        final tokenType = (data['token_type'] as String?) ?? 'Bearer';
        if (token == null || token.isEmpty) {
          throw const ApiException(message: '登录响应缺少 token');
        }
        return PanelConnectionResult(
          token: token,
          tokenType: tokenType,
          // JWT 自带 exp，解出来就能提前续期，不用等 401。
          expiresAt: _jwtExpiry(token),
        );
      }
      throw const ApiException(message: '登录响应格式不正确');
    } on DioException catch (e) {
      throw ApiException(
        message: readableError(e),
        statusCode: e.response?.statusCode,
        type: e.response?.statusCode == 401
            ? ApiExceptionType.unauthorized
            : ApiExceptionType.business,
      );
    }
  }

  /// OpenAPI 换票。
  ///
  /// 路径是 `/open/auth/token`，不是 `/api/auth/token`——后者在 2.15.x 上被
  /// JWT 中间件挡着，没带 JWT 就回 401 "No authorization token was found"，
  /// 于是"OpenAPI 登录永远失败"。换回 /open 前缀就通了。
  static Future<PanelConnectionResult> loginWithOpenApi({
    required String baseUrl,
    required String clientId,
    required String clientSecret,
  }) async {
    final site = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final response = await DioClient.dio.get<dynamic>(
        '$site/open/auth/token',
        queryParameters: {'client_id': clientId, 'client_secret': clientSecret},
        options: _authOptions(),
      );
      final data = parseQlResponse(response);
      if (data is Map<String, dynamic>) {
        final token = data['token'] as String?;
        final tokenType = (data['token_type'] as String?) ?? 'Bearer';
        if (token == null || token.isEmpty) {
          throw const ApiException(message: 'OpenAPI 响应缺少 token');
        }
        return PanelConnectionResult(
          token: token,
          tokenType: tokenType,
          expiresAt: _expiry(data['expiration']),
        );
      }
      throw const ApiException(message: 'OpenAPI 响应格式不正确');
    } on DioException catch (e) {
      throw ApiException(
        message: readableError(e),
        statusCode: e.response?.statusCode,
        type: e.response?.statusCode == 401
            ? ApiExceptionType.unauthorized
            : ApiExceptionType.business,
      );
    }
  }

  /// 从 JWT 的 payload 里取 exp（秒级）。解不出来就当"不知道"。
  static DateTime? _jwtExpiry(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;
      var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      payload = payload.padRight((payload.length + 3) ~/ 4 * 4, '=');
      final json = jsonDecode(utf8.decode(base64.decode(payload)));
      if (json is Map && json['exp'] != null) return _expiry(json['exp']);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// expiration 是秒级 Unix 时间戳。
  static DateTime? _expiry(Object? raw) {
    final seconds = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  /// 连接测试：GET {prefix}/system 返回系统信息。
  static Future<Map<String, dynamic>> fetchSystemInfo({
    required String baseUrl,
    String? token,
    LoginType loginType = LoginType.account,
  }) async {
    final site = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final prefix = loginType == LoginType.openapi ? 'open' : 'api';
    try {
      final response = await DioClient.dio.get<dynamic>(
        '$site/$prefix/system',
        options: Options(
          headers: token == null ? null : {'Authorization': 'Bearer $token'},
        ),
      );
      final data = parseQlResponse(response);
      if (data is Map<String, dynamic>) return data;
      return const {};
    } on DioException catch (e) {
      throw ApiException(message: readableError(e));
    }
  }
}
