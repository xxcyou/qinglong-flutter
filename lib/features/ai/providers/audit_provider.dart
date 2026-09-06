import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/audit_log.dart';

class AuditState {
  const AuditState({this.logs = const []});

  final List<AuditLog> logs;

  AuditState copyWith({List<AuditLog>? logs}) =>
      AuditState(logs: logs ?? this.logs);
}

class AuditNotifier extends Notifier<AuditState> {
  static const _prefsKey = 'ai_audit_logs_v1';
  static const _maxLogs = 200;

  @override
  AuditState build() => const AuditState();

  Future<void> load() async {
    if (state.logs.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(AuditLogCodec.fromJson)
          .toList();
      state = state.copyWith(logs: list);
    } catch (_) {}
  }

  Future<void> add({
    required String module,
    required String action,
    required String detail,
    required String result,
  }) async {
    await addAll([
      AuditLog(
        time: DateTime.now(),
        module: module,
        action: action,
        detail: detail,
        result: result,
      ),
    ]);
  }

  /// 批量写入。
  ///
  /// 逐条 add 会连续 await SharedPreferences，几十次工具调用写下来又慢又容易
  /// 互相覆盖状态，所以一次运行的工具记录一起落盘。
  Future<void> addAll(List<AuditLog> entries) async {
    if (entries.isEmpty) return;
    await load();
    final logs = [...entries.reversed, ...state.logs];
    if (logs.length > _maxLogs) logs.removeRange(_maxLogs, logs.length);
    state = state.copyWith(logs: logs);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode([for (final item in logs) item.toJson()]),
    );
  }

  Future<void> clear() async {
    state = const AuditState();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}

final auditProvider =
    NotifierProvider<AuditNotifier, AuditState>(AuditNotifier.new);
