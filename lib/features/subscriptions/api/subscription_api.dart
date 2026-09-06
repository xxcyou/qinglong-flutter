import 'package:dio/dio.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/error_handler.dart';
import '../../crons/models/cron_log.dart';
import '../models/subscription.dart';

/// 订阅 API（面板路由前缀 `/subscriptions`）。
///
/// 注意路径不是 `/subs`：面板里 `app.use('/subscriptions', route)`，
/// 猜短名会一路 404。
class SubscriptionApi {
  SubscriptionApi._();

  /// 列表。面板这个接口**不分页**，一次返回全部，只支持 searchValue。
  static Future<List<Subscription>> list({
    required String apiBaseUrl,
    String? searchValue,
  }) async {
    final response = await DioClient.dio.get<dynamic>(
      '$apiBaseUrl/subscriptions',
      queryParameters: {
        if (searchValue != null && searchValue.trim().isNotEmpty)
          'searchValue': searchValue.trim(),
      },
    );
    return _parseList(parseQlResponse(response));
  }

  static List<Subscription> _parseList(dynamic data) {
    if (data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(Subscription.fromJson)
          .toList();
    }
    if (data is Map<String, dynamic>) {
      // 有的版本会再套一层 {data: [...]}。
      final inner = data['data'];
      if (inner is List) {
        return inner
            .whereType<Map<String, dynamic>>()
            .map(Subscription.fromJson)
            .toList();
      }
      // 单个对象也吃下，省得调用方分情况。
      if (data['url'] != null || data['alias'] != null) {
        return [Subscription.fromJson(data)];
      }
    }
    return const [];
  }

  static Future<Subscription> detail({
    required String apiBaseUrl,
    required int id,
  }) async {
    final response = await DioClient.dio.get<dynamic>(
      '$apiBaseUrl/subscriptions/$id',
    );
    final data = parseQlResponse(response);
    if (data is Map<String, dynamic>) return Subscription.fromJson(data);
    throw const ApiException(message: '面板没有返回这条订阅');
  }

  static Future<Subscription> create({
    required String apiBaseUrl,
    required Subscription sub,
  }) async {
    final response = await DioClient.dio.post<dynamic>(
      '$apiBaseUrl/subscriptions',
      data: sub.toRequestBody(),
    );
    final data = parseQlResponse(response);
    if (data is Map<String, dynamic>) return Subscription.fromJson(data);
    return sub;
  }

  static Future<void> update({
    required String apiBaseUrl,
    required Subscription sub,
  }) async {
    if (sub.id == null) {
      throw const ApiException(message: '缺少订阅 id，无法更新');
    }
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/subscriptions',
      data: sub.toRequestBody(withId: true),
    );
    parseQlResponse(response);
  }

  /// 删除。[force] 为 true 时面板会连它自动建的定时任务一起删。
  static Future<void> delete({
    required String apiBaseUrl,
    required List<int> ids,
    bool force = false,
  }) async {
    final response = await DioClient.dio.delete<dynamic>(
      '$apiBaseUrl/subscriptions',
      data: ids,
      queryParameters: {if (force) 'force': true},
    );
    parseQlResponse(response);
  }

  static Future<void> run({
    required String apiBaseUrl,
    required List<int> ids,
  }) async {
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/subscriptions/run',
      data: ids,
    );
    parseQlResponse(response);
  }

  static Future<void> stop({
    required String apiBaseUrl,
    required List<int> ids,
  }) async {
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/subscriptions/stop',
      data: ids,
    );
    parseQlResponse(response);
  }

  static Future<void> setEnabled({
    required String apiBaseUrl,
    required List<int> ids,
    required bool enabled,
  }) async {
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/subscriptions/${enabled ? 'enable' : 'disable'}',
      data: ids,
    );
    parseQlResponse(response);
  }

  /// 读最近一次拉取的日志。
  ///
  /// `/subscriptions/:id/log` 返回的是**整段字符串**（响应体里同时有
  /// `data` 和 `content`），所以直接复用定时任务那边的 [CronLog] 解析：
  /// 它已经把 String / List / Map 三种形态都吃下了。
  static Future<CronLog> fetchLog({
    required String apiBaseUrl,
    required int id,
  }) async {
    try {
      final response = await DioClient.dio.get<dynamic>(
        '$apiBaseUrl/subscriptions/$id/log',
      );
      return CronLog.fromJson(parseQlResponse(response));
    } on DioException catch (e) {
      throw ApiException(message: readableError(e));
    }
  }

  /// 历史日志文件列表。
  static Future<List<SubLogFile>> logFiles({
    required String apiBaseUrl,
    required int id,
  }) async {
    final response = await DioClient.dio.get<dynamic>(
      '$apiBaseUrl/subscriptions/$id/logs',
    );
    final data = parseQlResponse(response);
    if (data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(SubLogFile.fromJson)
          .toList();
    }
    return const [];
  }
}
