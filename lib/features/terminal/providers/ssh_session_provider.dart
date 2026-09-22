import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh2/ssh2.dart';

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

/// SSH 会话注册表：负责保存/加载/连接/断开/删除，并持有 SSHClient。
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

  /// 保存/更新一个会话（只保存配置，不连接）。
  Future<String> save(SshSessionDraft draft, {String? id}) async {
    await loadSaved();
    final targetId = id ?? _newId();
    final existed = _sessions[targetId];
    _sessions[targetId] = SshSession(
      id: targetId,
      name: draft.name,
      host: draft.host,
      port: draft.port,
      username: draft.username,
      authType: draft.authType,
      status: existed?.status ?? 'disconnected',
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
    final targetId = id ?? await save(draft);
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

    final dynamic passwordOrKey = draft.authType == SshAuthType.password
        ? draft.password ?? ''
        : {
            if (draft.privateKey != null && draft.privateKey!.isNotEmpty)
              'privateKey': draft.privateKey,
            if (draft.keyPassphrase != null && draft.keyPassphrase!.isNotEmpty)
              'passphrase': draft.keyPassphrase,
          };

    final client = SSHClient(
      host: draft.host,
      port: draft.port,
      username: draft.username,
      passwordOrKey: passwordOrKey,
    );

    try {
      final result = await client.connect();
      if (result != null && result != 'connected') {
        _sessions[targetId] = SshSession(
            id: targetId,
            name: draft.name,
            host: draft.host,
            port: draft.port,
            username: draft.username,
            authType: draft.authType,
            status: 'error: $result');
        client.disconnect();
        _notify();
        return _sessions[targetId]!;
      }
      _clients[targetId] = client;
      _sessions[targetId] = SshSession(
          id: targetId,
          name: draft.name,
          host: draft.host,
          port: draft.port,
          username: draft.username,
          authType: draft.authType,
          status: 'connected');
      _notify();
      return _sessions[targetId]!;
    } catch (e) {
      _sessions[targetId] = SshSession(
          id: targetId,
          name: draft.name,
          host: draft.host,
          port: draft.port,
          username: draft.username,
          authType: draft.authType,
          status: 'error: $e');
      _notify();
      return _sessions[targetId]!;
    }
  }

  /// 断开连接但保留已保存的会话，下次可再连接。
  Future<void> disconnect(String id) async {
    final client = _clients.remove(id);
    if (client != null) {
      try {
        await client.disconnectSFTP();
      } catch (_) {}
      client.disconnect();
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
    final out = await client.execute(command);
    return out ?? '';
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
