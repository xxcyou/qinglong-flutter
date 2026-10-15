import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme_visual.dart';
import '../../shared/float_stack.dart';
import '../ai/floating/ai_dock_overlay.dart';
import '../ai/floating/ai_dock_provider.dart';
import '../ai/providers/chat_provider.dart';
import '../browser/browser_engine.dart';
import '../browser/browser_host.dart';
import '../browser/browser_window.dart';
import '../external/external_overlay_controller.dart';
import '../home/home_navigation_provider.dart';
import '../terminal/docker/ssh_floating_host.dart';
import '../terminal/floating_terminal.dart';
import 'attachment_float_host.dart';
import 'file_picker_float_host.dart';
import 'float_bounds_registry.dart';

/// 全局悬浮窗层：AI 悬浮球/聊天窗 + 浏览器窗。
///
/// 正式版把它挂在 `MaterialApp.builder` 的路由层之上；预览版的外部悬浮窗
/// 也复用同一棵树，所以这里抽出来，保证内外功能完全一致、状态也共享同一份。
class AppFloatLayer extends ConsumerWidget {
  const AppFloatLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 悬浮层不需要阴影：桌面覆盖窗是按并集裁剪的，阴影会被裁掉一截反而
    // 像一圈硬边；同时阴影余量会扩大覆盖窗口、吃掉桌面触摸。这里给悬浮层
    // 单独套一份 glassShadowOpacity=0 的主题，不影响 APP 其它菜单/面板。
    final baseTheme = Theme.of(context);
    final hasVisual = baseTheme.extension<ThemeVisual>() != null;
    final floatTheme = hasVisual
        ? baseTheme.copyWith(
            extensions: [
              for (final e in baseTheme.extensions.values)
                if (e is ThemeVisual)
                  e.copyWith(glassShadowOpacity: 0, glassShadowY: 0)
                else
                  e,
            ],
          )
        : baseTheme;

