import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../floating/app_float_layer.dart';
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
        controller.frameTick,
        controller.imeHeight,
      ]),
      builder: (context, _) {
        final bounds = controller.bounds.value;
        final tick = controller.frameTick.value;
        final base = MediaQuery.of(context);
        // 正常从 APP 内进入时已经有全屏信息；极端情况（服务直接拉起引擎/
        // 进程重启）没有，就用当前 view 尺寸兜底，至少不会白屏。
        final fallback = controller.fullScreenSize.isEmpty;
        final screen = fallback ? base.size : controller.fullScreenSize;
        if (screen.isEmpty) return const SizedBox.shrink();
        final shifted = fallback ? Rect.zero : bounds;
        return Opacity(
          // 0.999 与 1.0 肉眼无差，但会让引擎重新 paint 一帧；这是把内容
          // 真正画到覆盖窗口 surface 上的关键（部分 ROM 只 scheduleFrame
          // 不够，需要一个真实的绘制变更）。
          opacity: tick.isEven ? 1.0 : 0.999,
          child: ClipRect(
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
                    child: const AppFloatLayer(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
