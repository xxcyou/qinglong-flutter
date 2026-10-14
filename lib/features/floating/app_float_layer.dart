import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/float_stack.dart';
import '../ai/floating/ai_dock_overlay.dart';
import '../ai/floating/ai_dock_provider.dart';
import '../ai/providers/chat_provider.dart';
import '../browser/browser_engine.dart';
import '../browser/browser_host.dart';
import '../browser/browser_window.dart';
import '../external/external_overlay_controller.dart';

/// 全局悬浮窗层：AI 悬浮球/聊天窗 + 浏览器窗。
///
/// 正式版把它挂在 `MaterialApp.builder` 的路由层之上；预览版的外部悬浮窗
/// 也复用同一棵树，所以这里抽出来，保证内外功能完全一致、状态也共享同一份。
class AppFloatLayer extends ConsumerWidget {
  const AppFloatLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 监听会改变窗口几何的状态，让 bounds 上报及时更新。
    ref.watch(aiDockProvider);
    ref.watch(chatProvider);
    return AnimatedBuilder(
      animation: Listenable.merge([
        FloatStack.instance,
        BrowserWindow.instance,
        BrowserEngine.instance.visible,
      ]),
      builder: (context, _) {
        _reportBounds(context, ref);
        return Stack(
          children: [
            for (final id in FloatStack.instance.order)
              if (id == FloatStack.ai)
                const Positioned.fill(
                  key: ValueKey('float-ai'),
                  child: AiDockHost(),
                )
              else
                const Positioned.fill(
                  key: ValueKey('float-browser'),
                  child: BrowserHost(),
                ),
            // 悬浮球永远画在两个窗口之上：浏览器一最大化就盖住整块屏幕，
            // 气泡要是跟着聊天窗沉下去，用户就没有任何入口能把 AI 叫回来。
            const Positioned.fill(
              key: ValueKey('float-bubble'),
              child: AiBubbleHost(),
            ),
          ],
        );
      },
    );
  }

  void _reportBounds(BuildContext context, WidgetRef ref) {
    final media = MediaQuery.of(context);
    final rect = _visibleBounds(media, ref);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ExternalOverlayController.instance.noteBounds(rect);
    });
  }

  Rect _visibleBounds(MediaQueryData media, WidgetRef ref) {
    final size = media.size;
    final safeTop = media.padding.top;
    final safeBottom = media.padding.bottom;
    Rect? union;

    void add(Rect r) {
      if (r.isEmpty) return;
      union = union == null ? r : union!.expandToInclude(r);
    }

    final dock = ref.read(aiDockProvider);

    // 悬浮球。
    if (dock.visible) {
      const bubble = 56.0;
      final minY = safeTop + 8;
      final maxY = size.height - safeBottom - 110 - bubble;
      final left =
          (dock.dx * (size.width - bubble)).clamp(4.0, size.width - bubble - 4);
      var top =
          (minY + dock.dy * (maxY - minY)).clamp(minY, maxY < minY ? minY : maxY);
      final keyboard = media.viewInsets.bottom;
      if (dock.quickOpen && keyboard > 0) {
        final limit = size.height - keyboard - 8 - bubble;
        if (top > limit) top = limit < minY ? minY : limit;
      }
      add(Rect.fromLTWH(left, top, bubble, bubble));
      // 快问输入条/结果窗大致贴着悬浮球展开，给个宽松的包围盒，
      // 避免窗口被原生覆盖层裁掉；真正的精确 bounds 后续再细化。
      if (dock.quickOpen) {
        add(Rect.fromLTWH(4, top - 74, size.width - 8, 140));
      }
      if (dock.quickResults.isNotEmpty) {
        add(Rect.fromLTWH(4, safeTop + 8, size.width - 8, size.height * 0.5));
      }
    }

    // AI 聊天窗。
    if (dock.expanded) {
      final safeArea = EdgeInsets.only(
        left: 28,
        right: 28,
        top: safeTop + 6,
        bottom: safeBottom + 6,
      );
      final field = Size(
        size.width - safeArea.horizontal,
        size.height - safeArea.vertical,
      );
      final w = (dock.ww * field.width)
          .clamp(AiDockState.minW * field.width, field.width);
      final h = (dock.wh * field.height)
          .clamp(AiDockState.minH * field.height, field.height);
      var left = safeArea.left + dock.wx * field.width;
      var top = safeArea.top + dock.wy * field.height;
      final keyboard = media.viewInsets.bottom;
      if (keyboard > 0) {
        final limit = size.height - keyboard - 8 - h;
        if (top > limit) top = limit;
        if (top < safeArea.top) top = safeArea.top;
      }
      left = left.clamp(safeArea.left, size.width - safeArea.right - w);
      top = top.clamp(safeArea.top, size.height - safeArea.bottom - h);
      add(Rect.fromLTWH(left, top, w, h));
    }

    // 浏览器窗：把隐藏时的屏幕外矩形排除。
    if (BrowserEngine.instance.visible.value) {
      final win = BrowserWindow.instance.value;
      if (win.maximized) {
        add(Rect.fromLTWH(0, 0, size.width, size.height));
      } else {
        final gesture = media.systemGestureInsets;
        const keepOut = 26.0;
        final leftKeep = gesture.left > keepOut ? gesture.left : keepOut;
        final rightKeep = gesture.right > keepOut ? gesture.right : keepOut;
        final topKeep = safeTop + 4;
        final bottomInset =
            safeBottom > gesture.bottom ? safeBottom : gesture.bottom;
        final bottomKeep =
            (bottomInset > keepOut ? bottomInset : keepOut) + 4;
        final fieldLeft = leftKeep;
        final fieldTop = topKeep;
        final fieldW = (size.width - leftKeep - rightKeep).clamp(1.0, size.width);
        final fieldH =
            (size.height - topKeep - bottomKeep).clamp(1.0, size.height);
        final w = (win.w * fieldW).clamp(BrowserWindow.minW * fieldW, fieldW);
        final h = (win.h * fieldH).clamp(BrowserWindow.minH * fieldH, fieldH);
        var left = fieldLeft + win.x * fieldW;
        var top = fieldTop + win.y * fieldH;
        final keyboard = media.viewInsets.bottom;
        if (keyboard > 0) {
          final limit = size.height - keyboard - 6 - h;
          if (top > limit) top = limit;
          if (top < fieldTop) top = fieldTop;
        }
        left = left.clamp(fieldLeft, fieldLeft + fieldW - w);
        top = top.clamp(fieldTop, fieldTop + fieldH - h);
        add(Rect.fromLTWH(left, top, w, h));
      }
    }

    // 留一点余量给发光/阴影，避免光晕被覆盖窗口边缘切掉。
    return (union ?? Rect.fromLTWH(0, 0, 1, 1)).inflate(10);
  }
}
