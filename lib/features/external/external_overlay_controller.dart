import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// APP 外系统悬浮窗（预览）控制器。
///
/// 真正的窗口由 Android 前台服务用 [WindowManager] 承载，Flutter 这边只负责：
/// - 进入/退出外部悬浮模式；
/// - 把当前可见悬浮窗的并集矩形上报给原生，让覆盖窗口刚好包住内容，
///   窗口外的触摸继续落到下面的 APP 上；
/// - 接收原生的“返回 APP / 模式被系统结束”通知。
///
/// 这是预览分支的能力，默认关闭，不影响正式版。
class ExternalOverlayController {
  ExternalOverlayController._() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static final ExternalOverlayController instance = ExternalOverlayController._();

  static const MethodChannel _channel = MethodChannel('qinglong/external_overlay');

  /// 是否处于 APP 外悬浮模式。
  final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// 当前上报给原生的窗口矩形（逻辑像素）。
  final ValueNotifier<Rect> bounds = ValueNotifier<Rect>(Rect.zero);

  /// 进入外部模式前的完整屏幕尺寸/安全区，用于悬浮 FlutterView 内部
  /// 仍然按“全屏坐标系”布局原有悬浮窗。
  Size fullScreenSize = Size.zero;
  EdgeInsets fullScreenPadding = EdgeInsets.zero;
  EdgeInsets fullScreenViewPadding = EdgeInsets.zero;
  EdgeInsets systemGestureInsets = EdgeInsets.zero;

  /// 逻辑像素 -> 物理像素。原生 WindowManager 用的是物理像素。
  double devicePixelRatio = 1.0;

  /// 最后一次计算出的并集矩形；进入外部模式时先拿它当初始 bounds。
  Rect _lastKnownBounds = Rect.zero;

  /// 原生窗口当前使用的“粘性包络”。
  ///
  /// 如果每帧都按悬浮窗并集去改原生窗口，拖浏览器时窗口会不停移动/缩放，
  /// 同一窗口里的 AI 悬浮球就会跟着抖。这里改成：窗口只在内容接近边缘时
  /// 扩张，内容缩进去一大截后才收缩；小幅拖动完全不碰原生窗口。
  Rect? _windowBounds;
  static const double _windowMargin = 48;
  static const double _shrinkMargin = 120;

  Timer? _boundsDebounce;
  bool _busy = false;

  bool get supported => defaultTargetPlatform == TargetPlatform.android;

  /// 系统是否已授予“显示在其他应用上层”权限。
  Future<bool> isPermissionGranted() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isPermissionGranted') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统悬浮窗授权页。返回后需要用户手动点一次开启。
  Future<void> openPermissionSettings() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } catch (_) {}
  }

  /// 记录当前全屏信息，同时把并集矩形缓存下来。
  void noteFullScreen(MediaQueryData media) {
    fullScreenSize = media.size;
    fullScreenPadding = media.padding;
    fullScreenViewPadding = media.viewPadding;
    systemGestureInsets = media.systemGestureInsets;
    devicePixelRatio = media.devicePixelRatio <= 0 ? 1.0 : media.devicePixelRatio;
  }

  /// 由悬浮层在每一帧后上报可见窗口并集。
  void noteBounds(Rect desired) {
    _lastKnownBounds = desired;
    if (!active.value) return;
    final next = _stickyWindow(desired);
    if (next == bounds.value) return;
    bounds.value = next;
    _scheduleNativeBoundsUpdate();
  }

  Rect _stickyWindow(Rect desired) {
    final padded = desired.inflate(_windowMargin);
    final current = _windowBounds;
    if (current == null || current.isEmpty) {
      _windowBounds = padded;
      return padded;
    }
    final needsGrow = !current.contains(desired.topLeft) ||
        !current.contains(desired.bottomRight);
    if (needsGrow) {
      _windowBounds = current.expandToInclude(padded);
      return _windowBounds!;
    }
    final canShrink = current.left <= desired.left - _shrinkMargin &&
        current.top <= desired.top - _shrinkMargin &&
        current.right >= desired.right + _shrinkMargin &&
        current.bottom >= desired.bottom + _shrinkMargin;
    if (canShrink) {
      _windowBounds = padded;
      return padded;
    }
    return current;
  }

  void _scheduleNativeBoundsUpdate() {
    _boundsDebounce?.cancel();
    _boundsDebounce = Timer(const Duration(milliseconds: 60), () {
      if (!active.value) return;
      final r = bounds.value;
      if (r.isEmpty) return;
      _channel.invokeMethod<void>('updateBounds', _physicalArgs(r))
          .catchError((_) {});
    });
  }

  /// 进入 APP 外悬浮模式。
  ///
  /// [media] 必须是主 APP 的全屏 MediaQuery；进入后 FlutterView 会被原生
  /// 缩小到悬浮窗并集，但 Dart 侧仍用这份全屏尺寸做坐标系。
  Future<bool>? _enableInFlight;

  Future<bool> enable(
    MediaQueryData media, {
    Rect? initialBounds,
    bool requestPermission = true,
  }) {
    final inFlight = _enableInFlight;
    if (inFlight != null) return inFlight;
    final future = _enable(
      media,
      initialBounds: initialBounds,
      requestPermission: requestPermission,
    );
    _enableInFlight = future;
    return future.whenComplete(() {
      if (identical(_enableInFlight, future)) _enableInFlight = null;
    });
  }

  Future<bool> _enable(
    MediaQueryData media, {
    Rect? initialBounds,
    bool requestPermission = true,
  }) async {
    if (!supported || _busy) return false;
    _busy = true;
    try {
      noteFullScreen(media);
      final permission = await isPermissionGranted();
      if (!permission) {
        // 冷启动同步不能自动拉起系统设置页；只有用户亲手拨开关时才请求。
        if (requestPermission) await openPermissionSettings();
        return false;
      }
      final fallback = initialBounds ?? Rect.fromLTWH(0, 0, 1, 1);
      final initial = _lastKnownBounds.isEmpty ? fallback : _lastKnownBounds;
      final sticky = _stickyWindow(initial);
      bounds.value = sticky;
      active.value = true;
      final ok =
          await _channel.invokeMethod<bool>('enter', _physicalArgs(initial)) ??
              false;
      if (!ok) {
        active.value = false;
        return false;
      }
      return true;
    } catch (_) {
      active.value = false;
      return false;
    } finally {
      _busy = false;
    }
  }

  /// 退出 APP 外悬浮模式（从 APP 内调用；悬浮通知里的“返回 APP”由原生触发）。
  Future<void> disable() async {
    if (!supported) return;
    active.value = false;
    _windowBounds = null;
    try {
      await _channel.invokeMethod<void>('exit');
    } catch (_) {}
  }

  Map<String, double> _physicalArgs(Rect rect) {
    final ratio = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    return {
      'left': rect.left * ratio,
      'top': rect.top * ratio,
      'width': rect.width * ratio,
      'height': rect.height * ratio,
    };
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method == 'modeChanged') {
      active.value = call.arguments == true;
    } else if (call.method == 'boundsChanged') {
      // 原生没有主动改 bounds 的需求，预留。
    }
    return null;
  }
}
