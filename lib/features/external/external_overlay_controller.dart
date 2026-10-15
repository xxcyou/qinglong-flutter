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

  static final ExternalOverlayController instance =
      ExternalOverlayController._();

  static const MethodChannel _channel =
      MethodChannel('qinglong/external_overlay');

  /// 是否处于 APP 外悬浮模式（系统覆盖窗口正在显示）。
  ///
  /// 它由原生在悬浮窗 view attach/detach 时通过 `modeChanged` 通知：
  /// APP 在前台时 active=false（悬浮层画在 APP 内），缩到后台后 active=true
  /// （同一个 engine 的 view 交给系统覆盖窗口，悬浮层继续画在桌面上）。
  final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// 用户是否开启“APP 外悬浮”（AI 悬浮球开关）。
  ///
  /// 开启后原生会先跑起前台服务但不挂 view；等 APP 真正退到后台，
  /// 再把 view 挂到系统覆盖窗口上，所以不会强制 APP 最小化/重启。
  final ValueNotifier<bool> armed = ValueNotifier<bool>(false);

  /// 当前上报给原生的窗口矩形（逻辑像素）。
  final ValueNotifier<Rect> bounds = ValueNotifier<Rect>(Rect.zero);

  /// 覆盖窗口切换后的补帧信号。
  ///
  /// 单引擎换 view 时，Dart 侧 `active=true` 已经重建了悬浮层，但部分
  /// ROM 上引擎不会主动把这一帧提交到新的 SurfaceView；结果窗口有了、
  /// 内容却是透明的。切换后连续几秒主动 scheduleFrame，并让 shell 改变
  /// 一个肉眼不可见的透明度属性，确保帧真的被画到新 surface 上。
  final ValueNotifier<int> frameTick = ValueNotifier<int>(0);

  Timer? _frameTickTimer;

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
  /// 扩张，内容缩回超过回差后才收缩；小幅拖动完全不碰原生窗口；
  /// 全部关闭时立即收成空窗口，不再占桌面触摸。
  Rect? _windowBounds;

  /// 缩小窗口时的回差；扩大立即生效，缩回超过该值才执行，避免抖动。
  static const double _shrinkSlack = 16;

  Timer? _boundsDebounce;
  Future<bool>? _enableInFlight;

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
    devicePixelRatio =
        media.devicePixelRatio <= 0 ? 1.0 : media.devicePixelRatio;
  }

  /// 由悬浮层在每一帧后上报可见窗口并集。
  ///
  /// 不管当前在前台还是后台都要缓存/上报：前台时原生服务已经在跑（准备态），
  /// 等退后台挂 view 的那一刻必须拿到同一份几何，悬浮球位置才不会跳。
  void noteBounds(Rect desired) {
    _lastKnownBounds = desired;
    final next = _stickyWindow(desired);
    if (next == bounds.value) return;
    bounds.value = next;
    if (active.value || armed.value) _scheduleNativeBoundsUpdate();
  }

  Rect _stickyWindow(Rect desired) {
    // 没有任何可见悬浮窗：立刻把原生窗口收成空窗口，别再占桌面触摸。
    if (desired.isEmpty) {
      _windowBounds = Rect.zero;
      return Rect.zero;
    }
    final current = _windowBounds;
    if (current == null || current.isEmpty) {
      _windowBounds = desired;
      return desired;
    }
    final needsGrow = !current.contains(desired.topLeft) ||
        !current.contains(desired.bottomRight);
    if (needsGrow) {
      _windowBounds = current.expandToInclude(desired);
      return _windowBounds!;
    }
    final canShrink = current.left <= desired.left - _shrinkSlack &&
        current.top <= desired.top - _shrinkSlack &&
        current.right >= desired.right + _shrinkSlack &&
        current.bottom >= desired.bottom + _shrinkSlack;
    if (canShrink) {
      _windowBounds = desired;
      return desired;
    }
    return current;
  }

  void _scheduleNativeBoundsUpdate() {
    _boundsDebounce?.cancel();
    _boundsDebounce = Timer(const Duration(milliseconds: 60), () {
      if (!active.value && !armed.value) return;
      final r = bounds.value;
      // 空窗口也要发给原生：否则关掉悬浮窗后旧的大窗口会一直占着触摸。
      _channel
          .invokeMethod<void>('updateBounds', _physicalArgs(r))
          .catchError((_) {});
    });
  }

  /// 开启“APP 外悬浮”能力（AI 悬浮球开关）。
  ///
  /// 只负责：检查系统权限、记录全屏尺寸、让原生起一个准备态前台服务。
  /// **不会** finish Activity，也不会立刻切到悬浮窗；等 APP 自己退到后台，
  /// 原生再 attach 覆盖窗口，悬浮层原位继续显示。
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
    if (!supported) return false;
    try {
      noteFullScreen(media);
      var permission = await isPermissionGranted();
      if (!permission && requestPermission) {
        // 只有用户亲手拨开关才拉起系统授权页；启动时静默同步不打扰。
        await openPermissionSettings();
        permission = await isPermissionGranted();
      }
      if (!permission) return false;
      final fallback = initialBounds ??
          (_lastKnownBounds.isEmpty
              ? Rect.fromLTWH(
                  media.size.width - 88,
                  media.size.height * 0.55,
                  72,
                  72,
                )
              : _lastKnownBounds);
      final sticky = _stickyWindow(fallback);
      bounds.value = sticky;
      final ok = await _channel.invokeMethod<bool>(
            'arm',
            _physicalArgs(sticky),
          ) ??
          false;
      if (!ok) return false;
      armed.value = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 启动时静默同步：如果用户上次开着 AI 悬浮球、系统权限也在，就直接
  /// 把准备态服务拉起来。权限没给就安静地留在 APP 内悬浮，不弹设置页。
  Future<bool> ensureArmed(MediaQueryData media) {
    return enable(media, requestPermission: false);
  }

  /// 关闭“APP 外悬浮”能力：飘在桌面上的覆盖窗口如果正在显示，先摘掉，
  /// 再停掉准备态服务；APP 内悬浮球是否隐藏由调用方决定。
  Future<void> disable() async {
    if (!supported) return;
    armed.value = false;
    active.value = false;
    _windowBounds = null;
    try {
      await _channel.invokeMethod<void>('disarm');
    } catch (_) {}
  }

  /// 切换前后连续补帧 3 秒：surface 创建时间不稳定，固定延时踢一次
  /// 可能落在 surface 就绪之前；持续 scheduleFrame 能覆盖大部分 ROM。
  void _pumpOverlayFrames() {
    _frameTickTimer?.cancel();
    void tick() {
      frameTick.value++;
      WidgetsBinding.instance.ensureVisualUpdate();
      WidgetsBinding.instance.scheduleFrame();
      WidgetsBinding.instance.platformDispatcher.scheduleFrame();
    }

    tick();
    const delays = <int>[80, 200, 450, 900, 1600, 2400];
    var index = 0;
    void scheduleNext() {
      if (index >= delays.length) return;
      _frameTickTimer = Timer(Duration(milliseconds: delays[index]), () {
        tick();
        index++;
        scheduleNext();
      });
    }

    scheduleNext();
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
      final next = call.arguments == true;
      active.value = next;
      if (next) {
        _pumpOverlayFrames();
      } else {
        _frameTickTimer?.cancel();
        _frameTickTimer = null;
      }
    } else if (call.method == 'surfaceReady') {
      // 覆盖窗口的 surface 真正创建/重建完成，再补一轮帧。
      if (active.value) _pumpOverlayFrames();
    } else if (call.method == 'boundsChanged') {
      // 原生没有主动改 bounds 的需求，预留。
    }
    return null;
  }
}
