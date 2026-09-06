import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 浏览器窗口的显示形态。
enum BrowserWindowMode {
  /// 悬浮窗：可拖动、可按边缩放，下面的页面照样能点。
  floating,

  /// 铺满全屏：需要认真看网页、填长表单时用。
  maximized,
}

/// 浏览器悬浮窗的几何状态（都是占屏比例，换屏幕/横竖屏都不会跑偏）。
@immutable
class BrowserWindowState {
  const BrowserWindowState({
    this.mode = BrowserWindowMode.floating,
    this.x = 0.02,
    this.y = 0.05,
    this.w = 0.96,
    this.h = 0.66,
  });

  final BrowserWindowMode mode;
  final double x;
  final double y;
  final double w;
  final double h;

  bool get maximized => mode == BrowserWindowMode.maximized;

  BrowserWindowState copyWith({
    BrowserWindowMode? mode,
    double? x,
    double? y,
    double? w,
    double? h,
  }) {
    return BrowserWindowState(
      mode: mode ?? this.mode,
      x: x ?? this.x,
      y: y ?? this.y,
      w: w ?? this.w,
      h: h ?? this.h,
    );
  }
}

/// 浏览器窗口状态的单例。
///
/// 为什么不做成 Riverpod provider：宿主部件挂在 MaterialApp.builder 里，
/// 和 WebView 内核（同样是单例）是一对一的关系，用一个 ValueNotifier
/// 反而少一层间接。位置只在松手时落盘，拖动过程中不写。
class BrowserWindow extends ValueNotifier<BrowserWindowState> {
  BrowserWindow._() : super(const BrowserWindowState());

  static final BrowserWindow instance = BrowserWindow._();

  /// 窗口最小尺寸（占可用区比例）。浏览器比聊天窗需要更多地方：
  /// 再小就只能看见半个导航栏，什么网页都读不了。
  static const minW = 0.52;
  static const minH = 0.34;

  static const _key = 'browser_window_geometry';

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key);
    if (raw == null || raw.length < 5) return;
    final x = double.tryParse(raw[0]);
    final y = double.tryParse(raw[1]);
    final w = double.tryParse(raw[2]);
    final h = double.tryParse(raw[3]);
    if (x == null || y == null || w == null || h == null) return;
    value = BrowserWindowState(
      mode: raw[4] == 'max'
          ? BrowserWindowMode.maximized
          : BrowserWindowMode.floating,
      x: x,
      y: y,
      w: w.clamp(minW, 1.0),
      h: h.clamp(minH, 1.0),
    );
  }

  Future<void> commit() async {
    final v = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, [
      v.x.toStringAsFixed(4),
      v.y.toStringAsFixed(4),
      v.w.toStringAsFixed(4),
      v.h.toStringAsFixed(4),
      v.maximized ? 'max' : 'float',
    ]);
  }

  void moveBy(double dxFrac, double dyFrac) {
    final v = value;
    value = v.copyWith(
      x: (v.x + dxFrac).clamp(0.0, 1.0 - v.w),
      y: (v.y + dyFrac).clamp(0.0, 1.0 - v.h),
    );
  }

  /// 按边缩放。用"边界"算而不是"宽高 + 位移"：拖左边框时右边必须钉住，
  /// 否则窗口会一边变窄一边整体往左跑。
  void resize({
    double dLeft = 0,
    double dTop = 0,
    double dRight = 0,
    double dBottom = 0,
  }) {
    final v = value;
    var l = v.x;
    var t = v.y;
    var r = v.x + v.w;
    var b = v.y + v.h;
    if (dLeft != 0) l = (l + dLeft).clamp(0.0, r - minW);
    if (dRight != 0) r = (r + dRight).clamp(l + minW, 1.0);
    if (dTop != 0) t = (t + dTop).clamp(0.0, b - minH);
    if (dBottom != 0) b = (b + dBottom).clamp(t + minH, 1.0);
    value = v.copyWith(x: l, y: t, w: r - l, h: b - t);
  }

  void toggleMax() {
    value = value.copyWith(
      mode: value.maximized
          ? BrowserWindowMode.floating
          : BrowserWindowMode.maximized,
    );
    commit();
  }
}
