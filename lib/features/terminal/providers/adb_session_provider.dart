import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_adb/adb_connection.dart';
import 'package:flutter_adb/adb_crypto.dart';
import 'package:flutter_adb/adb_pairing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ADB 连接方式（网络 ADB，仿 SSH 会话管理）。
class AdbSession {
  const AdbSession({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.status,
    this.pairingPort,
    this.pairingCode,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String status; // disconnected / connecting / connected / error
  final int? pairingPort;
  final String? pairingCode;

  bool get isConnected => status == 'connected';

  AdbSession copyWith({String? status}) => AdbSession(
        id: id,
        name: name,
        host: host,
        port: port,
        status: status ?? this.status,
        pairingPort: pairingPort,
        pairingCode: pairingCode,
      );
}

class AdbSessionDraft {
  const AdbSessionDraft({
    required this.name,
    required this.host,
    required this.port,
    this.pairingPort,
    this.pairingCode,
  });

  final String name;
  final String host;
  final int port;
  final int? pairingPort;
  final String? pairingCode;
}

/// ADB 会话注册表：保存/加载/连接/断开/删除。
class AdbSessionManager {
  AdbSessionManager._();

  static final AdbSessionManager instance = AdbSessionManager._();

  static const _prefsKey = 'adb_saved_sessions';
  static const _cryptoKey = 'adb_crypto_key';

  final Map<String, AdbConnection> _clients = {};
  final Map<String, AdbSession> _sessions = {};
  final Map<String, AdbSessionDraft> _drafts = {};
  final List<void Function()> _listeners = [];
  AdbCrypto? _crypto;
  bool _loaded = false;

  List<AdbSession> get sessions =>
      List.unmodifiable(_sessions.values.toList());

  AdbConnection? connectionOf(String id) => _clients[id];

  AdbSessionDraft? draftOf(String id) => _drafts[id];

  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  Future<AdbCrypto> crypto() async {
    await loadSaved();
    if (_crypto != null) return _crypto!;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cryptoKey);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw);
        if (map is Map<String, dynamic>) {
          _crypto = AdbCrypto(
            keyPair: AdbCrypto.keyPairFromStorageMap(map),
            adbKeyName: 'qinglong_flutter@dsh',
          );
          return _crypto!;
        }
      }
    } catch (_) {}
    _crypto = AdbCrypto(adbKeyName: 'qinglong_flutter@dsh');
    await _persistCrypto();
    return _crypto!;
  }

  Future<void> _persistCrypto() async {
    final c = _crypto;
    if (c == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cryptoKey, jsonEncode(c.exportKeyPairForStorage()));
    } catch (_) {}
  }

  Future<void> loadSaved() async {
    if (_loaded) return;
    _loaded = true;
    await crypto();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      final list = jsonDecode(raw ?? '[]') as List? ?? const [];
      final seenEndpoint = <String>{};
      for (final item in list) {
        if (item is! Map) continue;
        final id = item['id']?.toString() ?? '';
        final name = item['name']?.toString() ?? '';
        final host = item['host']?.toString() ?? '';
        final port = (item['port'] as num?)?.toInt() ?? 5555;
        final pairingPort = (item['pairingPort'] as num?)?.toInt();
        final pairingCode = item['pairingCode']?.toString();
        if (id.isEmpty || host.isEmpty) continue;
        // 同一 主机:端口 只保留一条，清理之前 AI 重复添加留下的脏数据。
        if (!seenEndpoint.add('$host:$port')) continue;
        _sessions[id] = AdbSession(
          id: id,
          name: name,
          host: host,
          port: port,
          status: 'disconnected',
          pairingPort: pairingPort,
          pairingCode: pairingCode,
        );
        _drafts[id] = AdbSessionDraft(
          name: name,
          host: host,
          port: port,
          pairingPort: pairingPort,
          pairingCode: pairingCode,
        );
      }
      _notify();
    } catch (_) {}
  }

  String _newId() =>
      'adb_${DateTime.now().millisecondsSinceEpoch}_${_sessions.length}';

  /// 同一 主机:端口 只保留一条，避免 AI/UI 重复添加。
  String? _findByEndpoint(String host, int port) {
    for (final s in _sessions.values) {
      if (s.host == host && s.port == port) return s.id;
    }
    return null;
  }

  Future<String> save(AdbSessionDraft draft, {String? id}) async {
    await loadSaved();
    final targetId = id ?? _findByEndpoint(draft.host, draft.port) ?? _newId();
    _sessions[targetId] = AdbSession(
      id: targetId,
      name: draft.name,
      host: draft.host,
      port: draft.port,
      status: _sessions[targetId]?.status ?? 'disconnected',
      pairingPort: draft.pairingPort,
      pairingCode: draft.pairingCode,
    );
    _drafts[targetId] = draft;
    await _persist();
    _notify();
    return targetId;
  }

  Future<AdbSession> connect(AdbSessionDraft draft, {String? id}) async {
    await loadSaved();
    final targetId = id ?? await save(draft);
    final alive = _clients[targetId];
    if (alive != null && alive.connected) {
      return _sessions[targetId]!;
    }
    _drafts[targetId] = draft;
    _sessions[targetId] = AdbSession(
      id: targetId,
      name: draft.name,
      host: draft.host,
      port: draft.port,
      status: 'connecting',
      pairingPort: draft.pairingPort,
      pairingCode: draft.pairingCode,
    );
    _notify();

    try {
      final c = await crypto();
      // Android 11+ 无线调试需要先配对。
      if (draft.pairingPort != null &&
          draft.pairingCode != null &&
          draft.pairingCode!.isNotEmpty) {
        final paired = await AdbPairing.pair(
          draft.host,
          draft.pairingPort!,
          draft.pairingCode!,
          c,
        );
        if (!paired) {
          throw StateError('ADB 配对失败，请检查配对端口和 6 位配对码');
        }
      }
      final connection = AdbConnection(draft.host, draft.port, c);
      final ok = await connection.connect().timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              connection.disconnect();
              throw StateError('ADB 连接超时，请检查 IP/端口/无线调试是否开启');
            },
          );
      if (!ok) throw StateError('ADB 连接失败，请确认设备已开启无线调试');
      _clients[targetId] = connection;
      _sessions[targetId] = AdbSession(
        id: targetId,
        name: draft.name,
        host: draft.host,
        port: draft.port,
        status: 'connected',
        pairingPort: draft.pairingPort,
        pairingCode: draft.pairingCode,
      );
      _notify();
      return _sessions[targetId]!;
    } catch (e) {
      _clients.remove(targetId);
      _sessions[targetId] = AdbSession(
        id: targetId,
        name: draft.name,
        host: draft.host,
        port: draft.port,
        status: 'error: $e',
        pairingPort: draft.pairingPort,
        pairingCode: draft.pairingCode,
      );
      _notify();
      return _sessions[targetId]!;
    }
  }

  Future<void> disconnect(String id) async {
    final connection = _clients.remove(id);
    if (connection != null) {
      try {
        await connection.disconnect();
      } catch (_) {}
    }
    final s = _sessions[id];
    if (s != null) {
      _sessions[id] = s.copyWith(status: 'disconnected');
      _notify();
    }
  }

  Future<void> remove(String id) async {
    await disconnect(id);
    _sessions.remove(id);
    _drafts.remove(id);
    await _persist();
    _notify();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode([
        for (final s in _sessions.values)
          {
            'id': s.id,
            'name': s.name,
            'host': s.host,
            'port': s.port,
            if (s.pairingPort != null) 'pairingPort': s.pairingPort,
            if (s.pairingCode != null) 'pairingCode': s.pairingCode,
          },
      ]),
    );
  }

  /// 执行单条 ADB shell 命令，返回原始输出字符串。
  ///
  /// 用交互式 shell + 随机结束标记收尾，避免一次性 `shell:cmd` 在
  /// 订阅监听前就关闭导致输出/结束事件丢失（表现为“卡住/连不上”）。
  Future<String> execute(String id, String command) async {
    final connection = _clients[id];
    if (connection == null) throw StateError('ADB 未连接：$id');
    if (!connection.connected) throw StateError('ADB 已断开：$id');
    final stream = await connection.open('shell:');
    final completer = Completer<String>();
    final bytes = BytesBuilder();
    final token =
        '__ADB_DONE_${DateTime.now().microsecondsSinceEpoch}_${id.hashCode}__';
    late final StreamSubscription<Uint8List> sub;
    sub = stream.onPayload.listen(
      (p) {
        bytes.add(p);
        final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
        bytes.add(utf8.encode(text));
        final idx = text.indexOf(token);
        if (idx >= 0) {
          final result = text.substring(0, idx);
          if (!completer.isCompleted) completer.complete(result);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(
              utf8.decode(bytes.takeBytes(), allowMalformed: true));
        }
      },
      onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      },
    );
    try {
      await stream.writeString('$command; echo $token\n');
      return await completer.future.timeout(const Duration(seconds: 60));
    } finally {
      await sub.cancel();
      try {
        await stream.sendClose();
      } catch (_) {}
    }
  }

  /// 读取 ADB 远端文件为原始字节（base64 中转）。
  Future<Uint8List?> runBase64Read(String id, String path) async {
    final quoted = path.replaceAll("'", "'\\''");
    final out = await execute(id, 'base64 \'$quoted\'');
    final normalized = out.replaceAll(RegExp(r'\s'), '');
    if (normalized.isEmpty) return null;
    try {
      return base64Decode(normalized);
    } catch (e) {
      throw StateError('ADB 读取二进制失败：$e');
    }
  }
}

