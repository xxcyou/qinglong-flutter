import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/secure_storage.dart';

/// SSH 连接方式。
enum SshAuthType { password, key }

class SshSession {
  const SshSession({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authType,
    required this.status,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final SshAuthType authType;
  final String status; // disconnected / connecting / connected / error

  bool get isConnected => status == 'connected';

  SshSession copyWith({String? status}) => SshSession(
        id: id,
        name: name,
        host: host,
        port: port,
        username: username,
        authType: authType,
        status: status ?? this.status,
      );
}

/// 连接参数，包含秘密（密码/私钥），只在内存和 SecureStorage 里流转。
class SshSessionDraft {
  const SshSessionDraft({
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.authType,
    this.password,
    this.privateKey,
    this.keyPassphrase,
  });

  final String name;
  final String host;
  final int port;
  final String username;
  final SshAuthType authType;
  final String? password;
  final String? privateKey;
  final String? keyPassphrase;
}

/// SSH 会话注册表：负责保存/加载/连接/断开/删除。
/// 使用纯 Dart 的 dartssh2，原生支持 OpenSSH ed25519 / RSA / EC 私钥。
class SshSessionManager {
  SshSessionManager._();

  static final SshSessionManager instance = SshSessionManager._();

  static const _prefsKey = 'ssh_saved_sessions';

  final Map<String, SSHClient> _clients = {};
  final Map<String, SshSession> _sessions = {};
  final Map<String, SshSessionDraft> _drafts = {};
  final List<void Function()> _listeners = [];
  bool _loaded = false;

  List<SshSession> get sessions => List.unmodifiable(_sessions.values.toList());

  SSHClient? clientOf(String id) => _clients[id];

  SshSessionDraft? draftOf(String id) => _drafts[id];

  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// App 启动/首次使用时加载已保存的 SSH 会话。
  Future<void> loadSaved() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      final list = jsonDecode(raw ?? '[]') as List? ?? const [];
      final seenKeys = <String>{};
      for (final item in list) {
        if (item is! Map) continue;
        final id = item['id']?.toString() ?? '';
        final authType =
            item['authType'] == 'key' ? SshAuthType.key : SshAuthType.password;
        final name = item['name']?.toString() ?? '';
        final host = item['host']?.toString() ?? '';
        final username = item['username']?.toString() ?? '';
        final port = (item['port'] as num?)?.toInt() ?? 22;
        if (id.isEmpty || host.isEmpty || username.isEmpty) continue;
        final key = '$host:$port:$username';
        // 历史遗留脏数据：同一主机/端口/用户名只保留一条，其余跳过并清凭据。
        if (!seenKeys.add(key)) {
          try {
            await SecureStorage.deleteSshSecret(id);
          } catch (_) {}
          continue;
        }
        final secret = await SecureStorage.readSshSecret(id);
        if (secret == null) continue;
        _sessions[id] = SshSession(
          id: id,
          name: name,
          host: host,
          port: port,
          username: username,
          authType: authType,
          status: 'disconnected',
        );
        _drafts[id] = SshSessionDraft(
          name: name,
          host: host,
          port: port,
          username: username,
          authType: authType,
          password: secret['password'],
          privateKey: secret['privateKey'],
          keyPassphrase: secret['passphrase'],
        );
      }
      _notify();
    } catch (_) {}
  }

  String _newId() =>
      'ssh_${DateTime.now().millisecondsSinceEpoch}_${_sessions.length}';

  String _keyOf(SshSessionDraft draft) =>
      '${draft.host}:${draft.port}:${draft.username}';

  /// 找同主机/端口/用户名的已保存会话。找到就复用，避免 AI 重复创建 SSH。
  String? _existingIdFor(SshSessionDraft draft, {String? id}) {
    if (id != null && _sessions.containsKey(id)) return id;
    final key = _keyOf(draft);
    for (final entry in _sessions.entries) {
      final d = _drafts[entry.key];
      if (d != null && _keyOf(d) == key) return entry.key;
    }
    return null;
  }

  /// 标记某个会话已断开并从活动连接表移除（同一 client 才移除）。
  void _markDisconnected(String id, [String reason = 'disconnected']) {
    final s = _sessions[id];
    if (s == null) return;
    _sessions[id] = s.copyWith(status: reason);
    _notify();
  }

  /// 保存/更新一个会话（只保存配置，不连接）。
  Future<String> save(SshSessionDraft draft, {String? id}) async {
    await loadSaved();
    final targetId = id ?? _newId();
    _sessions[targetId] = SshSession(
      id: targetId,
      name: draft.name,
      host: draft.host,
      port: draft.port,
      username: draft.username,
      authType: draft.authType,
      status: _sessions[targetId]?.status ?? 'disconnected',
    );
    _drafts[targetId] = draft;
    await _persist();
    await SecureStorage.saveSshSecret(
      targetId,
      {
        if (draft.password != null) 'password': draft.password!,
        if (draft.privateKey != null) 'privateKey': draft.privateKey!,
        if (draft.keyPassphrase != null) 'passphrase': draft.keyPassphrase!,
      },
    );
    _notify();
    return targetId;
  }

