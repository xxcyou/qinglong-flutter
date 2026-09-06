import 'package:flutter/material.dart';

enum ApiDebugKind {
  request('请求', Icons.send_outlined),
  response('响应', Icons.check_circle_outline),
  error('错误', Icons.error_outline);

  const ApiDebugKind(this.label, this.icon);
  final String label;
  final IconData icon;
}

class ApiDebugEntry {
  const ApiDebugEntry({
    required this.time,
    required this.kind,
    required this.method,
    required this.uri,
    this.statusCode,
    this.durationMs,
    this.message,
    this.detail,
  });

  final DateTime time;
  final ApiDebugKind kind;
  final String method;
  final String uri;
  final int? statusCode;
  final int? durationMs;
  final String? message;
  final String? detail;

  String get timeText {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}

/// 全局 API 调试日志（内存型，保留最近 300 条）。
class ApiDebugLog extends ChangeNotifier {
  ApiDebugLog._();

  static final ApiDebugLog instance = ApiDebugLog._();

  /// 调试日志总开关；设置页“调试日志”开关控制。
  static bool enabled = true;

  static const int maxEntries = 300;
  final List<ApiDebugEntry> _entries = [];
  bool _notifyScheduled = false;

  List<ApiDebugEntry> get entries => List.unmodifiable(_entries);

  void add({
    required ApiDebugKind kind,
    required String method,
    required String uri,
    int? statusCode,
    int? durationMs,
    String? message,
    String? detail,
  }) {
    if (!enabled) return;
    _entries.insert(
      0,
      ApiDebugEntry(
        time: DateTime.now(),
        kind: kind,
        method: method,
        uri: uri,
        statusCode: statusCode,
        durationMs: durationMs,
        message: message,
        detail: detail,
      ),
    );
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    final detailPart = detail != null && detail.isNotEmpty ? ' | $detail' : '';
    debugPrint(
      '[API] $method $uri '
      '${statusCode != null ? 'status=$statusCode ' : ''}'
      '${durationMs != null ? '${durationMs}ms ' : ''}'
      '${message ?? ''}$detailPart',
    );
    _scheduleNotify();
  }

  void clear() {
    _entries.clear();
    debugPrint('[API] 调试日志已清空');
    _scheduleNotify();
  }

  String export() {
    final buffer = StringBuffer();
    for (final e in _entries) {
      buffer.writeln(
        '${e.timeText} [${e.kind.label}] '
        '${e.method} ${e.uri} '
        '${e.statusCode != null ? 'HTTP ${e.statusCode} ' : ''}'
        '${e.durationMs != null ? '${e.durationMs}ms ' : ''}'
        '${e.message ?? ''}'
        '${e.detail != null ? ' | ${e.detail}' : ''}',
      );
    }
    return buffer.toString();
  }

  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    Future.microtask(() {
      _notifyScheduled = false;
      notifyListeners();
    });
  }
}
