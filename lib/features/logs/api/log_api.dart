import '../../../core/network/dio_client.dart';
import '../models/log_item.dart';

/// 日志中心 API。
class LogApi {
  LogApi._();

  static Future<List<LogItem>> list({
    required String apiBaseUrl,
    String? searchValue,
  }) async {
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