  /// 连接（支持新建后自动保存，或连接已保存会话）。
  Future<SshSession> connect(
    SshSessionDraft draft, {
    String? id,
  }) async {
    await loadSaved();
    // 同一个主机/端口/用户名复用同一条会话，不重复创建。
    final existingId = _existingIdFor(draft, id: id);
    final targetId = existingId ?? await save(draft);
    final alive = _clients[targetId];
    if (alive != null && !alive.isClosed) {
      // 已经连着，直接返回，避免 AI 误判“断开”又开一条。
      final current = _sessions[targetId];
      if (current != null) return current;
    }
    if (alive != null && alive.isClosed) {
      _clients.remove(targetId);
    }
    _drafts[targetId] = draft;
    _sessions[targetId] = SshSession(
      id: targetId,
      name: draft.name,
      host: draft.host,
      port: draft.port,
      username: draft.username,
      authType: draft.authType,
      status: 'connecting',
    );
    _notify();

    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(draft.host, draft.port);
      if (draft.authType == SshAuthType.password) {
        client = SSHClient(
          socket,
          username: draft.username,
          onPasswordRequest: () => draft.password ?? '',
          authTimeout: const Duration(seconds: 15),
        );
      } else {
        final key = SSHKeyPair.fromPem(
          draft.privateKey ?? '',
          draft.keyPassphrase,
        );
        client = SSHClient(
          socket,
          username: draft.username,
          identities: key,
          authTimeout: const Duration(seconds: 15),
        );
      }
      await client.authenticated;
      _clients[targetId] = client;
      _sessions[targetId] = SshSession(
        id: targetId,
        name: draft.name,
        host: draft.host,
        port: draft.port,
        username: draft.username,
        authType: draft.authType,
        status: 'connected',
      );
      _notify();
      // 意外断链（网络掉线/服务器踢掉/NAT 超时）时自动把状态改回 disconnected，
      // 这样 AI 下次会复用同一条会话重连，而不是又创建一条新的。
      unawaited(client.done.then<void>((_) {
        if (_clients[targetId] == client) {
          _clients.remove(targetId);
          _markDisconnected(targetId);
        }
      }, onError: (Object e, StackTrace st) {
        if (_clients[targetId] == client) {
          _clients.remove(targetId);
          _markDisconnected(targetId, 'error: 连接断开: $e');
        }
      }));
      return _sessions[targetId]!;
    } catch (e) {
      client?.close();
      _sessions[targetId] = SshSession(
        id: targetId,
        name: draft.name,
        host: draft.host,
        port: draft.port,
        username: draft.username,
        authType: draft.authType,
        status: 'error: $e',
      );
      _notify();
      return _sessions[targetId]!;
    }
  }

  /// 断开连接但保留已保存的会话，下次可再连接。
  Future<void> disconnect(String id) async {
    final client = _clients.remove(id);
    if (client != null) {
      try {
        client.close();
        await client.done.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    final s = _sessions[id];
    if (s != null) {
      _sessions[id] = s.copyWith(status: 'disconnected');
      _notify();
    }
  }

  /// 彻底删除已保存会话并断开连接。
  Future<void> remove(String id) async {
    await disconnect(id);
    _sessions.remove(id);
    _drafts.remove(id);
    try {
      await _persist();
      await SecureStorage.deleteSshSecret(id);
    } catch (_) {}
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
            'username': s.username,
            'authType': s.authType.name,
          },
      ]),
    );
  }

  /// 给 AI/UI 调用的同步执行通道。
  Future<String> execute(String id, String command) async {
    final client = _clients[id];
    if (client == null) throw StateError('SSH 未连接：$id');
    if (client.isClosed) {
      _clients.remove(id);
      _markDisconnected(id, 'error: 连接已断开');
      throw StateError('SSH 已断开：$id，请用 ssh_connect 重新连接');
    }
    final session = await client.execute(command);
    final out = await utf8.decoder.bind(session.stdout).join();
    await session.done;
    return out;
  }
}

class SshSessionState {
  const SshSessionState({this.sessions = const []});

  final List<SshSession> sessions;

  SshSessionState copyWith({List<SshSession>? sessions}) =>
      SshSessionState(sessions: sessions ?? this.sessions);
}

class SshSessionNotifier extends Notifier<SshSessionState> {
  @override
  SshSessionState build() {
    SshSessionManager.instance.addListener(_onChange);
    ref.onDispose(() => SshSessionManager.instance.removeListener(_onChange));
    Future.microtask(SshSessionManager.instance.loadSaved);
    return SshSessionState(
      sessions: SshSessionManager.instance.sessions,
    );
  }

  void _onChange() {
    state = SshSessionState(sessions: SshSessionManager.instance.sessions);
  }

  Future<SshSession> connect(SshSessionDraft draft, {String? id}) =>
      SshSessionManager.instance.connect(draft, id: id);

  Future<String> save(SshSessionDraft draft, {String? id}) =>
      SshSessionManager.instance.save(draft, id: id);

  Future<void> disconnect(String id) =>
      SshSessionManager.instance.disconnect(id);

  Future<void> remove(String id) => SshSessionManager.instance.remove(id);
}

final sshSessionsProvider =
    NotifierProvider<SshSessionNotifier, SshSessionState>(
  SshSessionNotifier.new,
);
