import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/local_shell/proot_bridge.dart';
import '../../../core/local_shell/shell_detector.dart';
import '../../settings/providers/settings_provider.dart';

class TerminalSessionState {
  const TerminalSessionState({
    this.status,
    this.installing = false,
    this.running = false,
    this.progress,
    this.error,
    this.spawnedId,
  });

  final PreruntimeStatus? status;
  final bool installing;
  final bool running;

  /// 安装进度（仅 installing 期间有值）。
  final InstallProgress? progress;
  final String? error;

  /// 最近一次自动/手动 spawn 出来的本地终端 id（供页面把它接成标签）。
  final int? spawnedId;

  bool get isAndroidSupported => const ShellDetector().isAndroid;

  TerminalSessionState copyWith({
    PreruntimeStatus? status,
    bool? installing,
    bool? running,
    InstallProgress? progress,
    bool clearProgress = false,
    String? error,
    bool clearError = false,
    int? spawnedId,
    bool clearSpawnedId = false,
  }) {
    return TerminalSessionState(
      status: status ?? this.status,
      installing: installing ?? this.installing,
      running: running ?? this.running,
      progress: clearProgress ? null : progress ?? this.progress,
      error: clearError ? null : error ?? this.error,
      spawnedId: clearSpawnedId ? null : spawnedId ?? this.spawnedId,
    );
  }
}

class TerminalSessionNotifier extends Notifier<TerminalSessionState> {
  StreamSubscription<InstallProgress>? _progressSub;

  @override
  TerminalSessionState build() {
    ref.onDispose(() => _progressSub?.cancel());
    return const TerminalSessionState();
  }

  Future<void> load() async {
    final result = await const ShellDetector().probe();
    state = state.copyWith(
      status: result.status,
      running: false,
      clearError: true,
      clearSpawnedId: true,
    );
    await _maybeAutoStart();
  }

  /// 设置里开了「启动 APP 自动启动终端」就直接拉起 shell。
  /// 只在已安装且当前没跑的时候动手，绝不自动触发 150MB 下载。
  Future<void> _maybeAutoStart() async {
    if (state.running) return;
    if (state.status?.installed != true) return;
    if (!state.isAndroidSupported) return;
    final autoStart = ref.read(settingsProvider).autoStartTerminal;
    if (!autoStart) return;
    await spawn();
  }

  Future<void> install({bool clean = false}) async {
    if (state.installing) return;
    // 重装前先把正在跑的会话停掉：不然要替换的目录还被占着。
    if (state.running) stop();
    state = state.copyWith(
      installing: true,
      clearError: true,
      progress: const InstallProgress(
        stage: '准备下载',
        received: 0,
        total: 0,
        done: false,
      ),
    );
    final bridge = ProotBridge();
    // 先订阅再发起安装，否则最初几个进度事件会丢。
    _progressSub?.cancel();
    _progressSub = bridge.installProgress().listen((p) {
      state = state.copyWith(progress: p, error: p.error ?? state.error);
    });
    try {
      await bridge.install(clean: clean);
      final result = await const ShellDetector().probe();
      state = state.copyWith(
        status: result.status,
        installing: false,
        clearProgress: true,
      );
      await _maybeAutoStart();
    } catch (e) {
      state = state.copyWith(
        installing: false,
        error: e.toString(),
        clearProgress: true,
      );
    } finally {
      await _progressSub?.cancel();
      _progressSub = null;
    }
  }

  Future<int?> spawn() async {
    if (state.running) return state.spawnedId;
    try {
      final id = await ProotBridge().spawnTerminal();
      state = state.copyWith(
        running: id != 0,
        spawnedId: id != 0 ? id : null,
        clearError: true,
      );
      return id != 0 ? id : null;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  void markExited() {
    state = state.copyWith(running: false);
  }

  void stop() async {
    await ProotBridge().stopAllTerminals();
    markExited();
    state = state.copyWith(clearSpawnedId: true);
  }
}

final terminalSessionProvider =
    NotifierProvider<TerminalSessionNotifier, TerminalSessionState>(
  TerminalSessionNotifier.new,
);
