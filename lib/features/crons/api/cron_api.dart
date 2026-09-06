import 'package:dio/dio.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/error_handler.dart';
import '../../../core/utils/cron_parser.dart';
import '../models/cron_log.dart';
import '../models/cron_task.dart';

/// 定时任务 API。
class CronApi {
  CronApi._();

  static Future<CronPageResult> list({
    required String apiBaseUrl,
    String? searchValue,
    int page = 1,
    int pageSize = 20,
  }) async {
    final response = await DioClient.dio.get<dynamic>(
      '$apiBaseUrl/crons',
      queryParameters: {
        if (searchValue != null && searchValue.isNotEmpty)
          'searchValue': searchValue,
        'page': page,
        'pageSize': pageSize,
      },
    );
    final data = parseQlResponse(response);
    if (data is List) {
      final items = data
          .whereType<Map<String, dynamic>>()
          .map(CronTask.fromJson)
          .toList();
      return CronPageResult(items: items, total: items.length);
    }
    if (data is Map<String, dynamic>) {
      final listData = data['data'] ?? const [];
      final items = listData is List
          ? listData
              .whereType<Map<String, dynamic>>()
              .map(CronTask.fromJson)
              .toList()
          : <CronTask>[];
      final pagination = data['pagination'] is Map<String, dynamic>
          ? data['pagination'] as Map<String, dynamic>
          : null;
      final rawTotal = pagination?['total'];
      final total = rawTotal is int
          ? rawTotal
          : rawTotal is num
              ? rawTotal.toInt()
              : rawTotal is String
                  ? int.tryParse(rawTotal.trim()) ?? items.length
                  : items.length;
      return CronPageResult(items: items, total: total);
    }
    return const CronPageResult(items: [], total: 0);
  }

  static Future<CronTask> create({
    required String apiBaseUrl,
    required CronTask task,
  }) async {
    // 青龙只认 6 段 cron，5 段直接提交会 400；带 ? 的 6 段也要补成 7 段。
    task = _normalizeSchedule(task);
    // 面板对 body 做白名单校验（Joi）：多一个字段就 400
    // “"isDisabled" is not allowed”。启用/禁用、置顶都是独立接口，
    // 这里只能发它认的字段。
    final response = await DioClient.dio.post<dynamic>(
      '$apiBaseUrl/crons',
      data: {
        'name': task.name,
        'command': task.command,
        'schedule': task.schedule,
        if (task.labels.isNotEmpty) 'labels': task.labels,
        if ((task.taskBefore ?? '').isNotEmpty) 'task_before': task.taskBefore,
        if ((task.taskAfter ?? '').isNotEmpty) 'task_after': task.taskAfter,
      },
    );
    final data = parseQlResponse(response);
    if (data is Map<String, dynamic>) return CronTask.fromJson(data);
    return task;
  }

  static Future<void> update({
    required String apiBaseUrl,
    required CronTask task,
  }) async {
    task = _normalizeSchedule(task);
    // 同样受白名单校验限制：只发面板允许的可编辑字段 + id。
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/crons',
      data: {
        'id': task.id,
        'name': task.name,
        'command': task.command,
        'schedule': task.schedule,
        if (task.labels.isNotEmpty) 'labels': task.labels,
        if ((task.taskBefore ?? '').isNotEmpty) 'task_before': task.taskBefore,
        if ((task.taskAfter ?? '').isNotEmpty) 'task_after': task.taskAfter,
      },
    );
    parseQlResponse(response);
  }

  static CronTask _normalizeSchedule(CronTask task) {
    final normalized = CronParser.normalizeForQinglong(task.schedule);
    return normalized == task.schedule
        ? task
        : task.copyWith(schedule: normalized);
  }

  static Future<void> delete({
    required String apiBaseUrl,
    required List<int> ids,
  }) async {
    final response = await DioClient.dio.delete<dynamic>(
      '$apiBaseUrl/crons',
      data: ids,
    );
    parseQlResponse(response);
  }

  static Future<void> run({
    required String apiBaseUrl,
    required List<int> ids,
  }) async {
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/crons/run',
      data: ids,
    );
    parseQlResponse(response);
  }

  static Future<void> stop({
    required String apiBaseUrl,
    required List<int> ids,
  }) async {
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/crons/stop',
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
      '$apiBaseUrl/crons/${enabled ? 'enable' : 'disable'}',
      data: ids,
    );
    parseQlResponse(response);
  }

  static Future<void> setPinned({
    required String apiBaseUrl,
    required List<int> ids,
    required bool pinned,
  }) async {
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/crons/${pinned ? 'pin' : 'unpin'}',
      data: ids,
    );
    parseQlResponse(response);
  }

  static Future<CronLog> fetchLog({
    required String apiBaseUrl,
    required int id,
    String? logPath,
  }) async {
    try {
      // `/crons/:id/log` 每次都按库里最新的 log_path 解析，运行新一轮会自动跟上，
      // 所以优先走它；显式给了 logPath（翻历史日志）才去读具体文件。
      if (logPath == null || logPath.isEmpty) {
        final response = await DioClient.dio.get<dynamic>(
          '$apiBaseUrl/crons/$id/log',
        );
        return CronLog.fromJson(parseQlResponse(response));
      }

      final index = logPath.lastIndexOf('/');
      final dir = index < 0 ? '' : logPath.substring(0, index);
      final file = index < 0 ? logPath : logPath.substring(index + 1);
      final response = await DioClient.dio.get<dynamic>(
        '$apiBaseUrl/logs/$file',
        // v2.15 的 /logs/:file 要求 path 始终存在（空串也可）。
        queryParameters: {'path': dir},
      );
      return CronLog.fromJson(parseQlResponse(response));
    } on DioException catch (e) {
      throw ApiException(message: readableError(e));
    }
  }
}
