import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_overrides.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/error_handler.dart';

/// 青龙版本接口适配“插件”。
///
/// 每个版本一个 Plugin，里面声明一组“内置青龙函数”的请求/响应转换规则。
/// APP 固定函数（ScriptApi 等）先查当前面板版本的 Plugin；没有才走内置硬编码。
/// 这样青龙版本升级/切换时，不用改 APP 代码，只要更新对应版本的 Plugin。
class QinglongApiAdapterPlugin {
  const QinglongApiAdapterPlugin({
    required this.version,
    required this.name,
    required this.functions,
  });

  final String version;
  final String name;

  /// function name -> spec
  final Map<String, QinglongFunctionSpec> functions;

  Map<String, dynamic> toJson() => {
        'version': version,
        'name': name,
        'functions': {
          for (final e in functions.entries) e.key: e.value.toJson(),
        },
      };

  factory QinglongApiAdapterPlugin.fromJson(Map<String, dynamic> json) {
    final rawFunctions = json['functions'];
    return QinglongApiAdapterPlugin(
      version: (json['version'] ?? '').toString().trim(),
      name: (json['name'] ?? json['version'] ?? '').toString().trim(),
      functions: rawFunctions is Map
          ? {
              for (final e in rawFunctions.entries)
                '${e.key}': QinglongFunctionSpec.fromJson(
                    e.value is Map<String, dynamic>
                        ? e.value
                        : <String, dynamic>{}),
            }
          : const {},
    );
  }
}

/// 单个“内置青龙函数”的适配规则。
///
/// 示例（script_read，青龙 2.16+）：
/// {
///   "method": "GET",
///   "path": "/scripts/detail",
///   "query": {"path": "{dir}", "file": "{name}"},
///   "body": {},
///   "responseDataPath": ["data"]
/// }
class QinglongFunctionSpec {
  const QinglongFunctionSpec({
    this.method = 'GET',
    required this.path,
    this.query = const {},
    this.body = const {},
    this.responseDataPath = const [],
    this.responseContentKeys = const ['content'],
  });

  final String method;
  final String path;

  /// query 模板值里的 {xxx} 会从调用参数中替换。
  final Map<String, String> query;

  /// body 模板值里的 {xxx} 会从调用参数中替换；body 内可嵌套。
  final Map<String, dynamic> body;

  /// 对 parseQlResponse 后的结果继续取路径，如 ["data"] 取 data.data。
  final List<String> responseDataPath;

  /// 读文件时从 Map 里找内容的候选字段。
  final List<String> responseContentKeys;

  Map<String, dynamic> toJson() => {
        'method': method.toUpperCase(),
        'path': path,
        'query': query,
        'body': body,
        'responseDataPath': responseDataPath,
        'responseContentKeys': responseContentKeys,
      };

  factory QinglongFunctionSpec.fromJson(Map<String, dynamic> json) {
    return QinglongFunctionSpec(
      method: (json['method'] ?? 'GET').toString().toUpperCase(),
      path: (json['path'] ?? '').toString(),
      query: json['query'] is Map
          ? {
              for (final e in (json['query'] as Map).entries)
                '${e.key}': '${e.value}',
            }
          : const {},
      body: json['body'] is Map
          ? (json['body'] as Map).cast<String, dynamic>()
          : const {},
      responseDataPath: [
        for (final e in (json['responseDataPath'] as List? ?? const []))
          e.toString(),
      ],
      responseContentKeys: [
        for (final e in (json['responseContentKeys'] as List? ??
            const ['content']))
          e.toString(),
      ],
    );
  }
}

class QinglongApiAdapterRegistry {
  QinglongApiAdapterRegistry._();

  static const _pluginsKey = 'ql_panel_api_adapter_plugins_v1';

  static final Map<String, QinglongApiAdapterPlugin> _pluginsByVersion = {};
  static bool _loaded = false;

