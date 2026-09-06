import 'package:dio/dio.dart';

import '../../../core/network/dio_client.dart';
import '../models/system_info.dart';

/// 系统管理 API。
class SystemApi {
  SystemApi._();

  static Future<SystemInfo> info({required String apiBaseUrl}) async {
    final response = await DioClient.dio.get<dynamic>('$apiBaseUrl/system');
    final data = parseQlResponse(response);
    final info = data is Map<String, dynamic>
        ? SystemInfo.fromJson(data)
        : const SystemInfo();

    try {
      final freqResponse = await DioClient.dio.get<dynamic>(
        '$apiBaseUrl/system/log/remove',
      );
      final freqData = parseQlResponse(freqResponse);
      int? frequency;
      if (freqData is Map<String, dynamic>) {
        final nested = freqData['info'];
        if (nested is Map<String, dynamic>) {
          final f = nested['frequency'];
          if (f is num) frequency = f.toInt();
        }
        if (frequency == null && freqData['frequency'] is num) {
          frequency = (freqData['frequency'] as num).toInt();
        }
      }
      if (frequency != null) {
        return SystemInfo(
          version: info.version,
          logRemoveFrequency: frequency,
          data: info.data,
        );
      }
    } catch (_) {
      // 旧版有这个接口，新版可能没有；失败不影响主信息展示。
    }

    return info;
  }

  static Future<void> setLogRemoveFrequency({
    required String apiBaseUrl,
    required int days,
  }) async {
    try {
      final response = await DioClient.dio.put<dynamic>(
        '$apiBaseUrl/system/config/log-remove-frequency',
        data: {'logRemoveFrequency': days},
      );
      parseQlResponse(response);
      return;
    } on DioException catch (e) {
      // 旧版面板没有 /system/config/log-remove-frequency，回退到老接口。
      if (e.response?.statusCode != 404) rethrow;
    }
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/system/log/remove',
      data: {'frequency': days},
    );
    parseQlResponse(response);
  }

  static Future<dynamic> checkUpdate({required String apiBaseUrl}) async {
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/system/update-check',
    );
    return parseQlResponse(response);
  }

  static Future<dynamic> update({required String apiBaseUrl}) async {
    final response = await DioClient.dio.put<dynamic>(
      '$apiBaseUrl/system/update',
    );
    return parseQlResponse(response);
  }
}
