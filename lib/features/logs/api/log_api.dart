import 'package:dio/dio.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/error_handler.dart';
import '../../panels/adapters/qinglong_api_adapter.dart';
import '../models/log_item.dart';

/// 日志中心 API。
class LogApi {
  LogApi._();

  static Future<List<LogItem>> list({
    required String apiBaseUrl,
    String? searchValue,
  }) async {
    if (await QinglongApiAdapterRegistry.hasFunction('log_list')) {
      final data = await QinglongApiAdapterRegistry.invoke(
        apiBaseUrl: apiBaseUrl,
        function: 'log_list',
        query: {
          if (searchValue != null && searchValue.isNotEmpty)
            'searchValue': searchValue,
        },
      );
      return _flatten(data is List
          ? data
          : (data is Map<String, dynamic>
              ? data['data'] as List? ?? const []
              : const []));
    }
    final response = await DioClient.dio.get<dynamic>(
      '$apiBaseUrl/logs',
      queryParameters: {
        if (searchValue != null && searchValue.isNotEmpty)
          'searchValue': searchValue,
      },
    );
    final data = parseQlResponse(response);
    return _flatten(data is List
        ? data
        : (data is Map<String, dynamic>
            ? data['data'] as List? ?? const []
            : const []));
  }

  static List<LogItem> _flatten(List<dynamic> items) {
    final result = <LogItem>[];
    for (final item in items) {
      if (item is String) {
        result.add(LogItem(file: item, dir: item.split('/').first));
      } else if (item is Map<String, dynamic>) {
        final title = item['title'] as String? ?? '';
        final parent = item['parent'] as String? ?? '';
        final type = item['type'] as String?;
        // 目录本身不作为可点击项，只展示其下文件；文件名拼接父目录便于唯一区分。
        if (type == 'file' && title.isNotEmpty) {
          final fullDir = parent.isEmpty ? '' : parent;
          result.add(LogItem(dir: fullDir, file: title));
        }
        final children = item['children'];
        if (children is List) {
          result.addAll(_flatten(children));
        }
      }
    }
    return result;
  }

  static Future<List<String>> read({
    required String apiBaseUrl,
    required String file,
    String? dir,
  }) async {
    if (await QinglongApiAdapterRegistry.hasFunction('log_read')) {
      final data = await QinglongApiAdapterRegistry.invoke(
        apiBaseUrl: apiBaseUrl,
        function: 'log_read',
        pathParams: {'dir': dir ?? '', 'file': file},
        query: {'path': dir ?? '', 'file': file},
      );
      return _splitLog(data);
    }
    try {
      // 新版青龙（2.16+）已下线 GET /logs/:file，改用 /logs/detail。
      final response = await DioClient.dio.get<dynamic>(
        '$apiBaseUrl/logs/detail',
        queryParameters: {
          'path': dir ?? '',
          'file': file,
        },
      );
      return _splitLog(parseQlResponse(response));
    } on DioException catch (e) {
      if (_isNotFound(e.response?.statusCode) ||
          _isNotFound(_businessCode(e.response?.data))) {
        try {
          final response = await DioClient.dio.get<dynamic>(
            '$apiBaseUrl/logs/$file',
            queryParameters: {
              if (dir != null && dir.isNotEmpty) 'path': dir,
            },
          );
          return _splitLog(parseQlResponse(response));
        } on DioException catch (e2) {
          throw ApiException(message: readableError(e2));
        }
      }
      throw ApiException(message: readableError(e));
    }
  }

  static List<String> _splitLog(dynamic data) {
    if (data is String) {
      if (data.isEmpty) return const [];
      return data.split('\n');
    }
    if (data is List) return data.map((e) => e.toString()).toList();
    if (data is Map<String, dynamic>) {
      final lines = data['data'] ?? data['lines'] ?? const [];
      if (lines is String) return lines.isEmpty ? const [] : lines.split('\n');
      if (lines is List) return lines.map((e) => e.toString()).toList();
    }
    return const [];
  }

  static bool _isNotFound(dynamic code) {
    if (code is int) return code == 404 || code == 405 || code == 410;
    if (code is String) {
      return code == '404' || code == '405' || code == '410';
    }
    return false;
  }

  static int? _businessCode(dynamic data) {
    if (data is Map<String, dynamic>) {
      final code = data['code'];
      if (code is int) return code;
      if (code is String) return int.tryParse(code);
    }
    return null;
  }
}
