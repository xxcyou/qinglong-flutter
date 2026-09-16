import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/agent_event.dart';
import '../models/agent_task_plan.dart';

/// 完整轮本地归档：每个会话一个目录，每个完整轮一个 JSON 文件。
///
/// 主会话数据（session.json）只是索引；完整轮数据放在 rounds/ 下，
/// 平时不进模型上下文，只在 AI 明确调用 round_* 工具时按需读取。
/// 当前轮次从开跑就实时写盘（事件逐条追加），中断/继续同用一个 roundId。
class RoundArchiveService {
  RoundArchiveService._();

  static final RoundArchiveService instance = RoundArchiveService._();

  static const dirName = 'ai_rounds';

  /// 每个 roundId 一个写锁，避免并发 appendEvent 读改写互相覆盖。
  final Map<String, Future<void>> _writeLocks = {};

  Future<void> _locked(String key, Future<void> Function() action) {
    final prev = _writeLocks[key] ?? Future.value();
    final done = prev.then((_) => action());
    _writeLocks[key] = done.catchError((_) {});
    return done;
  }

  Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/$dirName');
  }

  String _safeSessionId(String sessionId) =>
      sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');

  Future<Directory> _sessionDir(String sessionId) async {
    final root = await _root();
    return Directory('${root.path}/${_safeSessionId(sessionId)}');
  }

  Future<Directory> _roundsDir(String sessionId) async {
    final dir = await _sessionDir(sessionId);
    return Directory('${dir.path}/rounds');
  }

  Future<File> _roundFile(String sessionId, String roundId) async {
    final dir = await _roundsDir(sessionId);
    return File('${dir.path}/$roundId.json');
  }

  Future<File> _sessionFile(String sessionId) async {
    final dir = await _sessionDir(sessionId);
    return File('${dir.path}/session.json');
  }

  /// 新建一个完整轮文件。已存在（continue/resume 同一个轮）时直接复用。
  Future<String> startRound(
    String sessionId,
    String roundId, {
    String userInput = '',
    String? resumeFrom,
  }) async {
    await _locked('$sessionId/$roundId', () async {
      final roundsDir = await _roundsDir(sessionId);
      await roundsDir.create(recursive: true);
      final file = await _roundFile(sessionId, roundId);
      if (!await file.exists()) {
        final now = DateTime.now().toIso8601String();
        await file.writeAsString(
          jsonEncode({
            'id': roundId,
            'sessionId': sessionId,
            'startedAt': now,
            'updatedAt': now,
            'endedAt': '',
            'outcome': '',
            'userInputs': [if (userInput.isNotEmpty) userInput],
            'assistantContent': '',
            'events': <Object>[],
            'taskPlan': const <String, dynamic>{},
            'turns': 0,
            'usage': const <String, dynamic>{},
            if (resumeFrom != null) 'resumeFrom': resumeFrom,
          }),
          flush: true,
        );
      } else if (userInput.isNotEmpty) {
        await _appendUserInputUnlocked(sessionId, roundId, userInput);
      }
      await writeSessionIndex(
        sessionId,
        endedAt: DateTime.now(),
        messageCount: null,
      );
    });
    return roundId;
  }

  Future<void> appendUserInput(
    String sessionId,
    String roundId,
    String text,
  ) async {
    if (text.trim().isEmpty) return;
    await _locked('$sessionId/$roundId', () async {
      await _appendUserInputUnlocked(sessionId, roundId, text);
    });
  }

  Future<void> _appendUserInputUnlocked(
    String sessionId,
    String roundId,
    String text,
  ) async {
    final json = await _read(sessionId, roundId);
    if (json == null) return;
    final inputs = (json['userInputs'] as List? ?? const [])
        .map((e) => e.toString())
        .toList();
    final value = text.trim();
    if (!inputs.contains(value)) {
      inputs.add(value);
      json['userInputs'] = inputs;
    }
    json['updatedAt'] = DateTime.now().toIso8601String();
    await _write(sessionId, roundId, json);
  }

  Future<void> appendEvent(
    String sessionId,
    String roundId,
    AgentEvent event,
  ) async {
    await _locked('$sessionId/$roundId', () async {
      final json = await _read(sessionId, roundId);
      if (json == null) return;
      final events = (json['events'] as List? ?? <Object>[]).toList()
        ..add(event.toJson());
      json['events'] = events;
      json['updatedAt'] = DateTime.now().toIso8601String();
      await _write(sessionId, roundId, json);
    });
  }

  Future<void> updateRound(
    String sessionId,
    String roundId, {
    String assistantContent = '',
    AgentTaskPlan? taskPlan,
    String outcome = '',
    int turns = 0,
    Map<String, dynamic>? usage,
    String? endedAt,
  }) async {
    await _locked('$sessionId/$roundId', () async {
      final json = await _read(sessionId, roundId);
      if (json == null) return;
      if (assistantContent.isNotEmpty) {
        json['assistantContent'] = assistantContent;
      }
      if (taskPlan != null) {
        json['taskPlan'] = taskPlan.toJson();
      }
      if (outcome.isNotEmpty) {
        json['outcome'] = outcome;
      }
      if (turns > 0) json['turns'] = turns;
      if (usage != null && usage.isNotEmpty) {
        json['usage'] = usage;
      }
      json['endedAt'] = endedAt ?? DateTime.now().toIso8601String();
      json['updatedAt'] = DateTime.now().toIso8601String();
      await _write(sessionId, roundId, json);
      await writeSessionIndex(sessionId, endedAt: DateTime.now());
    });
  }

  /// 主会话索引：目录里和完整轮数据并存的“主会话数据”轻量快照。
  Future<void> writeSessionIndex(
    String sessionId, {
    String title = '',
    DateTime? endedAt,
    int? messageCount,
  }) async {
    final dir = await _sessionDir(sessionId);
    await dir.create(recursive: true);
    final file = await _sessionFile(sessionId);
    Map<String, dynamic> data = {};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {}
    }
    data['sessionId'] = sessionId;
    if (title.isNotEmpty) data['title'] = title;
    data['updatedAt'] = DateTime.now().toIso8601String();
    if (messageCount != null) data['messageCount'] = messageCount;
    await file.writeAsString(jsonEncode(data), flush: true);
  }

  Future<List<Map<String, dynamic>>> listRounds(String sessionId) async {
    final dir = await _roundsDir(sessionId);
    if (!await dir.exists()) return const [];
    final files = await dir.list().toList();
    final out = <Map<String, dynamic>>[];
    for (final f in files) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await f.readAsString());
        if (json is! Map<String, dynamic>) continue;
        out.add({
          'roundId': json['id']?.toString() ?? f.uri.pathSegments.last,
          'startedAt': json['startedAt']?.toString() ??
              f.statSync().modified.toIso8601String(),
          'endedAt': json['endedAt']?.toString() ?? '',
          'outcome': json['outcome']?.toString() ?? '',
          'goal': _goalOf(json),
          'summary': _summaryOf(json),
          'turns': json['turns'] is int ? json['turns'] : 0,
        });
      } catch (_) {}
    }
    out.sort((a, b) =>
        (b['startedAt'] as String).compareTo(a['startedAt'] as String));
    return out;
  }

  Future<List<Map<String, dynamic>>> searchRounds(
    String sessionId,
    String query, {
    int maxResults = 5,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final dir = await _roundsDir(sessionId);
    if (!await dir.exists()) return const [];
    final hits = <Map<String, dynamic>>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await f.readAsString());
        if (json is! Map<String, dynamic>) continue;
        final snippets = <String>[
          for (final input in (json['userInputs'] as List? ?? const []))
            if (input.toString().toLowerCase().contains(q)) input.toString(),
          if ((json['assistantContent'] ?? '')
              .toString()
              .toLowerCase()
              .contains(q))
            json['assistantContent'].toString(),
          ..._eventSnippets(json, q),
        ].where((s) => s.trim().isNotEmpty).toList();
        if (snippets.isEmpty) continue;
        hits.add({
          'roundId': json['id']?.toString() ?? f.uri.pathSegments.last,
          'startedAt': json['startedAt']?.toString() ?? '',
          'outcome': json['outcome']?.toString() ?? '',
          'goal': _goalOf(json),
          'snippets': snippets.take(3).toList(),
        });
      } catch (_) {}
    }
    hits.sort((a, b) {
      final aCount = (a['snippets'] as List).length;
      final bCount = (b['snippets'] as List).length;
      if (aCount != bCount) return bCount.compareTo(aCount);
      return (b['startedAt'] as String).compareTo(a['startedAt'] as String);
    });
    return hits.take(maxResults).toList();
  }

  Future<String> readRound(
    String sessionId,
    String roundId, {
    bool full = false,
  }) async {
    final json = await _read(sessionId, roundId);
    if (json == null) return '未找到完整轮：$roundId（会话目录里没有这个文件）。';
    if (full) {
      final raw = jsonEncode(json);
      if (raw.length > 200000) return '${raw.substring(0, 200000)}…（超长截断）';
      return raw;
    }
    final buffer = StringBuffer('## 完整轮 ${json['id']}\n');
    buffer.writeln('时间：${json['startedAt']}');
    buffer.writeln('结束：${json['endedAt'] ?? ''}');
    buffer.writeln('结果：${json['outcome'] ?? ''}');
    buffer.writeln('轮数：${json['turns'] ?? 0}');
    final goal = _goalOf(json);
    if (goal.isNotEmpty) buffer.writeln('目标：$goal');
    final inputs = json['userInputs'] as List? ?? const [];
    if (inputs.isNotEmpty) {
      buffer.writeln('--- 用户输入 ---');
      for (final i in inputs) {
        buffer.writeln('· $i');
      }
    }
    final content = (json['assistantContent'] ?? '').toString().trim();
    if (content.isNotEmpty) {
      buffer.writeln('--- AI 最终回复 ---');
      buffer.writeln(content);
    }
    final events = json['events'] as List? ?? const [];
    buffer.writeln('--- 执行过程（${events.length} 条事件摘要）---');
    final parsedEvents = events.cast<Map<String, dynamic>>();
    final tail = parsedEvents.length <= 12
        ? parsedEvents
        : parsedEvents.sublist(parsedEvents.length - 12);
    for (final e in tail) {
      final kind = e['kind']?.toString() ?? '';
      final name = e['toolName']?.toString() ?? '';
      final msg = e['message']?.toString() ?? '';
      final res = e['result']?.toString() ?? e['fullResult']?.toString() ?? '';
      final line = '· $kind${name.isEmpty ? '' : ' [$name]'}'
          '${msg.isEmpty ? '' : ' $msg'}'
          '${res.isEmpty ? '' : '\n  ${res.length > 300 ? '${res.substring(0, 300)}…' : res}'}';
      buffer.writeln(line);
    }
    return buffer.toString().trimRight();
  }

  Future<Map<String, dynamic>?> _read(
    String sessionId,
    String roundId,
  ) async {
    final file = await _roundFile(sessionId, roundId);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(
    String sessionId,
    String roundId,
    Map<String, dynamic> json,
  ) async {
    final file = await _roundFile(sessionId, roundId);
    await file.writeAsString(jsonEncode(json), flush: true);
  }

  String _goalOf(Map<String, dynamic> json) {
    final plan = json['taskPlan'];
    if (plan is Map<String, dynamic>) {
      final goal = plan['goal']?.toString() ?? '';
      if (goal.isNotEmpty) return goal;
    }
    return '';
  }

  String _summaryOf(Map<String, dynamic> json) {
    final content = (json['assistantContent'] ?? '').toString().trim();
    if (content.isEmpty) return '';
    final oneLine = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 120 ? '${oneLine.substring(0, 120)}…' : oneLine;
  }

  Iterable<String> _eventSnippets(Map<String, dynamic> json, String q) sync* {
    final events = json['events'] as List? ?? const [];
    for (final raw in events) {
      if (raw is! Map<String, dynamic>) continue;
      final pieces = [
        raw['toolName']?.toString() ?? '',
        raw['args'] is Map ? jsonEncode(raw['args']) : '',
        raw['message']?.toString() ?? '',
        raw['result']?.toString() ?? '',
        raw['fullResult']?.toString() ?? '',
      ];
      for (final p in pieces) {
        if (p.toLowerCase().contains(q)) {
          final compact = p.replaceAll(RegExp(r'\s+'), ' ').trim();
          yield compact.length > 200
              ? '${compact.substring(0, 200)}…'
              : compact;
          break;
        }
      }
    }
  }
}
