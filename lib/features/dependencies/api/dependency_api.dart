import '../../../core/network/dio_client.dart';
import '../models/dependency.dart';

/// 依赖管理 API。
class DependencyApi {
  DependencyApi._();

  static Future<List<Dependency>> list({
    required String apiBaseUrl,
    required int type,
  }) async {
    // 2.15 后端 DependenceTypes 是枚举，列表查询必须传枚举名：
    // nodejs / python3 / linux。传数字 0/1/2 会被反向映射成字符串导致查不到数据。
    if (type < 0) {
      // v2.15 没有“全部”接口，逐个请求再合并。
      final result = <Dependency>[];
      final seen = <int>{};
      for (final t in const ['nodejs', 'python3', 'linux']) {
        final items = await _fetchByType(apiBaseUrl, t);
        for (final item in items) {
          if (item.id == null || seen.add(item.id!)) {
            result.add(item);
          }
        }
      }
      return result;
    }
    const typeNames = ['nodejs', 'python3', 'linux'];
    return _fetchByType(apiBaseUrl, typeNames[type]);
  }

  static Future<List<Dependency>> _fetchByType(
    String apiBaseUrl,
    String typeName,
  ) async {
    final response = await DioClient.dio.get<dynamic>(
      '$apiBaseUrl/dependencies',
      queryParameters: {'type': typeName},
    );
    final data = parseQlResponse(response);
    if (data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(Dependency.fromJson)
          .toList();
    }
    if (data is Map<String, dynamic>) {
      final list = data['data'] ?? const [];
      if (list is List) {
        return list
            .whereType<Map<String, dynamic>>()
            .map(Dependency.fromJson)
            .toList();
      }
    }
    return const [];
  }

  static Future<void> install({
    required String apiBaseUrl,
    required int type,
    required List<String> names,
  }) async {
    final response = await DioClient.dio.post<dynamic>(
      '$apiBaseUrl/dependencies',
      data: [
        for (final name in names) {'type': type, 'name': name},
      ],
    );
    parseQlResponse(response);
  }

  static Future<void> remove({
    required String apiBaseUrl,
    required List<int> ids,
  }) async {
    final response = await DioClient.dio.delete<dynamic>(
      '$apiBaseUrl/dependencies',
      data: ids,
    );
    parseQlResponse(response);
  }

  static Future<void> reinstall({
    required String apiBaseUrl,
    required List<int> ids,
  }) async {
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/dependencies/reinstall',
      data: ids,
    );
    parseQlResponse(response);
  }

  static Future<void> update({
    required String apiBaseUrl,
    required int id,
    required int type,
    required String name,
  }) async {
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/dependencies',
      data: {'id': id, 'type': type, 'name': name},
    );
    parseQlResponse(response);
  }
}
