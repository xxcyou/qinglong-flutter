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
    revision.value++;
  }

  static void remove(Object id) {
    _disabled.remove(id);
    _removeRect(id);
  }

  static void _removeRect(Object id) {
    if (_rects.remove(id) == null) return;
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
    final shift = controller.active.value && !controller.fullScreenSize.isEmpty
        ? controller.bounds.value.topLeft
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
