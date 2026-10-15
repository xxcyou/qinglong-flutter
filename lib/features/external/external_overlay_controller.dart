import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../shared/float_stack.dart';

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

  /// 当前覆盖窗口是否为了让悬浮窗内的输入框弹键盘而临时获得焦点。
  bool _imeFocus = false;
  bool _imeFocusListenerAttached = false;

  /// 键盘弹出/收起动画期间，MediaQuery.viewInsets.bottom 每帧都在变；
  /// 如果每帧都把新的并集发给原生 updateViewLayout，原生窗口会跟着
  /// 键盘动画反复 relayout，动画看起来一卡一卡。这里在 insets 变化时
  /// 只缓存最新 bounds，等键盘稳定 220ms 后再一次性下发。
  bool _imeAnimating = false;
  Rect? _pendingImeBounds;

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

  /// 窗口缩小阈值（逻辑像素面积）；扩大立即生效，面积缩小超过该值才收回，
  /// 避免拖动时窗口每帧抖动，同时保证关掉悬浮窗后窗口能立刻缩回去。
  static const double _shrinkArea = 16 * 16;

  Timer? _boundsDebounce;
  Timer? _shrinkDebounce;
  Rect? _pendingShrink;
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
    if (_imeAnimating) {
      _pendingImeBounds = desired;
      return;
    }
    _applyBounds(desired);
  }

  /// 键盘动画开始/结束。结束（或停止变化 220ms）时，把动画期间缓存的
  /// 最终 bounds 一次性应用，避免动画过程中反复 relayout。
  void setImeAnimating(bool animating) {
    if (_imeAnimating == animating) return;
    _imeAnimating = animating;
    if (!animating) {
      final pending = _pendingImeBounds;
      _pendingImeBounds = null;
      if (pending != null) _applyBounds(pending);
    }
  }

  void _applyBounds(Rect desired) {
    final next = _stickyWindow(desired);
    if (next == bounds.value) return;
    bounds.value = next;
    if (active.value || armed.value) _scheduleNativeBoundsUpdate();
  }

  Rect _stickyWindow(Rect desired) {
    // 没有任何可见悬浮窗。外部模式下“AI 悬浮球开关”一定是开着的，
    // 悬浮球必然可见；这里收到空并集只可能是切 view 瞬间布局尚未完成。
    // 若立刻收成 1x1，之后首帧一旦因 ROM 原因迟到，悬浮球就彻底消失。
    // 所以外部模式下空并集直接保持当前窗口，等非空并集到来再正常更新。
    if (desired.isEmpty) {
      final current = _windowBounds;
      if (active.value && current != null && !current.isEmpty) {
        return current;
      }
      _cancelPendingShrink();
      _windowBounds = Rect.zero;
      return Rect.zero;
    }
    final current = _windowBounds;
    if (current == null || current.isEmpty) {
      _cancelPendingShrink();
      _windowBounds = desired;
      return desired;
    }
    // 不能直接用 Rect.contains 判断左下/右下边界：它是右/下开区间，
    // 悬浮球本身贴着旧窗口右下角时会被误判成“需要扩大”，于是窗口
    // 永远收不回去（关掉悬浮窗后那片区域还是挡桌面）。这里逐边比较。
    final needsGrow = desired.left < current.left ||
        desired.top < current.top ||
        desired.right > current.right ||
        desired.bottom > current.bottom;
    if (needsGrow) {
      _cancelPendingShrink();
      _windowBounds = current.expandToInclude(desired);
      return _windowBounds!;
    }
    // desired 已在 current 内：面积缩小得足够多才收回窗口。收窗口会重置
    // FlutterView 的尺寸并让所有悬浮层重新布局，所以加 200ms 防抖：
    // 关闭/缩放动画期间持续变化会不断重置定时器，等画面稳定后再一次性收回，
    // 既不会裁剪动画，也不会在拖动时抖动。
    final currentArea = current.width * current.height;
    final desiredArea = desired.width * desired.height;
    if (currentArea - desiredArea > _shrinkArea) {
      _pendingShrink = desired;
      _shrinkDebounce?.cancel();
      _shrinkDebounce = Timer(const Duration(milliseconds: 200), () {
        final target = _pendingShrink;
        _pendingShrink = null;
        _shrinkDebounce = null;
        if (target == null) return;
        // 注意：这里不能因为当前未 armed 就跳过——_windowBounds/bounds 是
        // 进入外部模式时复用的缓存，必须始终收到正确的小窗口，否则用户
        // 之后打开开关、退后台时又会用旧的大矩形。
        _windowBounds = target;
        bounds.value = target;
        if (active.value || armed.value) _scheduleNativeBoundsUpdate();
      });
      return current;
    }
    _cancelPendingShrink();
    return current;
  }

  void _cancelPendingShrink() {
    _pendingShrink = null;
    _shrinkDebounce?.cancel();
    _shrinkDebounce = null;
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
    _frameTickTimer?.cancel();
    _frameTickTimer = null;
    _cancelPendingShrink();
    _resetImeFocus();
    try {
      await _channel.invokeMethod<void>('disarm');
    } catch (_) {}
  }

  /// 覆盖窗口默认 FLAG_NOT_FOCUSABLE，不抢其他应用的输入法焦点；
  /// 只有悬浮窗里的输入框拿到 Dart 焦点时，才临时让原生窗口可聚焦并
  /// 主动 showSoftInput。焦点离开后立刻恢复不可聚焦，其他应用才能正常
  /// 点出输入法。
  void _attachImeFocusListener() {
    if (_imeFocusListenerAttached) return;
    _imeFocusListenerAttached = true;
    FocusManager.instance.addListener(_syncImeFocus);
  }

  void _detachImeFocusListener() {
    if (!_imeFocusListenerAttached) return;
    _imeFocusListenerAttached = false;
    FocusManager.instance.removeListener(_syncImeFocus);
  }

  bool _hasEditableFocus() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return false;
    final ctx = node.context;
    if (ctx == null) return false;
    return ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  void _syncImeFocus() {
    if (!active.value) return;
    final next = _hasEditableFocus();
    if (next) {
      // 输入框拿到焦点时强制把 AI 层置顶：键盘弹出/点按过程中如果
      // 别的悬浮层被误 raise，气泡会从聊天窗下面冒出来。
      FloatStack.instance.raise(FloatStack.ai);
    }
    if (next == _imeFocus) return;
    _imeFocus = next;
    try {
      _channel.invokeMethod<void>('setImeFocus', next);
    } catch (_) {}
  }

  void _resetImeFocus() {
    _imeFocus = false;
    _detachImeFocusListener();
    _imeAnimating = false;
    _pendingImeBounds = null;
    try {
      _channel.invokeMethod<void>('setImeFocus', false);
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
        _attachImeFocusListener();
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncImeFocus());
      } else {
        _frameTickTimer?.cancel();
        _frameTickTimer = null;
        _cancelPendingShrink();
        _resetImeFocus();
      }
    } else if (call.method == 'surfaceReady') {
      // 覆盖窗口的 surface 真正创建/重建完成，再补一轮帧。
      if (active.value) _pumpOverlayFrames();
    } else if (call.method == 'boundsChanged') {
      // 原生没有主动改 bounds 的需求，预留。
    } else if (call.method == 'imeReleased') {
      // 原生因 Home/点击其他应用/失焦主动释放了 IME；同步清掉 Dart 侧
      // 焦点状态，下次再点悬浮窗输入框才会重新走 setImeFocus(true)。
      _imeFocus = false;
      FocusManager.instance.primaryFocus?.unfocus();
    }
    return null;
  }
}
