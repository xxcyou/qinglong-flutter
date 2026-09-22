import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ssh2/ssh2.dart';

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
  final String status; // connecting / connected / error

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

/// 连接参数，不携带秘密用于 UI 状态。
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

/// SSH 会话注册表：负责连接/断开/持有 SSHClient。
class SshSessionManager {
  SshSessionManager._();

  static final SshSessionManager instance = SshSessionManager._();

  final Map<String, SSHClient> _clients = {};
  final Map<String, SshSession> _sessions = {};
  final Map<String, SshSessionDraft> _drafts = {};
  final List<void Function()> _listeners = [];

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

  Future<SshSession> connect(SshSessionDraft draft) async {
    final id =
        'ssh_${DateTime.now().millisecondsSinceEpoch}_${_sessions.length}';
    final session = SshSession(
      id: id,
      name: draft.name,
      host: draft.host,
      port: draft.port,
      username: draft.username,
      authType: draft.authType,
      status: 'connecting',
    );
    _sessions[id] = session;
    _drafts[id] = draft;
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
        _sessions[id] = session.copyWith(status: 'error: $result');
        client.disconnect();
        _notify();
        return _sessions[id]!;
      }
      _clients[id] = client;
      _sessions[id] = session.copyWith(status: 'connected');
      _notify();
      return _sessions[id]!;
    } catch (e) {
      _sessions[id] = session.copyWith(status: 'error: $e');
      _notify();
      return _sessions[id]!;
    }
  }

  Future<void> disconnect(String id) async {
    final client = _clients.remove(id);
    if (client != null) {
      try {
        await client.disconnectSFTP();
      } catch (_) {}
      client.disconnect();
    }
    _sessions.remove(id);
    _drafts.remove(id);
    _notify();
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
    return SshSessionState(
      sessions: SshSessionManager.instance.sessions,
    );
  }

  void _onChange() {
    state = SshSessionState(sessions: SshSessionManager.instance.sessions);
  }

  Future<SshSession> connect(SshSessionDraft draft) =>
      SshSessionManager.instance.connect(draft);

  Future<void> disconnect(String id) =>
      SshSessionManager.instance.disconnect(id);
}

final sshSessionsProvider =
    NotifierProvider<SshSessionNotifier, SshSessionState>(
  SshSessionNotifier.new,
);
