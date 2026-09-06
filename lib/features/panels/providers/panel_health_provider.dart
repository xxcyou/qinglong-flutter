import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/secure_storage.dart';
import '../../crons/models/cron_task.dart';
import '../models/panel_info.dart';
import 'panel_token_manager.dart';
import 'panel_list_provider.dart';

/// 一个面板的健康快照。
class PanelHealth {
  const PanelHealth({
    this.checking = false,
    this.online,
    this.version = '',
    this.latencyMs = 0,
    this.total = 0,
    this.running = 0,
    this.disabled = 0,
    this.failed = 0,
    this.idle = 0,
    this.error = '',
    this.checkedAt,
  });

  final bool checking;

  /// null = 还没探测过。
  final bool? online;
  final String version;
  final int latencyMs;

  final int total;
  final int running;
  final int disabled;
  final int failed;

  /// 启用且上次成功（或还没跑过）的任务数。
  final int idle;

  final String error;
  final DateTime? checkedAt;

  PanelHealth copyWith({
    bool? checking,
    bool? online,
    String? version,
    int? latencyMs,
    int? total,
    int? running,
    int? disabled,
    int? failed,
    int? idle,
    String? error,
    DateTime? checkedAt,
  }) {
    return PanelHealth(
      checking: checking ?? this.checking,
      online: online ?? this.online,
      version: version ?? this.version,
      latencyMs: latencyMs ?? this.latencyMs,
      total: total ?? this.total,
      running: running ?? this.running,
      disabled: disabled ?? this.disabled,
      failed: failed ?? this.failed,
      idle: idle ?? this.idle,
      error: error ?? this.error,
      checkedAt: checkedAt ?? this.checkedAt,
    );
  }
}

/// 面板状态探测。
///
/// 为什么不用全局 DioClient：那个实例的 token 只对"当前面板"有效，
/// 而这里要同时探测列表里的每一个面板。所以自己起一个 Dio，
/// 每次请求现读该面板的 token。
class PanelHealthNotifier extends Notifier<Map<String, PanelHealth>> {
  @override
  Map<String, PanelHealth> build() => const {};

  final Dio _dio = Dio(
    BaseOptions(
      // 面板一般在内网，探测要快失败，不要让列表卡在转圈上。
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 8),
      headers: {'Content-Type': 'application/json'},
      validateStatus: (code) => code != null && code < 500,
    ),
  );

  PanelHealth healthOf(String id) => state[id] ?? const PanelHealth();

  void _put(String id, PanelHealth health) {
    state = {...state, id: health};
  }

  Future<void> refreshAll() async {
    final panels = ref.read(panelListProvider);
    await Future.wait([for (final p in panels) refresh(p)]);
  }

  /// [afterRenew] 内部用：换票后只允许再试一次，否则 401 会无限递归，
  /// 界面永远停在"检测中…"。
  Future<void> refresh(PanelInfo panel, {bool afterRenew = false}) async {
    _put(panel.id, healthOf(panel.id).copyWith(checking: true, error: ''));
    final started = DateTime.now();
    try {
      // 探测也要走令牌管家：否则面板列表会拿一张过期票去问，
      // 结果永远显示"登录已过期"，而真正的问题只是没人去续期。
      final token = await PanelTokenManager.token(panel);
      if (token == null || token.isEmpty) {
        _put(
          panel.id,
          healthOf(panel.id).copyWith(
            checking: false,
            online: false,
            error: '还没登录过这个面板，点进去连接一次',
            checkedAt: DateTime.now(),
          ),
        );
        return;
      }
      final tokenType = await SecureStorage.readTokenType(panel.id) ?? 'Bearer';
      final headers = {'Authorization': '$tokenType $token'};

      final systemResponse = await _dio.get<dynamic>(
        '${panel.apiBaseUrl}/system',
        options: Options(headers: headers),
      );
      final latency = DateTime.now().difference(started).inMilliseconds;
      final systemData = systemResponse.data;
      if (systemResponse.statusCode == 401) {
        // 401 后强制换一张票再试一次："过期"和"凭据错"要分清楚。
        if (!afterRenew) {
          final renewed = await PanelTokenManager.renew(panel);
          if (renewed != null && renewed.isNotEmpty) {
            return refresh(panel, afterRenew: true);
          }
        }
        _put(
          panel.id,
          healthOf(panel.id).copyWith(
            checking: false,
            online: false,
            latencyMs: latency,
            error: afterRenew
                ? '重新登录后仍被拒（401），检查用户名密码或 OpenAPI 权限'
                : '登录已过期（401），进去重连一次',
            checkedAt: DateTime.now(),
          ),
        );
        return;
      }
      var version = '';
      if (systemData is Map) {
        final data = systemData['data'];
        if (data is Map && data['version'] != null) {
          version = data['version'].toString();
        } else if (systemData['version'] != null) {
          version = systemData['version'].toString();
        }
      }

      // 任务统计：一次拉回来自己数，比多次请求快。
      var total = 0;
      var running = 0;
      var disabled = 0;
      var failed = 0;
      var idle = 0;
      try {
        final cronResponse = await _dio.get<dynamic>(
          '${panel.apiBaseUrl}/crons',
          queryParameters: {'page': 1, 'pageSize': 300},
          options: Options(headers: headers),
        );
        final raw = cronResponse.data;
        final list = raw is Map
            ? (raw['data'] is Map ? (raw['data'] as Map)['data'] : raw['data'])
            : raw;
        if (list is List) {
          for (final item in list) {
            if (item is! Map<String, dynamic>) continue;
            final task = CronTask.fromJson(item);
            total++;
            if (task.pid != null && task.pid != 0) {
              running++;
            } else if (task.isDisabled) {
              disabled++;
            } else if (task.lastResult == 'error') {
              failed++;
            } else {
              idle++;
            }
          }
        }
      } catch (_) {
        // 统计失败不影响"在线"判断：能拿到 /system 就说明面板活着。
      }

      _put(
        panel.id,
        PanelHealth(
          checking: false,
          online: true,
          version: version,
          latencyMs: latency,
          total: total,
          running: running,
          disabled: disabled,
          failed: failed,
          idle: idle,
          checkedAt: DateTime.now(),
        ),
      );
    } catch (e) {
      _put(
        panel.id,
        healthOf(panel.id).copyWith(
          checking: false,
          online: false,
          latencyMs: DateTime.now().difference(started).inMilliseconds,
          error: _friendly(e),
          checkedAt: DateTime.now(),
        ),
      );
    }
  }

  String _friendly(Object e) {
    final text = e.toString();
    if (text.contains('Failed host lookup')) return '域名解析失败';
    if (text.contains('Connection refused')) return '连接被拒绝，端口不对或服务没起';
    if (text.contains('timeout') || text.contains('Timeout')) return '连接超时';
    if (text.contains('CERTIFICATE')) return '证书不被信任（可在设置里允许自签名）';
    return '连不上：$text';
  }
}

final panelHealthProvider =
    NotifierProvider<PanelHealthNotifier, Map<String, PanelHealth>>(
  PanelHealthNotifier.new,
);
