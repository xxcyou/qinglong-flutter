import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 面板升级后对 APP 内置接口的运行时覆盖规则。
///
/// 原理：Dio 发出请求前，[apply] 会按当前面板版本匹配规则，改写请求
/// path / query。规则由 AI 通过 `app_api_override_update` 写入并持久化，
/// 这样面板升级导致的内置接口不兼容可以在不重装 APP 的情况下修正。
class ApiOverrideRule {
  const ApiOverrideRule({
    required this.method,
    required this.path,
    this.version = '',
    this.newPath,
    this.queryAdd = const {},
    this.queryRemove = const [],
    this.reason = '',
  });

  /// 匹配的 HTTP 方法，'*' 表示所有。
  final String method;

  /// 匹配的面板 API 路径后缀（相对 /api 或 /open），如 `/crons`。
  final String path;

  /// 可选：只在这个面板版本（前缀匹配）下生效。留空表示所有版本。
  final String version;

  /// 改写后的路径后缀，如 `/crons/v2`。
  final String? newPath;

  /// 追加/覆盖的查询参数。
  final Map<String, String> queryAdd;

  /// 要移除的查询参数名。
  final List<String> queryRemove;

  /// 给人看的说明。
  final String reason;

  Map<String, dynamic> toJson() => {
        'method': method,
        'path': path,
        'version': version,
        'newPath': newPath,
        'queryAdd': queryAdd,
        'queryRemove': queryRemove,
        'reason': reason,
      };

  factory ApiOverrideRule.fromJson(Map<String, dynamic> json) {
    return ApiOverrideRule(
      method: json['method']?.toString().toUpperCase() ?? '*',
      path: json['path']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      newPath: json['newPath']?.toString(),
      queryAdd: json['queryAdd'] is Map
          ? {
              for (final e in (json['queryAdd'] as Map).entries)
                '${e.key}': '${e.value}',
            }
          : const {},
      queryRemove: [
        for (final e in (json['queryRemove'] as List? ?? const []))
          e.toString(),
      ],
      reason: json['reason']?.toString() ?? '',
    );
  }
}

class ApiOverrideRegistry {
  ApiOverrideRegistry._();

  static const _rulesKey = 'ql_api_override_rules_v1';
  static const _versionKey = 'ql_api_override_version_v1';

  static final Map<String, List<ApiOverrideRule>> _rulesByPanel = {};
  static final Map<String, String> _versionsByPanel = {};
  static String currentPanelId = '';
  static bool _loaded = false;

  static String get _key =>
      currentPanelId.isEmpty ? '__global__' : currentPanelId;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final rawRules = sp.getString(_rulesKey);
      if (rawRules != null && rawRules.isNotEmpty) {
        final decoded = jsonDecode(rawRules);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            final list = entry.value;
            if (list is List) {
              _rulesByPanel[entry.key] = [
                for (final item in list)
                  if (item is Map<String, dynamic>)
                    ApiOverrideRule.fromJson(item),
              ];
            }
          }
        }
      }
      final rawVersions = sp.getString(_versionKey);
      if (rawVersions != null && rawVersions.isNotEmpty) {
        final decoded = jsonDecode(rawVersions);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            _versionsByPanel[entry.key] = '${entry.value}';
          }
        }
      }
    } catch (_) {
      // 解析失败按空规则处理，不能让覆盖层把 APP 自己的请求搞挂。
      _rulesByPanel.clear();
      _versionsByPanel.clear();
    }
  }

  static Future<void> save({
    List<ApiOverrideRule>? rules,
    String? version,
  }) async {
    await ensureLoaded();
    if (rules != null) _rulesByPanel[_key] = rules;
    if (version != null) _versionsByPanel[_key] = version;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _rulesKey,
      jsonEncode({
        for (final e in _rulesByPanel.entries)
          e.key: [for (final r in e.value) r.toJson()],
      }),
    );
    await sp.setString(
      _versionKey,
      jsonEncode(_versionsByPanel),
    );
  }

  static Future<void> clear() async {
    await ensureLoaded();
    _rulesByPanel.remove(_key);
    _versionsByPanel.remove(_key);
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _rulesKey,
      jsonEncode({
        for (final e in _rulesByPanel.entries)
          e.key: [for (final r in e.value) r.toJson()],
      }),
    );
    await sp.setString(_versionKey, jsonEncode(_versionsByPanel));
  }

  static List<ApiOverrideRule> get rules => _rulesByPanel[_key] ?? const [];

  static String get currentVersion => _versionsByPanel[_key] ?? '';

  /// 返回是否匹配当前版本。空版本规则对所有版本生效。
  static bool _versionMatches(String ruleVersion) {
    if (ruleVersion.isEmpty) return true;
    final version = currentVersion;
    if (version.isEmpty) return false;
    return version.startsWith(ruleVersion);
  }

  /// 应用覆盖。返回是否发生了改写。
  static Future<bool> apply(RequestOptions options) async {
    await ensureLoaded();
    final activeRules = _rulesByPanel[_key] ?? const [];
    if (activeRules.isEmpty) return false;

    final originalPath = options.path;
    final uri = Uri.tryParse(originalPath);
    if (uri == null || !uri.hasScheme) return false;

    final uriPath = uri.path;
    final container = uriPath.startsWith('/open')
        ? '/open'
        : uriPath.startsWith('/api')
            ? '/api'
            : '';
    if (container.isEmpty) return false;
    var suffix = uriPath.substring(container.length);
    if (!suffix.startsWith('/')) suffix = '/$suffix';

    var changed = false;
    for (final rule in activeRules) {
      final methodOk = rule.method == '*' ||
          rule.method.toUpperCase() == options.method.toUpperCase();
      if (!methodOk || !_versionMatches(rule.version)) continue;
      if (!_pathMatches(suffix, rule.path)) continue;

      if (rule.newPath != null && rule.newPath!.isNotEmpty) {
        var np = rule.newPath!;
        if (!np.startsWith('/')) np = '/$np';
        suffix = np;
        changed = true;
      }
      if (rule.queryRemove.isNotEmpty) {
        for (final key in rule.queryRemove) {
          options.queryParameters.remove(key);
        }
        changed = true;
      }
      if (rule.queryAdd.isNotEmpty) {
        options.queryParameters.addAll(rule.queryAdd);
        changed = true;
      }
    }

    if (!changed) return false;
    final newUri = uri.replace(path: '$container$suffix');
    options.path = newUri.toString();
    return true;
  }

  static bool _pathMatches(String suffix, String rulePath) {
    var rp = rulePath;
    if (!rp.startsWith('/')) rp = '/$rp';
    if (rp == '/*') return true;
    if (rp.endsWith('*')) {
      return suffix.startsWith(rp.substring(0, rp.length - 1));
    }
    return suffix == rp;
  }
}
