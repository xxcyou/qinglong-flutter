import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../models/agent_event.dart';
import '../models/agent_task_plan.dart';

/// 完整轮本地归档（正式版）。
///
/// 目录结构：
/// ```
/// <app>/ai_rounds/
///   <sessionId>/
///     manifest.json          # 会话索引/元数据（正式入口）
///     session.json           # 兼容旧版轻量信息
///     rounds/
///       <roundId>.json       # 每个完整轮的全部数据
/// ```
///
/// 设计原则：
/// - 每个会话一个目录，每个完整轮一个带 schemaVersion 的 JSON 文件。
/// - 运行中实时写入事件；中断/继续复用同一个 roundId。
/// - 所有写入都先写临时文件再原子 rename，避免中途崩溃留下半个 JSON。
/// - manifest 是 round 列表的唯一快速入口，listRounds 不需要扫全量文件。
/// - 有保留上限，超出的已结束轮次自动清掉最旧的，避免无限膨胀。
class RoundArchiveService {
  RoundArchiveService._();

  static final RoundArchiveService instance = RoundArchiveService._();

  static const dirName = 'ai_rounds';
  static const schemaVersion = 1;

  /// 每个会话最多保留的完整轮数量。
  static const maxRoundsPerSession = 200;

  /// 每个会话归档目录总字节上限（含 manifest/rounds）。
  static const maxBytesPerSession = 200 * 1024 * 1024;

  /// 每个 roundId 一个写锁，避免并发 appendEvent 读改写互相覆盖。
  final Map<String, Future<void>> _roundLocks = {};
  Future<void> _manifestLock = Future.value();

