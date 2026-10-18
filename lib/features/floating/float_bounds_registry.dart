import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../external/external_overlay_controller.dart';

/// 悬浮窗实际渲染矩形的登记处。
///
/// APP 外悬浮窗的原生覆盖窗口大小 = 当前所有可见悬浮窗的并集。AI 球/聊天窗/
/// 浏览器窗的位置能从状态比例算出来；终端/SSH/画布这类窗口是自己内部维护
/// `Offset + Size`，直接让它们每帧把实际 RenderBox 全局矩形登记进来最稳。
class FloatBoundsRegistry {
  FloatBoundsRegistry._();

  static final Map<Object, Rect> _rects = {};
  static final Set<Object> _disabled = {};

  /// 有窗口矩形变化时自增，供 AppFloatLayer 触发上报。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 最小化（Offstage 但仍 build）时禁止上报，否则覆盖窗口会算上隐藏窗口。
  static void setEnabled(Object id, bool enabled) {
    if (enabled) {
      _disabled.remove(id);
      return;
    }
    _disabled.add(id);
    _removeRect(id);
  }

  static void report(Object id, Rect rect) {
    if (_disabled.contains(id)) return;
    if (rect.isEmpty) {
      remove(id);
      return;
    }
    if (_rects[id] == rect) return;
    _rects[id] = rect;
    _bumpRevision();
  }

  static void remove(Object id) {
    _disabled.remove(id);
    _removeRect(id);
  }

  static void _removeRect(Object id) {
    if (_rects.remove(id) == null) return;
    _bumpRevision();
  }

  static bool _kickScheduled = false;

  /// 很多窗口是在 `build()` 里直接登记矩形的；在 build 阶段 notifyListeners
  /// 时，已经构建过/正在构建的 `FloatBoundsReporter` 可能吃不到这次通知，
  /// 于是原生覆盖窗口一直只按旧的并集大小（只包住 AI 球），终端/日志/
  /// 文件夹窗就被裁成“只显示一半”。这里在帧末再补一次通知，强制下一帧
  /// 重新计算并上报并集。
  static void _bumpRevision() {
    // 帧构建过程中直接 notifyListeners 会触发
    // “setState() or markNeedsBuild() called during build”：登记方
    // （SshFloatingHostLayer 里的窗口）和监听方（_FloatBoundsReporter）
    // 是兄弟节点，Flutter 不允许这样标记。延到帧末再通知，下一帧重算
    // 并集并上报，原生覆盖窗才能包住容器终端/日志/文件夹窗。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_kickScheduled) return;
      _kickScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _kickScheduled = false;
        revision.value++;
      });
      return;
    }
    revision.value++;
  }

  static Rect get union {
    Rect? result;
    for (final r in _rects.values) {
      if (r.isEmpty) continue;
      result = result == null ? r : result.expandToInclude(r);
    }
    return result ?? Rect.zero;
  }
}

/// 把一个任意尺寸的实际渲染矩形登记到 [FloatBoundsRegistry]。
///
/// AI 快问结果窗、ui_c 画布窗、提问窗的尺寸/高度不是比例算出来的，
/// 直接包在该 widget 外面，让 RenderBox 自己上报全局矩形，原生覆盖窗
/// 就能自动把每个独立悬浮窗都包住，不再被别的窗口大小限制。
class FloatBoundsReporter extends StatefulWidget {
  const FloatBoundsReporter({
    super.key,
    required this.id,
    required this.child,
  });

  final Object id;
  final Widget child;

  @override
  State<FloatBoundsReporter> createState() => _FloatBoundsReporterState();
}

class _FloatBoundsReporterState extends State<FloatBoundsReporter> {
  final GlobalKey _key = GlobalKey(debugLabel: 'FloatBoundsReporter');

  void _report() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final local = box.localToGlobal(Offset.zero);
    final controller = ExternalOverlayController.instance;
    // APP 外模式下 Shell 把整层 AppFloatLayer 平移了 -bounds.topLeft；
    // 加回来后方登记的是“全屏逻辑坐标”，和 _visibleBounds 里其它窗口一致。
    final shift = controller.active.value && controller.fullScreenSize.width > 0
        ? controller.appliedBounds.value.topLeft
        : Offset.zero;
    FloatBoundsRegistry.report(widget.id, (local + shift) & box.size);
  }

  @override
  void didUpdateWidget(covariant FloatBoundsReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      FloatBoundsRegistry.remove(oldWidget.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _report();
    });
    return KeyedSubtree(key: _key, child: widget.child);
  }

  @override
  void dispose() {
    FloatBoundsRegistry.remove(widget.id);
    super.dispose();
  }
}
