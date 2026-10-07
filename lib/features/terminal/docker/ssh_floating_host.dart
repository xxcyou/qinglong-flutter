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
    final groups = <String>[];
    for (final w in minimized) {
      if (!groups.contains(w.group)) groups.add(w.group);
    }
    return SizedBox(
      height: 66,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final group in groups)
              _MinimizeFolder(
                label: (minimized.firstWhere((w) => w.group == group)).title,
                windows: minimized.where((w) => w.group == group).toList(),
              ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _MinimizeFolder extends StatelessWidget {
  const _MinimizeFolder({
    required this.label,
    required this.windows,
  });

  final String label;
  final List<_HostedWindow> windows;

  @override
  Widget build(BuildContext context) {
    final display = label.length > 8 ? '${label.substring(0, 8)}…' : label;
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: const Color(0xEE28313B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: '展开 $label 的全部悬浮窗',
            child: InkWell(
              onTap: () => SshFloatingHost.expandGroup(windows.first.group),
              borderRadius: BorderRadius.circular(10),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.folder_rounded, color: Colors.amber, size: 20),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final w in windows)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Tooltip(
                        message: '展开 ${w.title}',
                        child: InkWell(
                          onTap: () => SshFloatingHost.expand(w.id),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            width: 26,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Icon(w.icon, size: 14, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
