import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../floating/app_float_layer.dart';
import '../floating/float_bounds_registry.dart';
import 'external_overlay_controller.dart';

/// APP 外悬浮模式下的根内容。
///
/// 原生覆盖窗口只有“可见悬浮窗并集”那么大；这里把它当成一个取景框，
/// 内部仍按完整屏幕坐标布局 [AppFloatLayer]，再整体平移到取景框位置。
/// 这样悬浮窗的拖动、吸附、几何比例和 APP 内完全一致。
class ExternalFloatShell extends StatelessWidget {
  const ExternalFloatShell({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ExternalOverlayController.instance;
    // 原生服务被直接拉起（自动化测试/进程重建）时，主 APP 还没机会调用
    // enable；从隐式 view 反推一次全屏尺寸，保证还是全屏坐标系布局。
    if (controller.fullScreenSize.isEmpty) {
      final implicit = WidgetsBinding.instance.platformDispatcher.implicitView;
      if (implicit != null) {
        controller.noteFullScreen(MediaQueryData.fromView(implicit));
      }
    }
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller.bounds,
        controller.appliedBounds,
        controller.imeHeight,
      ]),
      builder: (context, _) {
        final bounds = controller.appliedBounds.value;
        final base = MediaQuery.of(context);
        // 正常从 APP 内进入时已经有全屏信息；极端情况（服务直接拉起引擎/
        // 进程重启）没有，就用当前 view 尺寸兜底，至少不会白屏。
        final fallback = controller.fullScreenSize.isEmpty;
        final screen = fallback ? base.size : controller.fullScreenSize;
        if (screen.isEmpty) return const SizedBox.shrink();
        final shifted = fallback ? Rect.zero : bounds;
        final shell = ClipRect(
          child: Stack(
            children: [
              Positioned(
                left: -shifted.left,
                top: -shifted.top,
                width: screen.width,
                height: screen.height,
                child: MediaQuery(
                  data: base.copyWith(
                    size: screen,
                    padding: controller.fullScreenPadding,
                    viewPadding: controller.fullScreenViewPadding,
                    systemGestureInsets: controller.systemGestureInsets,
                    // 原生量出来的键盘高度并入 viewInsets：覆盖窗口自己
                    // 不一定会把 IME insets 透传给 Flutter。
                    viewInsets: base.viewInsets.copyWith(
                      bottom: math.max(
                        base.viewInsets.bottom,
                        controller.imeHeight.value,
                      ),
                    ),
                  ),
                  child: const ScaffoldMessenger(
                    child: _ExternalRouteHost(
                      child: AppFloatLayer(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
        // 只让补帧计数器重建最外层的 Opacity，不要每 tick 都把整个
        // AppFloatLayer（含 AI 聊天窗 ListView）重建一遍——AI 流式输出时
        // 那会表现成悬浮窗内容一直闪、滚动位置乱跳。
        return ValueListenableBuilder<int>(
          valueListenable: controller.frameTick,
          builder: (context, tick, child) => Opacity(
            // 0.999 与 1.0 肉眼无差，但会让引擎重新 paint 一帧；这是把
            // 内容真正画到覆盖窗口 surface 上的关键（部分 ROM 只
            // scheduleFrame 不够，需要一个真实的绘制变更）。
            opacity: tick.isEven ? 1.0 : 0.999,
            child: child,
          ),
          child: shell,
        );
      },
    );
  }
}

/// 桌面覆盖窗里的 Navigator/Scaffold 宿主。
///
/// 外悬浮模式下 MaterialApp.builder 直接返回 [ExternalFloatShell]，外面那棵
/// Navigator 不在树上；容器文件管理的“更多/重命名/删除/新建”、图片查看、
/// 代码编辑器等全部依赖 `Navigator.of(context)` 和 `ScaffoldMessenger`，没有
/// 宿主时表现为“点了没反应/打开失败”。这里补一棵最小 Navigator，并在任何
/// 非根路由（底部菜单/对话框/查看页）打开时把原生覆盖窗临时撑到全屏，
/// 否则弹窗会被按悬浮窗并集裁掉一半。
class _ExternalRouteHost extends StatefulWidget {
  const _ExternalRouteHost({required this.child});

  final Widget child;

  @override
  State<_ExternalRouteHost> createState() => _ExternalRouteHostState();
}

class _ExternalRouteHostState extends State<_ExternalRouteHost> {
  static const String _modalBoundsId = 'external-modal';

  final ValueNotifier<bool> _modalOpen = ValueNotifier<bool>(false);
  late final NavigatorObserver _observer = _ModalRouteObserver(_modalOpen);
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    _modalOpen.addListener(_syncModalBounds);
  }

  @override
  void dispose() {
    _modalOpen.removeListener(_syncModalBounds);
    _modalOpen.dispose();
    FloatBoundsRegistry.remove(_modalBoundsId);
    super.dispose();
  }

  void _syncModalBounds() {
    final open = _modalOpen.value;
    if (open == _reported) return;
    _reported = open;
    final screen = ExternalOverlayController.instance.fullScreenSize;
    if (open && screen.width > 0 && screen.height > 0) {
      FloatBoundsRegistry.report(_modalBoundsId, Offset.zero & screen);
    } else {
      FloatBoundsRegistry.remove(_modalBoundsId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Navigator(
      observers: [_observer],
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false,
          body: widget.child,
        ),
      ),
    );
  }
}

class _ModalRouteObserver extends NavigatorObserver {
  _ModalRouteObserver(this.modalOpen);

  final ValueNotifier<bool> modalOpen;

  void _sync() {
    final next = navigator?.canPop() ?? false;
    if (modalOpen.value != next) modalOpen.value = next;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _sync();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _sync();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _sync();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _sync();
}