    // 只监听 z 序变化。浏览器/终端/AI 各自在自己的宿主里监听自己的几何，
    // 这样拖浏览器时不会整层重建，AI 悬浮球自然就不会跟着闪。
    return Theme(
      data: floatTheme,
      child: AnimatedBuilder(
        animation: FloatStack.instance,
        builder: (context, _) {
          return Stack(
            children: [
              // 单独的几何上报器：它自己监听几何变化，重建只影响自己。
              const Positioned.fill(
                key: ValueKey('float-bounds-reporter'),
                child: _FloatBoundsReporter(),
              ),
              // 所有独立悬浮窗按 FloatStack 顺序绘制：点到谁，谁置顶。
              // 终端/SSH/附件不再固定压在某一个宿主上，浏览器也不再“困在 AI 里”。
              for (final id in FloatStack.instance.order)
                if (id != FloatStack.attachment)
                  Positioned.fill(
                    key: ValueKey('float-$id'),
                    child: Listener(
                      // 必须 deferToChild：translucent 会让每个全屏 Listener
                      // 都进入 hit test，点 AI 输入框时浏览器/终端/SSH/附件
                      // 也一起 raise，AI 被挤下顶层，隐藏的气泡就会冒出来。
                      behavior: HitTestBehavior.deferToChild,
                      onPointerDown: (_) => FloatStack.instance.raise(id),
                      child: switch (id) {
                        FloatStack.ai => const AiDockHost(),
                        FloatStack.browser => const BrowserHost(),
                        FloatStack.terminal => const FloatingTerminalHost(),
                        FloatStack.ssh => const SshFloatingHostLayer(),
                        _ => const SizedBox.shrink(),
                      },
                    ),
                  ),
              // 悬浮球永远画在普通悬浮窗之上：浏览器一最大化就盖住整块屏幕，
              // 气泡要是跟着聊天窗沉下去，用户就没有任何入口能把 AI 叫回来。
              const Positioned.fill(
                key: ValueKey('float-bubble'),
                child: AiBubbleHost(),
              ),
              // 附件/图片预览：独立悬浮窗。
              const Positioned.fill(
                key: ValueKey('float-attachment'),
                child: AttachmentFloatHost(),
              ),
              // 文件/附件选择器：独立悬浮窗，最上层。
              const Positioned.fill(
                key: ValueKey('float-file-picker'),
                child: FilePickerFloatHost(),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 单独监听“会影响窗口并集”的状态，只重建这个零尺寸 widget，避免拖浏览器
/// 时整层 `AppFloatLayer` 重建导致 AI 悬浮球闪烁。
class _FloatBoundsReporter extends ConsumerStatefulWidget {
  const _FloatBoundsReporter();

  @override
  ConsumerState<_FloatBoundsReporter> createState() =>
      _FloatBoundsReporterState();
}

class _FloatBoundsReporterState extends ConsumerState<_FloatBoundsReporter> {
  /// 阴影/外发光留在窗口内的余量。越大阴影越完整，但透明区域也会
  /// 吃掉桌面触摸；这里取一个较小折中值。
  static const double _shadowMargin = 2.0;

  double _lastKeyboardInset = 0;
  Timer? _keyboardSettle;

  @override
  void dispose() {
    _keyboardSettle?.cancel();
    // 悬浮层被移除（例如切回 APP 前台）时，清掉动画中状态，避免
    // controller 一直停留在“键盘动画中”而丢后续 bounds。
    ExternalOverlayController.instance.setImeAnimating(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(aiDockProvider);
    ref.watch(chatProvider);
    // AI 页会隐藏球旁边的状态文字；切页时也要重算原生窗口并集。
    ref.watch(homeTabIndexProvider);
    return AnimatedBuilder(
      animation: Listenable.merge([
        BrowserWindow.instance,
        BrowserEngine.instance.visible,
        FloatBoundsRegistry.revision,
      ]),
      builder: (context, _) {
        final media = MediaQuery.of(context);
        // 键盘弹出/收起时 viewInsets 每帧都在变；通知 controller 先别把
        // 每帧的并集都 updateViewLayout 到原生窗口，否则原生窗口 relayout
        // 会和 IME 动画互相打架，键盘看起来一卡一卡往上挪。等 insets
        // 稳定 220ms 后，再一次性下发最终 bounds。
        final keyboard = media.viewInsets.bottom;
        if (keyboard != _lastKeyboardInset) {
          _lastKeyboardInset = keyboard;
          ExternalOverlayController.instance.setImeAnimating(true);
          _keyboardSettle?.cancel();
          _keyboardSettle = Timer(const Duration(milliseconds: 220), () {
            ExternalOverlayController.instance.setImeAnimating(false);
          });
        }
        final rect = _visibleBounds(media, ref);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ExternalOverlayController.instance.noteBounds(rect);
        });
        return const SizedBox.shrink();
      },
    );
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
      var top = (minY + dock.dy * (maxY - minY))
          .clamp(minY, maxY < minY ? minY : maxY);
      final keyboard = media.viewInsets.bottom;
      if (dock.quickOpen && keyboard > 0) {
        // 只在输入面板会被键盘盖住时才抬球，和 AiBubbleLayer 的计算一致。
        final inputBottom = top + (bubble + 44.0) / 2;
        final imeTop = size.height - keyboard - 8;
        final delta = inputBottom - imeTop;
        if (delta > 0) {
          final maxShift = top - minY;
          final shift = delta < maxShift ? delta : maxShift;
          top -= shift;
        }
      }
      // 收起贴边时球实际只有 44×44，按真实渲染矩形上报，避免多占触摸区。
      final onRight = left + bubble / 2 > size.width / 2;
      final docked = !dock.quickOpen &&
          !dock.expanded &&
          (dock.dx <= 0.03 || dock.dx >= 0.97);
      const dockedTabWidth = 44.0;
      const dockedTabHeight = 44.0;
      final renderLeft =
          docked ? (onRight ? size.width - dockedTabWidth - 2.0 : 2.0) : left;
      final renderTop = docked ? top + (bubble - dockedTabHeight) / 2 : top;
      add(Rect.fromLTWH(
        renderLeft,
        renderTop,
        docked ? dockedTabWidth : bubble,
        docked ? dockedTabHeight : bubble,
      ));

      // 球旁边的思考/工具文字：和 AiBubbleLayer 用完全相同的显示条件与
      // 几何。原生覆盖窗必须把它算进并集，否则桌面级只会露出一点点内容。
      // 没文字时返回 null，不额外占触摸区域。
      final onAiPage = ref.read(homeTabIndexProvider) == 2;
      final status = (dock.expanded || onAiPage || dock.quickOpen)
          ? ''
          : aiBubbleStatusText(ref.read(chatProvider));
      final labelRect = aiBubbleStatusLabelRect(
        size: size,
        left: renderLeft,
        top: renderTop,
        status: status,
      );
      if (labelRect != null) add(labelRect);

      // 快问输入条/结果窗大致贴着悬浮球展开，给个宽松的包围盒，
      // 避免窗口被原生覆盖层裁掉；真正的精确 bounds 后续再细化。
      if (dock.quickOpen) {
        add(Rect.fromLTWH(4, top - 74, size.width - 8, 140));
      }
    }

    // AI 聊天窗。几何和 AiDockOverlay 共用同一个函数，确保内外一致。
    if (dock.expanded) {
      final geometry = aiChatGeometry(media, dock);
      add(geometry.rect);
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
        final bottomKeep = (bottomInset > keepOut ? bottomInset : keepOut) + 4;
        final fieldLeft = leftKeep;
        final fieldTop = topKeep;
        final fieldW =
            (size.width - leftKeep - rightKeep).clamp(1.0, size.width);
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

    // 终端/SSH，以及 AI 快问结果窗 / ui_c 画布窗 / 提问窗等自己维护
    // 尺寸的窗口：它们通过 FloatBoundsReporter 上报真实全局矩形，这里
    // 直接并入并集，每个悬浮窗都不会被别的窗口大小限制/裁掉。
    add(FloatBoundsRegistry.union);

    // 没有可见悬浮窗时返回空矩形，让原生把覆盖窗口收成空/1x1，
    // 不再挡住桌面滑动。
    final visible = union;
    if (visible == null || visible.isEmpty) return Rect.zero;

    // 只留很小的阴影/外发光余量：原生窗口是矩形的，透明区域也会吃掉
    // 桌面触摸；余量太大时悬浮球旁边一大片区域会无法点击/滑动。
    return visible.inflate(_shadowMargin);
  }
}
