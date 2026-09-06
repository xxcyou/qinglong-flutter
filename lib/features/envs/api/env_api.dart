import '../../../core/network/dio_client.dart';
import '../models/env_var.dart';

/// 环境变量 API。
class EnvApi {
  EnvApi._();

  static Future<List<EnvVar>> list({
    required String apiBaseUrl,
    String? searchValue,
  }) async {
    final response = await DioClient.dio.get<dynamic>(
      '$apiBaseUrl/envs',
      queryParameters: {
        if (searchValue != null && searchValue.isNotEmpty)
          'searchValue': searchValue,
      },
    );
    final data = parseQlResponse(response);
    if (data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(EnvVar.fromJson)
          .toList();
    }
    if (data is Map<String, dynamic>) {
      final list = data['data'] ?? const [];
      if (list is List) {
        return list
            .whereType<Map<String, dynamic>>()
            .map(EnvVar.fromJson)
            .toList();
      }
    }
    return const [];
  }

  static Future<EnvVar> create({
    required String apiBaseUrl,
    required EnvVar env,
  }) async {
    final response = await DioClient.dio.post<dynamic>(
      '$apiBaseUrl/envs',
      data: [
        {
          'name': env.name,
          'value': env.value,
          if (env.remarks != null) 'remarks': env.remarks,
        },
      ],
    );
    final data = parseQlResponse(response);
    if (data is List && data.isNotEmpty && data.first is Map<String, dynamic>) {
      return EnvVar.fromJson(data.first as Map<String, dynamic>);
    }
    if (data is Map<String, dynamic>) return EnvVar.fromJson(data);
    return env;
  }

  static Future<void> update({
    required String apiBaseUrl,
    required EnvVar env,
  }) async {
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/envs',
      data: {
        if (env.id != null) 'id': env.id,
        'name': env.name,
        'value': env.value,
        if (env.remarks != null) 'remarks': env.remarks,
      },
    );
    parseQlResponse(response);
  }

  static Future<void> delete({
    required String apiBaseUrl,
    required List<int> ids,
  }) async {
    final response = await DioClient.dio.delete<dynamic>(
      '$apiBaseUrl/envs',
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
      '$apiBaseUrl/envs/${enabled ? 'enable' : 'disable'}',
      data: ids,
    );
    parseQlResponse(response);
  }
}