class AdbSessionState {
  const AdbSessionState({this.sessions = const []});

  final List<AdbSession> sessions;

  AdbSessionState copyWith({List<AdbSession>? sessions}) =>
      AdbSessionState(sessions: sessions ?? this.sessions);
}

class AdbSessionNotifier extends Notifier<AdbSessionState> {
  @override
  AdbSessionState build() {
    AdbSessionManager.instance.addListener(_onChange);
    ref.onDispose(() => AdbSessionManager.instance.removeListener(_onChange));
    Future.microtask(AdbSessionManager.instance.loadSaved);
    return AdbSessionState(
      sessions: AdbSessionManager.instance.sessions,
    );
  }

  void _onChange() {
    state = AdbSessionState(sessions: AdbSessionManager.instance.sessions);
  }

  Future<AdbSession> connect(AdbSessionDraft draft, {String? id}) =>
      AdbSessionManager.instance.connect(draft, id: id);

  Future<String> save(AdbSessionDraft draft, {String? id}) =>
      AdbSessionManager.instance.save(draft, id: id);

  Future<void> disconnect(String id) =>
      AdbSessionManager.instance.disconnect(id);

  Future<void> remove(String id) => AdbSessionManager.instance.remove(id);
}

final adbSessionsProvider =
    NotifierProvider<AdbSessionNotifier, AdbSessionState>(
  AdbSessionNotifier.new,
);
