import '../../../core/network/dio_client.dart';
import '../models/config_file.dart';

/// 配置管理 API。
class ConfigApi {
  ConfigApi._();

  static Future<List<ConfigFile>> files({
    required String apiBaseUrl,
  }) async {
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
    final response = await DioClient.dio.post<dynamic>(
      '$apiBaseUrl/configs/save',
      data: {'name': file, 'content': content},
    );
    parseQlResponse(response);
  }
}
