import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/local_shell/proot_bridge.dart';
import '../settings/providers/settings_provider.dart';
import 'providers/shell_files_provider.dart';
import 'providers/terminal_session_provider.dart';
import 'terminal_palettes.dart';
import '../../../shared/mono_text.dart';

/// 悬浮窗终端：在文件管理器当前目录上浮一层，方便用户直接在该目录跑命令。
class FloatingTerminal {
  static OverlayEntry? _entry;

  static bool get isOpen => _entry != null;

  static void show(
    BuildContext context, {
    String? cwd,
  }) {
    if (_entry != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (_) => FloatingTerminalWindow(
        cwd: cwd ?? fileManagerCwd.value,
        onClose: () {
          _entry?.remove();
          _entry = null;
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

class FloatingTerminalWindow extends ConsumerStatefulWidget {
  const FloatingTerminalWindow({
    super.key,
    required this.cwd,
    required this.onClose,
  });

  final String cwd;
  final VoidCallback onClose;

  @override
  ConsumerState<FloatingTerminalWindow> createState() =>
      _FloatingTerminalWindowState();
}

class _FloatingTerminalWindowState
    extends ConsumerState<FloatingTerminalWindow> {
  final _terminal = Terminal(maxLines: 2000);
  final _terminalController = TerminalController();
  final _focusNode = FocusNode();
  late final ProotBridge _bridge = ProotBridge();
  StreamSubscription<Map<String, dynamic>>? _eventsSubscription;
  Offset _pos = const Offset(24, 90);
  Size _size = const Size(360, 260);
  bool _ready = false;
  String? _error;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _writeTerminal;
    _terminal.onResize = (w, h, pw, ph) {
      unawaited(_bridge.resizeTerminal(w, h));
    };
    _eventsSubscription = _bridge.terminalEvents().listen(_onTerminalEvent);
    Future.microtask(_start);
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    _bridge.stopTerminal();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final notifier = ref.read(terminalSessionProvider.notifier);
      await notifier.load();
      final state = ref.read(terminalSessionProvider);
      if (!state.running) {
        await notifier.spawn();
      }
      if (!mounted) return;
      setState(() {
        _ready = true;
        _error = ref.read(terminalSessionProvider).error;
      });
      // 进入文件管理器当前目录。
      final dir = widget.cwd.trim();
      if (dir.isNotEmpty) {
        await _bridge.writeTerminal('cd ${_shq(dir)}\n');
        await _bridge.writeTerminal('pwd\n');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _ready = true;
        });
      }
    }
  }

  static String _shq(String s) => "'${s.replaceAll("'", "'\\''")}'";

  void _writeTerminal(String data) {
    unawaited(_bridge.writeTerminal(data));
  }

  void _onTerminalEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'output':
        _terminal.write(event['data']?.toString() ?? '');
      case 'exit':
        ref.read(terminalSessionProvider.notifier).markExited();
    }
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final width = (_size.width).clamp(220.0, media.size.width - 16);
    final height = (_size.height).clamp(160.0, media.size.height - 120);
    final left = _pos.dx.clamp(0.0, media.size.width - width - 8);
    final top = _pos.dy.clamp(MediaQuery.paddingOf(context).top,
        media.size.height - height - 8);
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Stack(
        children: [
          // 无边框：终端本体直接铺满悬浮窗。
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ColoredBox(
                color: const Color(0xF0282C34),
                child: _buildBody(scheme),
              ),
            ),
          ),
          // 顶部一条细的拖动手势区，不影响终端主体输入。
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 18,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: (d) {
                setState(() => _pos += d.delta);
              },
              child: const SizedBox.expand(),
            ),
          ),
          // 当前目录小标签。
          Positioned(
            left: 8,
            top: 5,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  widget.cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9,
                    color: Colors.white70,
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                  ),
                ),
              ),
            ),
          ),
          // 右上角半透明关闭点。
          Positioned(
            right: 2,
            top: 0,
            child: IconButton(
              tooltip: '关闭悬浮终端',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(
                minWidth: 30,
                minHeight: 30,
              ),
              iconSize: 14,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close_rounded,
                  color: Colors.white70),
              onPressed: _close,
            ),
          ),
          // 右下角缩放。
          Positioned(
            right: 0,
            bottom: 0,
            width: 20,
            height: 20,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) {
                setState(() {
                  _size = Size(
                    (_size.width + d.delta.dx).clamp(220.0, 700.0),
                    (_size.height + d.delta.dy).clamp(160.0, 600.0),
                  );
                });
              },
              child: const Icon(
                Icons.open_in_full_rounded,
                size: 13,
                color: Colors.white54,
              ),
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildBody(ColorScheme scheme) {
    if (!_ready) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 8),
            Text(
              '启动终端…',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _error!,
            style: TextStyle(fontSize: 11, color: scheme.error),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final settings = ref.watch(settingsProvider);
    return TerminalView(
      _terminal,
      controller: _terminalController,
      focusNode: _focusNode,
      autofocus: true,
      keyboardType: TextInputType.multiline,
      backgroundOpacity: 0.92,
      theme: TerminalPalette.byId(settings.terminalPalette).theme,
      textStyle: TerminalStyle(
        fontSize: settings.terminalFontSize,
        height: settings.terminalLineHeight,
        fontFamily: kMonoFamily,
        fontFamilyFallback: kMonoFallback,
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
      cursorType: TerminalCursorType.block,
    );
  }
}
