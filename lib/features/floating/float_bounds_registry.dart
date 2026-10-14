import 'package:flutter/widgets.dart';

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