  static Future<void> ensureLoaded() async {
    await ApiOverrideRegistry.ensureLoaded();
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_pluginsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            if (entry.value is Map<String, dynamic>) {
              final plugin = QinglongApiAdapterPlugin.fromJson(
                  entry.value as Map<String, dynamic>);
              if (plugin.version.isNotEmpty) {
                _pluginsByVersion[plugin.version.trim()] = plugin;
              }
            }
          }
        }
      }
    } catch (_) {
      _pluginsByVersion.clear();
    }
  }

  static Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _pluginsKey,
      jsonEncode({
        for (final e in _pluginsByVersion.entries) e.key: e.value.toJson(),
      }),
    );
  }

  static Future<void> upsert(QinglongApiAdapterPlugin plugin) async {
    await ensureLoaded();
    _pluginsByVersion[plugin.version.trim()] = plugin;
    await _persist();
  }

  static Future<void> remove(String version) async {
    await ensureLoaded();
    _pluginsByVersion.remove(version.trim());
    await _persist();
  }

  static List<QinglongApiAdapterPlugin> get all => _pluginsByVersion.values.toList();

  static QinglongApiAdapterPlugin? pluginForVersion(String version) {
    final v = version.trim();
    if (v.isEmpty) return null;
    // 先精确，再前缀（如 2.16 匹配 2.16.3）。
    if (_pluginsByVersion.containsKey(v)) return _pluginsByVersion[v];
    for (final entry in _pluginsByVersion.entries) {
      if (v.startsWith(entry.key) || entry.key.startsWith(v)) {
        return entry.value;
      }
    }
    return null;
  }

  /// 当前默认面板版本对应的插件。
  static Future<QinglongApiAdapterPlugin?> currentPlugin() async {
    await ensureLoaded();
    final version = ApiOverrideRegistry.currentVersion.trim();
    return pluginForVersion(version);
  }

  /// 当前面板版本是否已定义某个内置函数。
  static Future<bool> hasFunction(String function) async {
    final plugin = await currentPlugin();
    return plugin?.functions.containsKey(function) ?? false;
  }

  static Future<QinglongFunctionSpec?> specFor(String function) async {
    final plugin = await currentPlugin();
    return plugin?.functions[function];
  }

  /// 按插件规则发起请求，返回已经按 responseDataPath 提取后的结果。
  /// 没有插件或函数未定义时返回 null，调用方回退到内置硬编码。
  static Future<dynamic> invoke({
    required String apiBaseUrl,
    required String function,
    Map<String, String> pathParams = const {},
    Map<String, dynamic> query = const {},
    Map<String, dynamic> body = const {},
  }) async {
    final spec = await specFor(function);
    if (spec == null) return null;

    try {
      final path = _render(spec.path, pathParams);
      final queryParameters = <String, dynamic>{
        for (final e in spec.query.entries)
          e.key: _renderValue(e.value, pathParams, query),
      };
      final requestBody = _renderBody(spec.body, pathParams, query);

      final response = await DioClient.dio.request<dynamic>(
        '$apiBaseUrl$path',
        options: Options(method: spec.method),
        queryParameters: queryParameters,
        data: requestBody.isEmpty ? null : requestBody,
      );
      var data = parseQlResponse(response);
      for (final key in spec.responseDataPath) {
        if (data is Map) {
          data = data[key];
        } else if (data is List && key == 'list') {
          data = data;
        } else {
          return data;
        }
      }
      return data;
    } on DioException catch (e) {
      throw ApiException(message: readableError(e));
    }
  }

  static String _render(String template, Map<String, String> params) {
    var out = template;
    params.forEach((k, v) => out = out.replaceAll('{$k}', v));
    return out;
  }

  static dynamic _renderValue(
    String template,
    Map<String, String> params,
    Map<String, dynamic> values,
  ) {
    var out = template;
    params.forEach((k, v) => out = out.replaceAll('{$k}', v));
    values.forEach((k, v) {
      if (v != null) out = out.replaceAll('{$k}', v.toString());
    });
    try {
      final decoded = jsonDecode(out);
      if (decoded is String && decoded == template) return template;
      return decoded;
    } catch (_) {
      if (out == 'true') return true;
      if (out == 'false') return false;
      if (out == 'null') return null;
      final numV = num.tryParse(out);
      if (numV != null && !out.contains(' ')) return numV;
      return out;
    }
  }

  static Map<String, dynamic> _renderBody(
    Map<String, dynamic> template,
    Map<String, String> params,
    Map<String, dynamic> values,
  ) {
    final rendered = <String, dynamic>{};
    template.forEach((k, v) {
      if (v is String) {
        rendered[k] = _renderValue(v, params, values);
      } else if (v is Map) {
        rendered[k] = _renderNested(v, params, values);
      } else if (v is List) {
        rendered[k] = [
          for (final item in v)
            if (item is String) _renderValue(item, params, values) else item,
        ];
      } else {
        rendered[k] = v;
      }
    });
    return rendered;
  }

  static Map<String, dynamic> _renderNested(
    Map<dynamic, dynamic> nested,
    Map<String, String> params,
    Map<String, dynamic> values,
  ) {
    return {
      for (final e in nested.entries)
        '${e.key}': e.value is String
            ? _renderValue(e.value as String, params, values)
            : e.value,
    };
  }
}
