import 'package:dio/dio.dart';
import 'api_overrides.dart';
import 'dio_client.dart';

/// 青龙接口多版本兼容解析器。
///
/// 每个内置函数对应一组“版本范围 → 实际接口规格”。APP 固定调用函数名，
/// 在请求前根据当前面板版本挑出该版本的 path / query / body。
///
/// 覆盖来自 docs/qinglong_api_compatibility.md（v2.10 ~ master/v2.22）。
class QinglongApiSpec {
  const QinglongApiSpec({
    required this.method,
    required this.path,
    this.query = const {},
    this.body = const {},
    this.responseDataPath = const [],
    this.responseContentKeys = const ['content'],
  });

  final String method;

  /// 相对 apiBaseUrl 的路径，如 /scripts/detail；支持 {dir} {file} 占位。
  final String path;

  /// query 模板，值里的 {dir} {file} 等会被替换。
  final Map<String, String> query;

  /// body 模板，String 值里的 {name} 等会被替换；仅一层嵌套。
  final Map<String, dynamic> body;

  /// 对 parseQlResponse 后的返回继续按 key 取。
  final List<String> responseDataPath;

  /// 读文件/日志时从 Map 里找内容的候选 key。
  final List<String> responseContentKeys;
}

class QinglongVersionRule {
  const QinglongVersionRule({
    required this.minVersion,
    required this.maxVersion,
    required this.spec,
    this.when,
  });

  final String minVersion;
  final String maxVersion;
  final QinglongApiSpec spec;

  /// 额外条件：例如旧日志 v2.10-2.12 有目录时走 /:dir/:file。
  final bool Function(Map<String, String> pathParams)? when;
}

class QinglongVersionCompat {
  QinglongVersionCompat._();