  String _safeSessionId(String sessionId) =>
      sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');

  Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/$dirName');
  }

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

  Future<File> _manifestFile(String sessionId) async {
    final dir = await _sessionDir(sessionId);
    return File('${dir.path}/manifest.json');
  }

  Future<File> _sessionAliasFile(String sessionId) async {
    final dir = await _sessionDir(sessionId);
    return File('${dir.path}/session.json');
  }

  /// 生成可读、带随机后缀的完整轮 ID。
  static String newRoundId([DateTime? now]) {
    final t = now ?? DateTime.now();
    final random = Random.secure();
    final suffix = List.generate(
      4,
      (_) => random.nextInt(36).toRadixString(36),
    ).join();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}_$suffix';
  }

  Future<void> _atomicWrite(File file, String content) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> _locked(String key, Future<void> Function() action) {
    final prev = _roundLocks[key] ?? Future.value();
    final done = prev.then((_) => action());
    _roundLocks[key] = done.catchError((_) {});
    return done;
  }

  Future<T> _withManifest<T>(
    String sessionId,
    Future<T> Function(Map<String, dynamic> manifest) action,
  ) async {
    final prev = _manifestLock;
    final completer = Completer<T>();
    _manifestLock = prev.then((_) async {
      try {
        final result = await action(await _loadManifest(sessionId));
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }).catchError((_) {});
    return completer.future;
  }

  Future<Map<String, dynamic>> _loadManifest(String sessionId) async {
    final file = await _manifestFile(sessionId);
    if (!await file.exists()) {
      return {
        'schemaVersion': schemaVersion,
        'sessionId': sessionId,
        'title': '',
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
        'messageCount': 0,
        'rounds': <Map<String, dynamic>>[],
      };
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        final rounds = decoded['rounds'];
        return {
          ...decoded,
          'rounds': rounds is List
              ? rounds.whereType<Map<String, dynamic>>().toList()
              : <Map<String, dynamic>>[],
        };
      }
    } catch (_) {}
    return {
      'schemaVersion': schemaVersion,
      'sessionId': sessionId,
      'title': '',
      'createdAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
      'messageCount': 0,
      'rounds': <Map<String, dynamic>>[],
    };
  }

  Future<void> _saveManifest(
      String sessionId, Map<String, dynamic> manifest) async {
    manifest['schemaVersion'] = schemaVersion;
    manifest['updatedAt'] = DateTime.now().toIso8601String();
    final dir = await _sessionDir(sessionId);
    await dir.create(recursive: true);
    await _atomicWrite(await _manifestFile(sessionId), jsonEncode(manifest));
    final alias = await _sessionAliasFile(sessionId);
    await _atomicWrite(
      alias,
      jsonEncode({
        'sessionId': sessionId,
        'title': manifest['title']?.toString() ?? '',
        'createdAt': manifest['createdAt']?.toString() ?? '',
        'updatedAt': DateTime.now().toIso8601String(),
        'messageCount': manifest['messageCount'] ?? 0,
      }),
    );
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
        await _atomicWrite(
          file,
          jsonEncode({
            'schemaVersion': schemaVersion,
            'id': roundId,
            'sessionId': sessionId,
            'startedAt': now,
            'updatedAt': now,
            'endedAt': '',
            'outcome': '',
            'status': 'running',
            'userInputs': [if (userInput.isNotEmpty) userInput],
            'assistantContent': '',
            'summary': '',
            'events': <Object>[],
            'taskPlan': const <String, dynamic>{},
            'turns': 0,
            'usage': const <String, dynamic>{},
            'canvases': <Object>[],
            if (resumeFrom != null) 'resumeFrom': resumeFrom,
          }),
        );
      } else if (userInput.isNotEmpty) {
        await _appendUserInputUnlocked(sessionId, roundId, userInput);
      }

      final meta = await _roundMetaUnlocked(sessionId, roundId);
      await _withManifest(sessionId, (manifest) async {
        final rounds = (manifest['rounds'] as List<Map<String, dynamic>>)
            .where((r) => r['id'] != roundId)
            .toList()
          ..insert(0, meta);
        manifest['rounds'] = rounds;
        manifest['messageCount'] =
            (manifest['messageCount'] as num?)?.toInt() ?? 0;
        await _saveManifest(sessionId, manifest);
        await _cleanupIfNeeded(sessionId, manifest);
      });
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
      await _touchManifest(sessionId, roundId);
    });
  }

  Future<void> _appendUserInputUnlocked(
    String sessionId,
    String roundId,
    String text,
  ) async {
    final json = await _readRound(sessionId, roundId);
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
    await _atomicWrite(await _roundFile(sessionId, roundId), jsonEncode(json));
  }

  Future<void> appendEvent(
    String sessionId,
    String roundId,
    AgentEvent event,
  ) async {
    await _locked('$sessionId/$roundId', () async {
      final json = await _readRound(sessionId, roundId);
      if (json == null) return;
      final events = (json['events'] as List? ?? <Object>[]).toList()
        ..add(event.toJson());
      json['events'] = events;
      json['updatedAt'] = DateTime.now().toIso8601String();
      await _atomicWrite(
          await _roundFile(sessionId, roundId), jsonEncode(json));
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
      final json = await _readRound(sessionId, roundId);
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
      final now = DateTime.now();
      json['endedAt'] = endedAt ?? now.toIso8601String();
      json['updatedAt'] = now.toIso8601String();
      json['status'] = outcome.isNotEmpty ? outcome : 'running';
      json['summary'] = _summaryOf(json);
      await _atomicWrite(
          await _roundFile(sessionId, roundId), jsonEncode(json));

      final meta = _roundMetaFromJson(json);
      await _withManifest(sessionId, (manifest) async {
        final rounds = (manifest['rounds'] as List<Map<String, dynamic>>)
            .where((r) => r['id'] != roundId)
            .toList()
          ..insert(0, meta);
        manifest['rounds'] = rounds;
        await _saveManifest(sessionId, manifest);
        await _cleanupIfNeeded(sessionId, manifest);
      });
    });
  }

  /// 更新主会话索引（兼容旧调用名）。
  Future<void> writeSessionIndex(
    String sessionId, {
    String title = '',
    DateTime? endedAt,
    int? messageCount,
  }) async {
    await _withManifest(sessionId, (manifest) async {
      if (title.isNotEmpty) manifest['title'] = title;
      if (messageCount != null) manifest['messageCount'] = messageCount;
      if (endedAt != null) manifest['updatedAt'] = endedAt.toIso8601String();
      await _saveManifest(sessionId, manifest);
    });
  }

  Future<List<Map<String, dynamic>>> listRounds(String sessionId) async {
    final manifest = await _loadManifest(sessionId);
    final rounds =
        manifest['rounds'] as List<Map<String, dynamic>>? ?? const [];
    if (rounds.isNotEmpty) return rounds;
    return _scanRoundsFallback(sessionId);
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
          'endedAt': json['endedAt']?.toString() ?? '',
          'outcome': json['outcome']?.toString() ?? '',
          'status': json['status']?.toString() ?? '',
          'goal': _goalOf(json),
          'turns': (json['turns'] as num?)?.toInt() ?? 0,
          'summary': _summaryOf(json),
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
    String sections = 'default',
  }) async {
    final json = await _readRound(sessionId, roundId);
    if (json == null) {
      return '未找到完整轮：$roundId（该会话目录里没有这个文件）。';
    }
    if (full) {
      final raw = jsonEncode(json);
      if (raw.length > 200000) return '${raw.substring(0, 200000)}…（超长截断）';
      return raw;
    }
    final wanted = sections
        .split(',')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toSet();
    final hasAll = wanted.contains('all') || wanted.isEmpty;
    bool want(String key) => hasAll || wanted.contains(key);

    final buffer = StringBuffer('## 完整轮 ${json['id']}\n');
    if (want('meta')) {
      buffer.writeln('时间：${json['startedAt']}');
      buffer.writeln('结束：${json['endedAt'] ?? ''}');
      buffer.writeln('状态：${json['status'] ?? ''} / ${json['outcome'] ?? ''}');
      buffer.writeln('轮数：${json['turns'] ?? 0}');
      final goal = _goalOf(json);
      if (goal.isNotEmpty) buffer.writeln('目标：$goal');
    }
    if (want('user') || hasAll) {
      final inputs = json['userInputs'] as List? ?? const [];
      if (inputs.isNotEmpty) {
        buffer.writeln('--- 用户输入 ---');
        for (final i in inputs) {
          buffer.writeln('· $i');
        }
      }
    }
    if (want('assistant') || hasAll) {
      final content = (json['assistantContent'] ?? '').toString().trim();
      if (content.isNotEmpty) {
        buffer.writeln('--- AI 最终回复 ---');
        buffer.writeln(content);
      }
    }
    if (want('task') || hasAll) {
      final plan = json['taskPlan'];
      if (plan is Map<String, dynamic> && plan.isNotEmpty) {
        final planText = AgentTaskPlan.fromJson(plan).promptLines();
        if (planText.isNotEmpty) {
          buffer.writeln('--- 任务清单 ---');
          buffer.writeln(planText);
        }
      }
    }
    if (want('events') || hasAll) {
      final events = json['events'] as List? ?? const [];
      buffer.writeln('--- 执行过程（${events.length} 条事件摘要）---');
      final parsed = events.whereType<Map<String, dynamic>>().toList();
      final tail =
          parsed.length <= 12 ? parsed : parsed.sublist(parsed.length - 12);
      for (final e in tail) {
        final kind = e['kind']?.toString() ?? '';
        final name = e['toolName']?.toString() ?? '';
        final msg = e['message']?.toString() ?? '';
        final res =
            e['result']?.toString() ?? e['fullResult']?.toString() ?? '';
        buffer.writeln(
          '· $kind${name.isEmpty ? '' : ' [$name]'}'
          '${msg.isEmpty ? '' : ' $msg'}'
          '${res.isEmpty ? '' : '\n  ${res.length > 300 ? '${res.substring(0, 300)}…' : res}'}',
        );
      }
    }
    if (want('usage') && !hasAll) {
      final usage = json['usage'];
      if (usage is Map<String, dynamic> && usage.isNotEmpty) {
        buffer.writeln('--- 用量 ---');
        buffer.writeln(jsonEncode(usage));
      }
    }
    return buffer.toString().trimRight();
  }

  Future<Map<String, dynamic>?> _readRound(
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

  Future<Map<String, dynamic>> _roundMetaUnlocked(
    String sessionId,
    String roundId,
  ) async {
    final json = await _readRound(sessionId, roundId);
    return _roundMetaFromJson(json ?? const {});
  }

  Map<String, dynamic> _roundMetaFromJson(Map<String, dynamic> json) {
    final fileSize = json['events'] is List ? jsonEncode(json).length : 0;
    return {
      'id': json['id']?.toString() ?? '',
      'startedAt': json['startedAt']?.toString() ?? '',
      'endedAt': json['endedAt']?.toString() ?? '',
      'outcome': json['outcome']?.toString() ?? '',
      'status': json['status']?.toString() ?? 'running',
      'summary': _summaryOf(json),
      'goal': _goalOf(json),
      'turns': (json['turns'] as num?)?.toInt() ?? 0,
      'fileSize': fileSize,
    };
  }

  Future<void> _touchManifest(String sessionId, String roundId) async {
    await _withManifest(sessionId, (manifest) async {
      final rounds = manifest['rounds'] as List<Map<String, dynamic>>? ?? [];
      final i = rounds.indexWhere((r) => r['id'] == roundId);
      if (i >= 0) {
        final meta = await _roundMetaUnlocked(sessionId, roundId);
        rounds[i] = meta;
        manifest['rounds'] = rounds;
        await _saveManifest(sessionId, manifest);
      }
    });
  }

  Future<void> _cleanupIfNeeded(
    String sessionId,
    Map<String, dynamic> manifest,
  ) async {
    final rounds = manifest['rounds'] as List<Map<String, dynamic>>? ?? [];
    if (rounds.length <= maxRoundsPerSession) return;

    final roundsDir = await _roundsDir(sessionId);
    if (!await roundsDir.exists()) return;
    // 只清“已结束”的最旧轮；running 永远保留。
    var removable = rounds.where((r) {
      final status = r['status']?.toString() ?? '';
      return status != 'running' &&
          status != 'awaitingInput' &&
          status != 'awaitingConfirm';
    }).toList()
      ..sort((a, b) => (a['startedAt'] as String? ?? '')
          .compareTo(b['startedAt'] as String? ?? ''));
    const keep = maxRoundsPerSession;
    final toRemove = removable.take(
      removable.length > keep ? removable.length - keep : 0,
    );
    for (final r in toRemove) {
      final id = r['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      try {
        final f = File('${roundsDir.path}/$id.json');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    manifest['rounds'] =
        rounds.where((r) => !toRemove.any((x) => x['id'] == r['id'])).toList();
    await _saveManifest(sessionId, manifest);
  }

  Future<List<Map<String, dynamic>>> _scanRoundsFallback(
      String sessionId) async {
    final dir = await _roundsDir(sessionId);
    if (!await dir.exists()) return const [];
    final out = <Map<String, dynamic>>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await f.readAsString());
        if (json is! Map<String, dynamic>) continue;
        out.add(_roundMetaFromJson(json));
      } catch (_) {}
    }
    out.sort((a, b) => (b['startedAt'] as String? ?? '')
        .compareTo(a['startedAt'] as String? ?? ''));
    return out;
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
