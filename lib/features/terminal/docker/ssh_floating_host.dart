import 'package:flutter/material.dart';

/// SSH 容器悬浮窗总控：多个悬浮窗共用同一个 OverlayEntry。
/// 支持：点击置顶、最小化成容器文件夹、按容器分组批量最小化/恢复。
/// 所有窗口都保留在树里（Offstage），因此终端会话/路径/文件状态不会丢。
class SshFloatingHost {
  SshFloatingHost._();

  static final List<_HostedWindow> _windows = [];
  static OverlayEntry? _entry;
  static int _counter = 0;

  /// 注册一个悬浮窗，返回稳定 id。
  static int add(
    BuildContext context, {
    required String group,
    required String title,
    required IconData icon,
    required WidgetBuilder builder,
  }) {
    final id = ++_counter;
    _windows.add(_HostedWindow(
      id: id,
      group: group,
      title: title,
      icon: icon,
      key: UniqueKey(),
      builder: builder,
    ));
    final overlay = Overlay.of(context, rootOverlay: true);
    if (_entry == null) {
      late final OverlayEntry entry;
      entry = OverlayEntry(
        builder: (context) => Stack(
          children: [
            for (final w in _windows)
              Offstage(
                offstage: w.minimized,
                child: KeyedSubtree(key: w.key, child: w.builder(context)),
              ),
            if (_windows.any((w) => w.minimized))
              const Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: _MinimizeDock(),
              ),
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

  /// 最小化成容器文件夹里的一个图标。
  static void minimize(int id) {
    final w = _windows.where((x) => x.id == id).firstOrNull;
    if (w == null || w.minimized) return;
    w.minimized = true;
    _entry?.markNeedsBuild();
  }

  /// 从小方块恢复显示，并置顶。
  static void expand(int id) {
    final w = _windows.where((x) => x.id == id).firstOrNull;
    if (w == null) return;
    w.minimized = false;
    // 先强制重建，再置顶；避免目标本来就是最后一个时 focus 提前 return 不刷新。
    _entry?.markNeedsBuild();
    focus(id);
  }

  /// 展开某个容器文件夹里的全部最小化窗口。
  static void expandGroup(String group) {
    var changed = false;
    for (final w in _windows) {
      if (w.group == group && w.minimized) {
        w.minimized = false;
        changed = true;
      }
    }
    if (changed) {
      _entry?.markNeedsBuild();
      final last = _windows.lastWhere(
        (w) => w.group == group,
        orElse: () => _windows.last,
      );
      focus(last.id);
    }
  }

  /// 把某容器当前展开（非最小化）的悬浮窗全部最小化，返回展开的 id 列表。
  static Set<int> minimizeExpandedGroup(String group) {
    final expanded = <int>{};
    for (final w in _windows) {
      if (w.group == group && !w.minimized) {
        w.minimized = true;
        expanded.add(w.id);
      }
    }
    _entry?.markNeedsBuild();
    return expanded;
  }

  /// 恢复某容器在编辑前展开过的悬浮窗。
  static void restoreExpandedGroup(String group, Set<int> ids) {
    for (final w in _windows) {
      if (w.group == group && ids.contains(w.id)) {
        w.minimized = false;
      }
    }
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
  _HostedWindow({
    required this.id,
    required this.group,
    required this.title,
    required this.icon,
    required this.key,
    required this.builder,
  });

  final int id;
  final String group;
  final String title;
  final IconData icon;
  bool minimized = false;
  final Key key;
  final WidgetBuilder builder;
}

/// 底部收纳栏：按容器分组显示，一行横向滑动。
class _MinimizeDock extends StatelessWidget {
  const _MinimizeDock();

  @override
  Widget build(BuildContext context) {
    final minimized = SshFloatingHost._windows
        .where((w) => w.minimized)
        .toList();
    if (minimized.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 68,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final w in minimized) _MinimizeCube(window: w),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _MinimizeCube extends StatelessWidget {
  const _MinimizeCube({required this.window});

  final _HostedWindow window;

  @override
  Widget build(BuildContext context) {
    final display =
        window.title.length > 5 ? '${window.title.substring(0, 5)}…' : window.title;
    return Tooltip(
      message: '展开 ${window.title}',
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: const Color(0xEE28313B),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: () => SshFloatingHost.expand(window.id),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 56,
              height: 58,
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(window.icon, size: 20, color: Colors.white),
                  const SizedBox(height: 3),
                  Text(
                    display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 9, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