  static final Map<String, List<QinglongVersionRule>> _rules = {
    // ===== 脚本 =====
    'script_list': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '2.12',
        spec: const QinglongApiSpec(method: 'GET', path: '/scripts/files'),
      ),
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'GET', path: '/scripts'),
      ),
    ],
    'script_read': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '2.16',
        spec: const QinglongApiSpec(
          method: 'GET',
          path: '/scripts/{name}',
          query: {'path': '{dir}'},
          responseContentKeys: ['content', 'data'],
        ),
      ),
      QinglongVersionRule(
        minVersion: '2.17',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'GET',
          path: '/scripts/detail',
          query: {'path': '{dir}', 'file': '{name}'},
          responseContentKeys: ['content', 'data'],
        ),
      ),
    ],
    'script_create': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'POST',
          path: '/scripts',
          body: {'path': '{dir}', 'filename': '{name}', 'content': '{content}'},
        ),
      ),
    ],
    'script_save': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'PUT',
          path: '/scripts',
          body: {'path': '{dir}', 'filename': '{name}', 'content': '{content}'},
        ),
      ),
    ],
    'script_rename': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '2.14',
        spec: const QinglongApiSpec(
          method: 'PUT',
          path: '/scripts',
          body: {
            'path': '{dir}',
            'filename': '{name}',
            'newFilename': '{newName}',
          },
        ),
      ),
      QinglongVersionRule(
        minVersion: '2.15',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'PUT',
          path: '/scripts/rename',
          body: {
            'path': '{dir}',
            'filename': '{name}',
            'newFilename': '{newName}',
          },
        ),
      ),
    ],
    'script_delete': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'DELETE',
          path: '/scripts',
          body: {
            'path': '{dir}',
            'filename': '{name}',
            'type': '{type}',
          },
        ),
      ),
    ],
    'script_create_directory': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'POST',
          path: '/scripts',
          body: {'path': '{path}', 'directory': '{directory}'},
        ),
      ),
    ],
    'script_run': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'PUT',
          path: '/scripts/run',
          body: {'path': '{dir}', 'filename': '{name}', 'content': '{content}'},
        ),
      ),
    ],
    'script_stop': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'PUT',
          path: '/scripts/stop',
          body: {'path': '{dir}', 'filename': '{name}', 'pid': '{pid}'},
        ),
      ),
    ],

    // ===== 日志 =====
    'log_list': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'GET', path: '/logs'),
      ),
    ],
    'log_read': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '2.12',
        spec: const QinglongApiSpec(method: 'GET', path: '/logs/{dir}/{file}'),
        when: (p) => (p['dir'] ?? '').isNotEmpty,
      ),
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '2.12',
        spec: const QinglongApiSpec(method: 'GET', path: '/logs/{file}'),
        when: (p) => (p['dir'] ?? '').isEmpty,
      ),
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '2.16',
        spec: const QinglongApiSpec(
          method: 'GET',
          path: '/logs/{file}',
          query: {'path': '{dir}'},
        ),
      ),
      QinglongVersionRule(
        minVersion: '2.17',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'GET',
          path: '/logs/detail',
          query: {'path': '{dir}', 'file': '{file}'},
        ),
      ),
    ],

    // ===== 配置文件 =====
    'config_files': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'GET', path: '/configs/files'),
      ),
    ],
    'config_read': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '2.16',
        spec: const QinglongApiSpec(
          method: 'GET',
          path: '/configs/{file}',
          responseContentKeys: ['content', 'data'],
        ),
      ),
      QinglongVersionRule(
        minVersion: '2.17',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'GET',
          path: '/configs/detail',
          query: {'path': '{file}'},
          responseContentKeys: ['content', 'data'],
        ),
      ),
    ],
    'config_save': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'POST',
          path: '/configs/save',
          body: {'name': '{file}', 'content': '{content}'},
        ),
      ),
    ],

    // ===== 环境变量 =====
    'env_list': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'GET', path: '/envs'),
      ),
    ],
    'env_create': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'POST', path: '/envs'),
      ),
    ],
    'env_update': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'PUT', path: '/envs'),
      ),
    ],
    'env_delete': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'DELETE', path: '/envs'),
      ),
    ],
    'env_enable': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'PUT', path: '/envs/enable'),
      ),
    ],
    'env_disable': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'PUT', path: '/envs/disable'),
      ),
    ],

    // ===== 依赖 =====
    'dep_list': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'GET', path: '/dependencies'),
      ),
    ],
    'dep_install': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'POST', path: '/dependencies'),
      ),
    ],
    'dep_remove': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'DELETE', path: '/dependencies'),
      ),
    ],
    'dep_reinstall': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'PUT',
          path: '/dependencies/reinstall',
        ),
      ),
    ],
    'dep_update': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'PUT', path: '/dependencies'),
      ),
    ],

    // ===== 订阅 =====
    'sub_list': [
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'GET', path: '/subscriptions'),
      ),
    ],
    'sub_detail': [
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'GET', path: '/subscriptions/{id}'),
      ),
    ],
    'sub_create': [
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'POST', path: '/subscriptions'),
      ),
    ],
    'sub_update': [
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'PUT', path: '/subscriptions'),
      ),
    ],
    'sub_delete': [
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'DELETE', path: '/subscriptions'),
      ),
    ],
    'sub_run': [
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'PUT', path: '/subscriptions/run'),
      ),
    ],
    'sub_stop': [
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'PUT', path: '/subscriptions/stop'),
      ),
    ],
    'sub_enable': [
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'PUT', path: '/subscriptions/enable'),
      ),
    ],
    'sub_disable': [
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'PUT',
          path: '/subscriptions/disable',
        ),
      ),
    ],
    'sub_log': [
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'GET',
          path: '/subscriptions/{id}/log',
        ),
      ),
    ],
    'sub_logs': [
      QinglongVersionRule(
        minVersion: '2.13',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'GET',
          path: '/subscriptions/{id}/logs',
        ),
      ),
    ],

    // ===== 系统 / 设置 =====
    'sys_info': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'GET', path: '/system'),
      ),
    ],
    'sys_log_frequency_get': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '2.14',
        spec: const QinglongApiSpec(method: 'GET', path: '/system/log/remove'),
      ),
      QinglongVersionRule(
        minVersion: '2.15',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'GET', path: '/system/config'),
      ),
    ],
    'sys_log_frequency_set': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '2.14',
        spec: const QinglongApiSpec(
          method: 'PUT',
          path: '/system/log/remove',
          body: {'frequency': '{days}'},
        ),
      ),
      QinglongVersionRule(
        minVersion: '2.15',
        maxVersion: '2.16',
        spec: const QinglongApiSpec(
          method: 'PUT',
          path: '/system/config',
          body: {'logRemoveFrequency': '{days}'},
        ),
      ),
      QinglongVersionRule(
        minVersion: '2.17',
        maxVersion: '999',
        spec: const QinglongApiSpec(
          method: 'PUT',
          path: '/system/config/log-remove-frequency',
          body: {'logRemoveFrequency': '{days}'},
        ),
      ),
    ],
    'sys_update_check': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'PUT', path: '/system/update-check'),
      ),
    ],
    'sys_update': [
      QinglongVersionRule(
        minVersion: '2.10',
        maxVersion: '999',
        spec: const QinglongApiSpec(method: 'PUT', path: '/system/update'),
      ),
    ],
  };

  /// 取当前默认面板版本的接口规格；找不到返回 null（调用方回退内置硬编码）。
  static Future<QinglongApiSpec?> specForCurrentVersion(
    String function, {
    Map<String, String> pathParams = const {},
  }) async {
    await ApiOverrideRegistry.ensureLoaded();
    final version = ApiOverrideRegistry.currentVersion.trim();
    if (version.isEmpty) return null;
    return specForVersion(function, version, pathParams);
  }

  /// 直接按当前面板版本执行一个内置函数；没有规则时返回 null。
  /// 有规则但请求失败时抛异常，由调用方决定是否回退内置。
  static Future<dynamic> call({
    required String apiBaseUrl,
    required String function,
    Map<String, String> pathParams = const {},
    Map<String, dynamic> query = const {},
    dynamic body = const {},
  }) async {
    final spec = await specForCurrentVersion(function, pathParams: pathParams);
    if (spec == null) return null;

    final path = QinglongCompatRender.render(spec.path, pathParams, query);
    final queryParameters = <String, dynamic>{
      for (final e in spec.query.entries)
        e.key: QinglongCompatRender.renderValue(e.value, pathParams, query),
      // 调用方直接传的 query（如 searchValue / type / force）原样透传。
      ...query,
    };
    final requestBody = spec.body.isNotEmpty
        ? QinglongCompatRender.renderBody(
            spec.body,
            pathParams,
            body is Map ? body.cast<String, dynamic>() : const {},
          )
        : (body == null || body.isEmpty ? null : body);
    final response = await DioClient.dio.request<dynamic>(
      '$apiBaseUrl$path',
      options: Options(method: spec.method),
      queryParameters: queryParameters,
      data: requestBody == null
          ? null
          : (requestBody is List
              ? (requestBody.isEmpty ? null : requestBody)
              : (requestBody is Map && requestBody.isEmpty
                  ? null
                  : requestBody)),
    );
    return parseQlResponse(response);
  }

  static QinglongApiSpec? specForVersion(
    String function,
    String version,
    Map<String, String> pathParams,
  ) {
    final rules = _rules[function];
    if (rules == null) return null;
    for (final rule in rules) {
      if (_inRange(version, rule.minVersion, rule.maxVersion) &&
          (rule.when?.call(pathParams) ?? true)) {
        return rule.spec;
      }
    }
    return null;
  }

  static bool _inRange(String version, String min, String max) {
    return _compare(version, min) >= 0 && _compare(version, max) <= 0;
  }

  static int _compare(String a, String b) {
    final av = _parts(a);
    final bv = _parts(b);
    final len = av.length > bv.length ? av.length : bv.length;
    for (var i = 0; i < len; i++) {
      final avi = i < av.length ? av[i] : 0;
      final bvi = i < bv.length ? bv[i] : 0;
      if (avi != bvi) return avi.compareTo(bvi);
    }
    return 0;
  }

  static List<int> _parts(String version) {
    final m = RegExp(r'(\d+)(?:\.(\d+))?(?:\.(\d+))?')
        .firstMatch(version.trim());
    if (m == null) return const [0];
    return [
      int.parse(m.group(1)!),
      int.tryParse(m.group(2) ?? '') ?? 0,
      int.tryParse(m.group(3) ?? '') ?? 0,
    ];
  }
}

