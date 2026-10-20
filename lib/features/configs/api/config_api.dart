import '../../../core/network/dio_client.dart';
import '../../../core/network/qinglong_version_compat.dart';
import '../models/config_file.dart';

/// 配置管理 API。
class ConfigApi {
  ConfigApi._();

  static Future<List<ConfigFile>> files({
    required String apiBaseUrl,
  }) async {
    try {
      final data = await QinglongVersionCompat.call(
        apiBaseUrl: apiBaseUrl,
        function: 'config_files',
      );
      if (data != null) {
        final parsed = _parseList(data is List
            ? data
            : (data is Map<String, dynamic>
                ? data['data'] ?? const []
                : const []));
        if (parsed.isNotEmpty) return parsed;
      }
    } catch (_) {
      // 兼容失败继续内置。
    }
    final response =
        await DioClient.dio.get<dynamic>('$apiBaseUrl/configs/files');
    final data = parseQlResponse(response);
    if (data is List) return _parseList(data);
    if (data is Map<String, dynamic>) {
      final list = data['data'] ?? const [];
      if (list is List) return _parseList(list);
    }
    return const [];
  }

  static List<ConfigFile> _parseList(List<dynamic> data) {
    return [
      for (final item in data)
        if (item is String)
          ConfigFile(name: item)
        else if (item is Map<String, dynamic>)
          ConfigFile(
            name: (item['name'] ??
                    item['title'] ??
                    item['value'] ??
                    item['file'] ??
                    '')
                .toString(),
            content: item['content']?.toString() ?? '',
          ),
    ];
  }

  static Future<String> read({
    required String apiBaseUrl,
    required String file,
  }) async {
    try {
      final data = await QinglongVersionCompat.call(
        apiBaseUrl: apiBaseUrl,
        function: 'config_read',
        pathParams: {'file': file},
      );
      if (data != null) {
        String? content;
        if (data is String) content = data;
        if (data is Map<String, dynamic>) {
          content = (data['content'] ?? data['data']) as String?;
        }
        if (content != null && content.isNotEmpty) return content;
      }
    } catch (_) {
      // 兼容失败继续内置。
    }
    final response = await DioClient.dio.get<dynamic>(
      '$apiBaseUrl/configs/$file',
    );
    final data = parseQlResponse(response);
    if (data is String) return data;
    if (data is Map<String, dynamic>) {
      final content = data['content'] ?? data['data'];
      if (content is String) return content;
    }
    return data?.toString() ?? '';
  }

  static Future<void> save({
    required String apiBaseUrl,
    required String file,
    required String content,
  }) async {
    try {
      final data = await QinglongVersionCompat.call(
        apiBaseUrl: apiBaseUrl,
        function: 'config_save',
        pathParams: {'file': file},
        body: {'content': content},
      );
      if (data != null) return;
    } catch (_) {
      // 兼容失败继续内置。
    }
    final response = await DioClient.dio.post<dynamic>(
      '$apiBaseUrl/configs/save',
      data: {'name': file, 'content': content},
    );
    parseQlResponse(response);
  }
}
