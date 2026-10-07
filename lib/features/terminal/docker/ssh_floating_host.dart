import 'package:flutter/material.dart';

/// SSH 容器悬浮窗总控：多个悬浮窗共用同一个 OverlayEntry，
/// 点击窗口时只调整内部 Stack 顺序，不销毁重建，因此终端/日志状态不丢。
class SshFloatingHost {
  SshFloatingHost._();

  static final List<_HostedWindow> _windows = [];
  static OverlayEntry? _entry;
  static int _counter = 0;

  /// 注册一个悬浮窗，返回它的稳定 id。
  static int add(BuildContext context, WidgetBuilder builder) {
    final id = ++_counter;
    _windows.add(_HostedWindow(id: id, key: UniqueKey(), builder: builder));
    final overlay = Overlay.of(context, rootOverlay: true);
    if (_entry == null) {
      late final OverlayEntry entry;
      entry = OverlayEntry(
        builder: (context) => Stack(
          children: [
            for (final w in _windows)
              KeyedSubtree(key: w.key, child: w.builder(context)),
          ],
        ),
      );
      _entry = entry;
      overlay.insert(entry);
    } else {
      _entry!.markNeedsBuild();
    }
    return id;
  }

  /// 点击某个悬浮窗时把它置顶。
  static void focus(int id) {
    final i = _windows.indexWhere((w) => w.id == id);
    if (i < 0 || i == _windows.length - 1) return;
    final w = _windows.removeAt(i);
    _windows.add(w);
    _entry?.markNeedsBuild();
  }

  /// 关闭某个悬浮窗。
  static void close(int id) {
    final i = _windows.indexWhere((w) => w.id == id);
    if (i < 0) return;
    _windows.removeAt(i);
    if (_windows.isEmpty) {
      _entry?.remove();
      _entry = null;
      return;
    }
    _entry?.markNeedsBuild();
  }
}

class _HostedWindow {
  const _HostedWindow({
    required this.id,
    required this.key,
    required this.builder,
  });

  final int id;
  final Key key;
  final WidgetBuilder builder;
}