/// 路径/query/body 模板渲染工具。
class QinglongCompatRender {
  QinglongCompatRender._();

  static String render(
    String template,
    Map<String, String> pathParams,
    Map<String, dynamic> values,
  ) {
    var out = template;
    pathParams.forEach((k, v) => out = out.replaceAll('{$k}', v));
    values.forEach((k, v) {
      if (v != null) out = out.replaceAll('{$k}', '$v');
    });
    return out;
  }

  static dynamic renderValue(
    String template,
    Map<String, String> pathParams,
    Map<String, dynamic> values,
  ) {
    final out = render(template, pathParams, values);
    if (out == 'true') return true;
    if (out == 'false') return false;
    final numV = num.tryParse(out);
    if (numV != null && !out.contains(' ')) return numV;
    return out;
  }

  static Map<String, dynamic> renderBody(
    Map<String, dynamic> template,
    Map<String, String> pathParams,
    Map<String, dynamic> values,
  ) {
    final result = <String, dynamic>{};
    template.forEach((k, v) {
      if (v is String) {
        final rendered = renderValue(v, pathParams, values);
        // 没被替换的占位符保持字符串，避免把 {dir} 误解析成数字。
        result[k] = rendered is String && rendered.contains('{')
            ? v
            : rendered;
      } else if (v is Map) {
        result[k] = renderBody(
          v.cast<String, dynamic>(),
          pathParams,
          values,
        );
      } else if (v is List) {
        result[k] = [
          for (final item in v)
            if (item is String) renderValue(item, pathParams, values) else item,
        ];
      } else {
        result[k] = v;
      }
    });
    return result;
  }
}
