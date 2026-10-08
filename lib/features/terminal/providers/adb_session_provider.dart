import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_adb/adb_connection.dart';
import 'package:flutter_adb/adb_crypto.dart';
import 'package:flutter_adb/adb_pairing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'qinglong_adb_crypto.dart';

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
          _crypto = QinglongAdbCrypto(
            keyPair: AdbCrypto.keyPairFromStorageMap(map),
            adbKeyName: 'qinglong_flutter@dsh',
          );
          return _crypto!;
        }
      }
    } catch (_) {}
    _crypto = QinglongAdbCrypto(adbKeyName: 'qinglong_flutter@dsh');
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
    final target = host.trim();
    for (final s in _sessions.values) {
      if (s.host.trim() == target && s.port == port) return s.id;
    }
    return null;
  }

  /// 同一台手机重新开无线调试时端口会变，AI 很容易因此重复建设备。
  /// 精确 主机:端口 找不到时，按主机复用已有会话并更新端口。
  String? _findByHost(String host) {
    final target = host.trim();
    if (target.isEmpty) return null;
    for (final s in _sessions.values) {
      if (s.host.trim() == target) return s.id;
    }
    return null;
  }

  Future<String> save(AdbSessionDraft draft, {String? id}) async {
    await loadSaved();
    final host = draft.host.trim();
    final name = draft.name.trim().isEmpty ? host : draft.name.trim();
    final normalized = AdbSessionDraft(
      name: name,
      host: host,
      port: draft.port,
      pairingPort: draft.pairingPort,
      pairingCode: draft.pairingCode,
    );
    final targetId = id ??
        _findByEndpoint(host, draft.port) ??
        _findByHost(host) ??
        _newId();
    _sessions[targetId] = AdbSession(
      id: targetId,
      name: name,
      host: host,
      port: draft.port,
      status: _sessions[targetId]?.status ?? 'disconnected',
      pairingPort: draft.pairingPort,
      pairingCode: draft.pairingCode,
    );
    _drafts[targetId] = normalized;
    await _persist();
    _notify();
    return targetId;
  }

  Future<AdbSession> connect(AdbSessionDraft draft, {String? id}) async {
    await loadSaved();
    final host = draft.host.trim();
    final name = draft.name.trim().isEmpty ? host : draft.name.trim();
    final normalized = AdbSessionDraft(
      name: name,
      host: host,
      port: draft.port,
      pairingPort: draft.pairingPort,
      pairingCode: draft.pairingCode,
    );
    final targetId = id ?? await save(normalized);
    final alive = _clients[targetId];
    if (alive != null && alive.connected) {
      return _sessions[targetId]!;
    }
    _drafts[targetId] = normalized;
    _sessions[targetId] = AdbSession(
      id: targetId,
      name: name,
      host: host,
      port: draft.port,
      status: 'connecting',
      pairingPort: draft.pairingPort,
      pairingCode: draft.pairingCode,
    );
    _notify();

    try {
      final c = await crypto();
      // Android 11+ 无线调试需要先配对。
      if (normalized.pairingPort != null &&
          normalized.pairingCode != null &&
          normalized.pairingCode!.isNotEmpty) {
        final paired = await AdbPairing.pair(
          normalized.host,
          normalized.pairingPort!,
          normalized.pairingCode!,
          c,
        );
        if (!paired) {
          throw StateError('ADB 配对失败，请检查配对端口和 6 位配对码');
        }
      }
      final connection = AdbConnection(normalized.host, normalized.port, c);
      // flutter_adb 1.0.0 的 connect() 有广播事件竞态：设备响应很快时，
      // CNXN 可能在 connect() 自己订阅 _adbConnectedController 之前就到达，
      // 导致它返回的 future 永远不完成——表现为每次重连都卡到 15 秒超时。
      // 这里先挂 onConnectionChanged，再发起 connect()，两者竞速。
      final adbReady = connection.onConnectionChanged.where((v) => v).first;
      final connectFuture = connection.connect();
      unawaited(connectFuture.catchError((Object _) => false));
      final ok = await Future.any<bool>([
        adbReady.then((_) => true),
        connectFuture,
      ]).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          connection.disconnect();
          throw StateError(
            'ADB 连接超时：请解锁手机，若弹出“允许调试”就点允许/始终允许；'
            '已连过可回 ADB 设备管理点重新连接。',
          );
        },
      );
      if (!ok) throw StateError('ADB 连接失败，请确认设备已开启无线调试');
      _clients[targetId] = connection;
      _sessions[targetId] = AdbSession(
        id: targetId,
        name: name,
        host: host,
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
        name: name,
        host: host,
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
  /// 关键点：必须用非交互式 raw shell（`shell,raw:`）把命令直接写进
  /// service 参数，而不是先开 `shell:` 再 writeString。交互式 shell 会回显
  /// 命令，结束标记先出现在回显里，execute 会把“提示符+命令本身”当结果
  /// 返回——所以之前 ls 解析不到文件、cat 打开文件显示 `matisse:/ $ ...`。
  Future<String> execute(String id, String command) async {
    final connection = _clients[id];
    if (connection == null) throw StateError('ADB 未连接：$id');
    if (!connection.connected) throw StateError('ADB 已断开：$id');
    final token =
        '__ADB_DONE_${DateTime.now().microsecondsSinceEpoch}_${id.hashCode}__';
    final stream = await connection.open('shell,raw:$command; echo $token');

    final completer = Completer<String>();
    final acc = StringBuffer();
    var tail = '';
    late final StreamSubscription<String> sub;
    sub = utf8.decoder.bind(stream.onPayload).listen(
      (text) {
        acc.write(text);
        tail += text;
        // 只保留尾部一小段用于跨 chunk 搜 token，避免大输出 O(n²)。
        if (tail.length > 4096) {
          tail = tail.substring(tail.length - 4096);
        }
        final idx = tail.indexOf(token);
        if (idx >= 0 && !completer.isCompleted) {
          final cut = acc.length - (tail.length - idx);
          if (cut < 0) {
            completer.complete(acc.toString());
          } else {
            completer.complete(acc.toString().substring(0, cut));
          }
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(acc.toString());
      },
      onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      },
    );
    try {
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
