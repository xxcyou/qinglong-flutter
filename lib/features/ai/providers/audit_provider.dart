import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/audit_log.dart';
import '../services/round_archive_service.dart';

class AuditState {
  const AuditState({this.logs = const []});

  final List<AuditLog> logs;

  AuditState copyWith({List<AuditLog>? logs}) =>
      AuditState(logs: logs ?? this.logs);
}

/// 审计数据按会话存放，不再全局共享。
///
/// 文件位置：<app>/ai_rounds/<sessionId>/audit.json
/// 删会话时整个会话目录被 RoundArchiveService 删除，审计跟着一起消失。
class AuditNotifier extends Notifier<AuditState> {
  static const _fileName = 'audit.json';
  static const _maxLogs = 100;

  /// 旧版审计存在 SharedPreferences，全局共享且最多 200 条。
  /// 迁移到会话目录后这个键不再使用，第一次加载时顺手删掉，清掉旧缓存。
  static const _legacyPrefsKey = 'ai_audit_logs_v1';
  static bool _legacyCleared = false;

  String? _loadedSessionId;

  Future<void> _clearLegacyPrefsOnce() async {
    if (_legacyCleared) return;
    _legacyCleared = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_legacyPrefsKey);
    } catch (_) {}
  }

  @override
  AuditState build() => const AuditState();

  Future<File> _file(String sessionId) async {
    final dir = await RoundArchiveService.instance.sessionDirectory(sessionId);
    return File('${dir.path}/$_fileName');
  }

  Future<void> load(String sessionId) async {
    await _clearLegacyPrefsOnce();
    if (state.logs.isNotEmpty && _loadedSessionId == sessionId) return;
    _loadedSessionId = sessionId;
    try {
      final file = await _file(sessionId);
      if (!await file.exists()) {
        state = const AuditState();
        return;
      }
      final raw = await file.readAsString();
      final list = (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(AuditLogCodec.fromJson)
          .toList();
      state = state.copyWith(logs: list);
    } catch (_) {
      state = const AuditState();
    }
  }

  Future<void> add({
    required String sessionId,
    required String module,
    required String action,
    required String detail,
    required String result,
  }) async {
    await addAll(
      [
        AuditLog(
          time: DateTime.now(),
          module: module,
          action: action,
          detail: detail,
          result: result,
        ),
      ],
      sessionId: sessionId,
    );
  }

  /// 批量写入当前会话审计。
  ///
  /// 多次写共享同一个文件，先读最新内容再 append，避免并发互相覆盖。
  Future<void> addAll(
    List<AuditLog> entries, {
    required String sessionId,
  }) async {
    if (entries.isEmpty) return;
    await load(sessionId);
    final logs = [...entries.reversed, ...state.logs];
    if (logs.length > _maxLogs) {
      logs.removeRange(_maxLogs, logs.length);
    }
    state = state.copyWith(logs: logs);
    final file = await _file(sessionId);
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsString(
      jsonEncode([for (final item in logs) item.toJson()]),
      flush: true,
    );
  }

  Future<void> clear(String sessionId) async {
    _loadedSessionId = sessionId;
    state = const AuditState();
    try {
      final file = await _file(sessionId);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

final auditProvider =
    NotifierProvider<AuditNotifier, AuditState>(AuditNotifier.new);
