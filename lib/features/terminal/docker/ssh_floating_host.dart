import 'package:flutter/material.dart';

import '../../floating/float_bounds_registry.dart';

/// SSH 容器悬浮窗总控：所有容器终端/日志/文件窗共用同一份常驻列表。
/// 支持：点击置顶、最小化成小方块。
/// 所有窗口都保留在树里（Offstage），因此终端会话/路径/文件状态不会丢。
///
/// 和 [FloatingTerminal] 一样，不再往页面 OverlayEntry 插入，而是由
/// [SshFloatingHostLayer] 渲染在 [AppFloatLayer] 中，APP 外悬浮模式下也常驻。
class SshFloatingHost {
  SshFloatingHost._();

  static final List<_HostedWindow> _windows = [];
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
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
    revision.value++;
    return id;
  }

  /// 点击某个悬浮窗时把它置顶。
  static void focus(int id) {
    final i = _windows.indexWhere((w) => w.id == id);
    if (i < 0 || i == _windows.length - 1) return;
    final w = _windows.removeAt(i);
    _windows.add(w);
    revision.value++;
  }

  /// 最小化成小方块。
  static void minimize(int id) {
    final w = _windows.where((x) => x.id == id).firstOrNull;
    if (w == null || w.minimized) return;
    w.minimized = true;
    FloatBoundsRegistry.setEnabled('ssh-float-$id', false);
    revision.value++;
  }

  /// 从小方块恢复显示，并置顶。
  static void expand(int id) {
    final w = _windows.where((x) => x.id == id).firstOrNull;
    if (w == null) return;
    w.minimized = false;
    FloatBoundsRegistry.setEnabled('ssh-float-$id', true);
    // 先强制刷新再置顶，避免目标本来就是最后一个时 focus 提前 return 不刷新。
    revision.value++;
    focus(id);
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
    revision.value++;
    return expanded;
  }

  /// 恢复某容器在编辑前展开过的悬浮窗。
  static void restoreExpandedGroup(String group, Set<int> ids) {
    for (final w in _windows) {
      if (w.group == group && ids.contains(w.id)) {
        w.minimized = false;
      }
    }
    revision.value++;
  }

  /// 关闭某个悬浮窗。
  static void close(int id) {
    final i = _windows.indexWhere((w) => w.id == id);
    if (i < 0) return;
    _windows.removeAt(i);
    FloatBoundsRegistry.setEnabled('ssh-float-$id', false);
    revision.value++;
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

/// 常驻 SSH 悬浮窗宿主：挂在 [AppFloatLayer] 中。
class SshFloatingHostLayer extends StatelessWidget {
  const SshFloatingHostLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: SshFloatingHost.revision,
      builder: (context, _, __) {
        final windows = SshFloatingHost._windows;
        if (windows.isEmpty) return const SizedBox.shrink();
        return Stack(
          fit: StackFit.expand,
          children: [
            for (final w in windows)
              KeyedSubtree(
                key: w.key,
                child: Offstage(
                  offstage: w.minimized,
                  child: w.builder(context),
                ),
              ),
            if (windows.any((w) => w.minimized))
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final w in windows.where((w) => w.minimized))
                        _MinimizeCube(
                          title: w.title,
                          icon: w.icon,
                          onTap: () => SshFloatingHost.expand(w.id),
                        ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MinimizeCube extends StatelessWidget {
  const _MinimizeCube({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final display = title.length > 4 ? '${title.substring(0, 4)}…' : title;
    return Tooltip(
      message: '展开 $title',
      child: Material(
        color: const Color(0xFF28313B),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: Colors.white),
                const SizedBox(height: 2),
                Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 8, color: Colors.white70),
                ),
              ],
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
