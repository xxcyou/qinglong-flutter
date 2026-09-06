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
  });

  final PreruntimeStatus? status;
  final bool installing;
  final bool running;

  /// 安装进度（仅 installing 期间有值）。
  final InstallProgress? progress;
  final String? error;

  bool get isAndroidSupported => const ShellDetector().isAndroid;

  TerminalSessionState copyWith({
    PreruntimeStatus? status,
    bool? installing,
    bool? running,
    InstallProgress? progress,
    bool clearProgress = false,
    String? error,
    bool clearError = false,
  }) {
    return TerminalSessionState(
      status: status ?? this.status,
      installing: installing ?? this.installing,
      running: running ?? this.running,
      progress: clearProgress ? null : progress ?? this.progress,
      error: clearError ? null : error ?? this.error,
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

  Future<void> spawn() async {
    if (state.running) return;
    try {
      final ok = await ProotBridge().spawnTerminal();
      state = state.copyWith(running: ok, clearError: true);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  void markExited() {
    state = state.copyWith(running: false);
  }

  void stop() async {
    await ProotBridge().stopTerminal();
    markExited();
  }
}

final terminalSessionProvider =
    NotifierProvider<TerminalSessionNotifier, TerminalSessionState>(
  TerminalSessionNotifier.new,
);
