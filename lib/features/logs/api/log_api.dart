import 'package:dio/dio.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/qinglong_version_compat.dart';
import '../../panels/adapters/qinglong_api_adapter.dart';
import '../models/log_item.dart';

/// 日志中心 API。
class LogApi {
  LogApi._();

  static List<String> _splitLog(dynamic data) {
    if (data is String) return data.isEmpty ? const [] : data.split('\n');
    if (data is List) return data.map((e) => e.toString()).toList();
    if (data is Map<String, dynamic>) {
      final lines = data['data'] ?? data['lines'] ?? const [];
      if (lines is String) return lines.isEmpty ? const [] : lines.split('\n');
      if (lines is List) return lines.map((e) => e.toString()).toList();
    }
    return const [];
  }

  static Future<dynamic> _compatCall({
    required String apiBaseUrl,
    required String function,
    Map<String, String> pathParams = const {},
    Map<String, dynamic> query = const {},
  }) async {
    final spec = await QinglongVersionCompat.specForCurrentVersion(
      function,
      pathParams: pathParams,
    );
    if (spec == null) return null;
    final path = QinglongCompatRender.render(spec.path, pathParams, query);
    final queryParameters = <String, dynamic>{
      for (final e in spec.query.entries)
        e.key: QinglongCompatRender.renderValue(e.value, pathParams, query),
      ...query,
    };
    final response = await DioClient.dio.request<dynamic>(
      '$apiBaseUrl$path',
      options: Options(method: spec.method),
      queryParameters: queryParameters,
    );
    return parseQlResponse(response);
  }

  static Future<List<LogItem>> list({
    required String apiBaseUrl,
    String? searchValue,
  }) async {
    if (await QinglongApiAdapterRegistry.hasFunction('log_list')) {
      try {
        final data = await QinglongApiAdapterRegistry.invoke(
          apiBaseUrl: apiBaseUrl,
          function: 'log_list',
          query: {
            if (searchValue != null && searchValue.isNotEmpty)
              'searchValue': searchValue,
          },
        );
        if (data != null) {
          final result = _flatten(data is List
              ? data
              : (data is Map<String, dynamic>
                  ? data['data'] as List? ?? const []
                  : const []));
          if (result.isNotEmpty) return result;
        }
      } catch (_) {
        // 插件失败回退内置版本表。
      }
    }
    try {
      final data = await _compatCall(
        apiBaseUrl: apiBaseUrl,
        function: 'log_list',
        query: {
          if (searchValue != null && searchValue.isNotEmpty)
            'searchValue': searchValue,
        },
      );
      if (data != null) {
        final result = _flatten(data is List
            ? data
            : (data is Map<String, dynamic>
                ? data['data'] as List? ?? const []
                : const []));
        if (result.isNotEmpty) return result;
      }
    } catch (_) {
      // 兼容失败继续内置。
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
      try {
        final data = await QinglongApiAdapterRegistry.invoke(
          apiBaseUrl: apiBaseUrl,
          function: 'log_read',
          pathParams: {'dir': dir ?? '', 'file': file},
          query: {'path': dir ?? '', 'file': file},
        );
        if (data != null) {
          final result = _splitLog(data);
          if (result.isNotEmpty) return result;
        }
      } catch (_) {
        // 插件失败回退内置版本表。
      }
    }
    try {
      final data = await _compatCall(
        apiBaseUrl: apiBaseUrl,
        function: 'log_read',
        pathParams: {'dir': dir ?? '', 'file': file},
      );
      if (data != null) {
        final result = _splitLog(data);
        if (result.isNotEmpty) return result;
      }
    } catch (_) {
      // 兼容失败继续内置。
    }
    final response = await DioClient.dio.get<dynamic>(
      '$apiBaseUrl/logs/$file',
      queryParameters: {
        if (dir != null && dir.isNotEmpty) 'path': dir,
      },
    );
    final data = parseQlResponse(response);
    if (data is String) {
      // 青龙 /logs/detail 返回的是字符串内容，按行拆开便于展示。
      if (data.isEmpty) return const [];
      return data.split('\n');
    }
    if (data is List) {
      return data.map((e) => e.toString()).toList();
    }
    if (data is Map<String, dynamic>) {
      final lines = data['data'] ?? data['lines'] ?? const [];
      if (lines is String) {
        return lines.isEmpty ? const [] : lines.split('\n');
      }
      if (lines is List) return lines.map((e) => e.toString()).toList();
    }
    return const [];
  }
}
