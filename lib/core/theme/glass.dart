import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'theme_effects_controller.dart';
import 'theme_visual.dart';
import '../local_shell/proot_bridge.dart';

/// 液体玻璃视觉基元。
///
/// 统一三件事：背景模糊、半透明渐变填充、高光描边。
/// 全局所有悬浮层（菜单、AppBar、悬浮 AI、底部面板）都从这里取样式，
/// 避免各页面各写一套导致质感不一致。
class Glass {
  const Glass._();

  /// 常规模糊强度。
  ///
  /// 流动玻璃比"毛玻璃"更厚：模糊要压住背景细节，只留下颜色的流动感。
  static const double blur = 26;

  /// 强模糊（用于覆盖全屏内容的浮层）。
  static const double blurStrong = 38;

  static BorderRadius radius(double r) => BorderRadius.circular(r);

  /// 玻璃填充渐变：左上受光、右下沉底，中间留一段更透的"腰"。
  ///
  /// 三段而不是两段是刻意的：只有两个端点时整块面板像一张均匀的半透明纸，
  /// 中间收一下才有"一块有厚度的玻璃"的感觉，背景的色彩也能从腰部透出来。
  static Gradient fill(ColorScheme scheme, {double opacity = 1}) {
    final dark = scheme.brightness == Brightness.dark;
    final base = dark ? scheme.surfaceContainerHigh : Colors.white;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        base.withValues(alpha: (dark ? 0.52 : 0.80) * opacity),
        base.withValues(alpha: (dark ? 0.30 : 0.56) * opacity),
        base.withValues(alpha: (dark ? 0.40 : 0.70) * opacity),
      ],
      stops: const [0, 0.55, 1],
    );
  }

  /// 镜面光带：斜着划过左上角的一道白光，玻璃的"反光"就是它。
  ///
  /// 只覆盖前 45%，而且到中间就完全透明——铺满会变成一层白纱，
  /// 文字对比度立刻掉下去。
  static Gradient sheen(ColorScheme scheme, {double opacity = 1}) {
    final dark = scheme.brightness == Brightness.dark;
    return LinearGradient(
      begin: const Alignment(-1, -1.2),
      end: const Alignment(0.4, 0.9),
      colors: [
        Colors.white.withValues(alpha: (dark ? 0.16 : 0.42) * opacity),
        Colors.white.withValues(alpha: (dark ? 0.05 : 0.14) * opacity),
        Colors.white.withValues(alpha: 0),
      ],
      stops: const [0, 0.28, 0.62],
    );
  }

  /// 玻璃边缘高光。
  ///
  /// 上沿最亮（光从上面来），往下逐渐消失，下沿留一点环境色反光——
  /// 单色描边看起来是"贴纸"，渐变描边才像磨过的玻璃棱。
  static Border border(ColorScheme scheme, {double width = 1}) {
    final dark = scheme.brightness == Brightness.dark;
    return Border.all(
      width: width,
      color: dark
          ? Colors.white.withValues(alpha: 0.16)
          : Colors.white.withValues(alpha: 0.78),
    );
  }

  /// 棱边渐变（配合 [GlassPanel] 的内描边用）。
  static Gradient rim(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.white.withValues(alpha: dark ? 0.26 : 0.9),
        Colors.white.withValues(alpha: dark ? 0.06 : 0.28),
        scheme.primary.withValues(alpha: dark ? 0.12 : 0.10),
      ],
      stops: const [0, 0.5, 1],
    );
  }

  /// 浮起阴影，让玻璃真的"飘"在内容上。
  static List<BoxShadow> shadow(ColorScheme scheme, {double y = 8}) {
    final dark = scheme.brightness == Brightness.dark;
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.42 : 0.14),
        blurRadius: y * 2.2,
        offset: Offset(0, y),
      ),
      BoxShadow(
        color: scheme.primary.withValues(alpha: dark ? 0.10 : 0.06),
        blurRadius: y * 3,
        spreadRadius: -y,
      ),
    ];
  }
}

/// 一块液体玻璃。任何需要浮在内容之上的容器都用它包一层。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 18,
    this.blur = Glass.blur,
    this.padding,
    this.margin,
    this.opacity = 1,
    this.shadowY = 6,
    this.borderWidth = 1,
    this.tint,
    this.onTap,
    this.sheen = true,
    this.anchorIndex,
  });

  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double opacity;
  final double shadowY;
  final double borderWidth;

  /// 额外色调（例如错误态给一点红）。
  final Color? tint;
  final VoidCallback? onTap;

  /// 镜面反光。默认开；只有极小的药丸（一行字都放不下）才关掉，
  /// 那种尺寸上再叠一道光带只会显脏。
  final bool sheen;

  /// 组件锚点序号：主题包 JS 用 DSHTheme.queryComponents 查询组件位置时，
  /// 同一页同类型组件可以按这个序号区分（可传可不传）。
  final int? anchorIndex;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeEffectsController.instance,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final visual = Theme.of(context).extension<ThemeVisual>();
        final page = ModalRoute.of(context)?.settings.name ?? 'default';
        final style = ThemeEffectsController.instance
            .componentStyleFor(page, 'panel', anchorIndex ?? 0);
        final baseRadius = style?.radius ?? radius;
        final br = Glass.radius(baseRadius);
        final effectiveBlur = style?.liquid?.blur ??
            style?.blur ??
            (blur == Glass.blur && visual != null ? visual.glassBlur : blur);
        final effectiveShadowY =
            shadowY == 8 && visual != null ? visual.glassShadowY : shadowY;
        final effectiveBorderColor =
            style?.borderColor ?? visual?.borderColor ?? Colors.white;
        final liquidActive = style?.liquid != null;
        final borderExplicit = style?.borderWidth != null ||
            style?.borderColor != null ||
            style?.borderOpacity != null;
        final effectiveBorderOpacity = (liquidActive && !borderExplicit)
            ? 0.0
            : (style?.borderOpacity ??
                (style?.borderColor != null
                    ? 1.0
                    : (visual?.glassBorderOpacity ??
                        (scheme.brightness == Brightness.dark ? 0.16 : 0.78))));
        final effectiveBorderWidth = (liquidActive && !borderExplicit)
            ? 0.0
            : (style?.borderWidth ?? borderWidth);
        final effectiveShadowColor =
            style?.shadowColor ?? visual?.shadowColor ?? Colors.black;
        final effectiveShadowOpacity = style?.shadowOpacity ??
            (visual?.glassShadowOpacity ??
                (scheme.brightness == Brightness.dark ? 0.34 : 0.10));
        final effectiveShadowBlur =
            style?.shadowBlur ?? (effectiveShadowY * 2.2);
        final effectiveShadowOffsetY = style?.shadowOffsetY ?? effectiveShadowY;
        // 液体玻璃默认要透：主题没显式给 fillOpacity 时，自动压到半透明，
        // 否则原来的不透明 colors/纯色会把“液态”直接盖成一块实心板。
        final defaultLiquidFill = liquidActive ? 0.55 : null;
        final fillOpacity = style?.fillOpacity ?? defaultLiquidFill ?? opacity;
        final styleAngle = style?.gradientAngle ?? 135;
        Widget inner = tint == null
            ? _padded(child)
            : DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: br,
                  color: tint!.withValues(alpha: 0.10),
                ),
                child: _padded(child),
              );
        if (sheen) {
          inner = Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: br,
                      gradient: Glass.sheen(scheme, opacity: fillOpacity),
                    ),
                  ),
                ),
              ),
              inner,
            ],
          );
        }
        final List<Color> gradientColors = style?.gradientColors ?? [];
        final gradientAlpha = style?.fillOpacity ?? defaultLiquidFill;
        final effectiveGradientColors =
            gradientColors.isNotEmpty && gradientAlpha != null
                ? [
                    for (final c in gradientColors)
                      c.withValues(alpha: gradientAlpha)
                  ]
                : gradientColors;
        final solidColor = style?.color != null && liquidActive
            ? style!.color!.withValues(alpha: gradientAlpha ?? 0.55)
            : style?.color;
        final gradient = effectiveGradientColors.isNotEmpty
            ? LinearGradient(
                begin: Alignment(-math.cos(styleAngle * math.pi / 180),
                    -math.sin(styleAngle * math.pi / 180)),
                end: Alignment(math.cos(styleAngle * math.pi / 180),
                    math.sin(styleAngle * math.pi / 180)),
                colors: effectiveGradientColors.length >= 2
                    ? effectiveGradientColors
                    : [
                        effectiveGradientColors.first,
                        effectiveGradientColors.first
                      ],
              )
            : Glass.fill(scheme, opacity: fillOpacity);
        final hasInnerDecor = style != null &&
            (style.innerGlowColor != null ||
                style.innerGlowOpacity != null ||
                style.innerShadowColor != null ||
                style.innerShadowOpacity != null);
        Widget? bgLayer;
        if (style?.backgroundImage?.isNotEmpty == true) {
          final bgStyle = style!;
          bgLayer = Positioned.fill(
            child: IgnorePointer(
              child: FutureBuilder<String>(
                future: ThemeEffectsController.instance
                    .resolveImagePath(bgStyle.backgroundImage!),
                builder: (context, snap) {
                  final host = snap.data ?? '';
                  if (host.isEmpty) return const SizedBox.shrink();
                  final fit = bgStyle.backgroundImageFit;
                  final opacity =
                      (bgStyle.backgroundImageOpacity ?? 1).clamp(0.0, 1.0);
                  final boxFit = fit == 'fill'
                      ? BoxFit.fill
                      : fit == 'contain'
                          ? BoxFit.contain
                          : BoxFit.cover;
                  Widget img = Image.file(
                    File(host),
                    fit: boxFit,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  );
                  if (opacity < 1) {
                    img = Opacity(opacity: opacity, child: img);
                  }
                  return img;
                },
              ),
            ),
          );
        }
        final liquidGlass = style?.liquid;
        final contentChild =
            (hasInnerDecor || bgLayer != null || liquidGlass != null)
                ? Stack(
                    children: [
                      if (bgLayer != null) bgLayer,
                      if (liquidGlass != null)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: LiquidGlassOverlay(
                              liquid: liquidGlass,
                              cornerRadius: br.topLeft.x,
                            ),
                          ),
                        ),
                      if (hasInnerDecor)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: ThemeInnerDecorPainter(
                                style: style,
                                cornerRadius: br.topLeft.x,
                              ),
                            ),
                          ),
                        ),
                      inner,
                    ],
                  )
                : inner;
        Widget content = DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: br,
            color: solidColor,
            gradient: solidColor == null ? gradient : null,
            border: Border.all(
              width: effectiveBorderWidth,
              color: effectiveBorderColor.withValues(
                  alpha: effectiveBorderOpacity),
            ),
          ),
          child: contentChild,
        );

        if (onTap != null) {
          content = Stack(
            children: [
              content,
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(borderRadius: br, onTap: onTap),
                ),
              ),
            ],
          );
        }

        final glow = style?.glowColor != null
            ? [
                BoxShadow(
                  color: (style!.glowColor ?? Colors.transparent)
                      .withValues(alpha: style.glowOpacity ?? 0.6),
                  blurRadius: style.glowRadius ?? 12,
                  spreadRadius: 0,
                ),
              ]
            : const <BoxShadow>[];

        return ComponentAnchorTracker(
          type: 'panel',
          index: anchorIndex,
          child: Opacity(
            opacity: (style?.opacity ?? 1).clamp(0.0, 1.0),
            child: Container(
              margin: margin,
              decoration: BoxDecoration(
                borderRadius: br,
                boxShadow: [
                  BoxShadow(
                    color: effectiveShadowColor.withValues(
                        alpha: effectiveShadowOpacity),
                    blurRadius: effectiveShadowBlur,
                    offset: Offset(0, effectiveShadowOffsetY),
                  ),
                  BoxShadow(
                    color: scheme.primary.withValues(
                      alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.06,
                    ),
                    blurRadius: effectiveShadowY * 3,
                    spreadRadius: -effectiveShadowY,
                  ),
                  ...glow,
                ],
              ),
              child: ClipRRect(
                borderRadius: br,
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: effectiveBlur,
                    sigmaY: effectiveBlur,
                  ),
                  child: content,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _padded(Widget child) =>
      padding == null ? child : Padding(padding: padding!, child: child);
}

/// 顶部玻璃标题条：替代 AppBar，内容从状态栏下方开始，没有"额头"色块。
/// 页面顶部操作条：只有按钮，没有"额头"。
///
/// 早先这里是一整条不透明渐变色块 + 标题 + 副标题，占掉近 130px 的竖向空间，
/// 而且把玻璃背景切成两段。现在标题挪到背景水印（见 [GlassScaffold]），
/// 这里只留下返回键与右侧动作，整体透明、贴着状态栏，能省的空间全省下来。
class GlassHeader extends StatelessWidget {
  const GlassHeader({
    super.key,
    this.actions = const [],
    this.leading,
    this.bottom,
    this.inlineLeft,
  });

  final List<Widget> actions;
  final Widget? leading;
  final Widget? bottom;

  /// 与右侧动作按钮同一行的内容（通常是搜索框）。
  /// 塞进这一行而不是单独一排，能再省掉约 48px 的竖向空间。
  final Widget? inlineLeft;

  bool get _hasControls =>
      leading != null || actions.isNotEmpty || inlineLeft != null;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Padding(
      // 紧贴状态栏下沿，一像素都不留。
      padding: EdgeInsets.only(top: top, left: 4, right: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_hasControls)
            // 图标按钮默认 48×48 的点击区，一排下来白占一大截高度。
            // 收紧到 ~36：手指照样按得到，却把十几个像素还给内容。
            IconButtonTheme(
              data: IconButtonThemeData(
                style: IconButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(7),
                  minimumSize: const Size(34, 34),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              child: Row(
                children: [
                  if (leading != null) leading!,
                  if (inlineLeft != null)
                    Expanded(child: inlineLeft!)
                  else
                    const Spacer(),
                  ...actions,
                ],
              ),
            ),
          if (bottom != null) bottom!,
        ],
      ),
    );
  }
}

/// 页面标题水印：大字号、极低透明度，铺在内容后面。
///
/// "标题不要占地方"的落点——它在 [Stack] 的最底层，不吃布局空间、不拦手势，
/// 只在滑到顶部时透出来告诉你这是哪一页。
class GlassTitleWatermark extends StatelessWidget {
  const GlassTitleWatermark({
    super.key,
    required this.title,
    this.subtitle,
  });

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 40,
                height: 1.05,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: scheme.onSurface.withValues(alpha: 0.075),
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface.withValues(alpha: 0.09),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 玻璃小药丸按钮：图标 + 可选文字，用于头部动作与工具条。
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.icon,
    this.label,
    this.onTap,
    this.color,
    this.tooltip,
    this.dense = false,
    this.maxLabelWidth,
  });

  final IconData icon;
  final String? label;
  final VoidCallback? onTap;
  final Color? color;
  final String? tooltip;
  final bool dense;

  /// 标签最长能占多宽，超出就省略号。
  ///
  /// 从外面套 `ConstrainedBox` 是**没用的**：Row 给非弹性子节点的主轴约束是
  /// 无限宽，文字照样按原长排版，然后撑破外面那个框——屏幕上就是一条黄黑
  /// 警告斜线（模型名一长必现）。宽度必须夹在文字自己身上。
  final double? maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.onSurfaceVariant;
    final body = GlassPanel(
      radius: 18,
      blur: 12,
      shadowY: 2,
      // 药丸太小，再叠一道反光只会显脏。
      sheen: false,
      padding: EdgeInsets.symmetric(
        horizontal: label == null ? (dense ? 7 : 9) : 11,
        vertical: dense ? 5 : 7,
      ),
      onTap: onTap,
      tint: color,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: dense ? 14 : 16, color: tint),
          if (label != null) ...[
            const SizedBox(width: 5),
            _label(tint),
          ],
        ],
      ),
    );
    if (tooltip == null) return body;
    return Tooltip(message: tooltip!, child: body);
  }

  Widget _label(Color tint) {
    final text = Text(
      label!,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: dense ? 11.5 : 12.5,
        color: tint,
        fontWeight: FontWeight.w500,
      ),
    );
    final w = maxLabelWidth;
    if (w == null) return text;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: w),
      child: text,
    );
  }
}

/// 全局流动相位：驱动背景光斑缓缓漂移。
///
/// 这里有一条实测出来的硬约束：**空闲时一帧都不能画**。
/// 常驻 Ticker 的版本在 K50 上实测空闲占用 78%~99% 的单核（不挂 ticker 是 15%），
/// 原因不是重建 widget——相位冻结、什么都不变时照样这么高——而是只要有人请求帧，
/// 满屏十几个 BackdropFilter 就得重新栅格化一遍，这活儿没法缓存。
///
/// 所以改成**交互驱动**：手指按下 / 滑动 / 切页时 [nudge] 一下，相位随之流动，
/// 停手 1.6 秒后 ticker 自己停掉，空闲回到零帧。反正没人碰屏幕的时候，
/// 背景在动给谁看？而正在滑动的那些帧本来就要重画，动画是顺路搭车，几乎不加钱。
class GlassFlow {
  GlassFlow._();

  static final GlassFlow instance = GlassFlow._();

  /// 一圈 42 秒。快一点就成了屏保，慢一点用户觉察不到。
  static const Duration period = Duration(seconds: 42);

  /// 最后一次交互之后再漂多久。留一点余量，手指刚离开屏幕时不会"咔"地停住。
  static const Duration _coast = Duration(milliseconds: 1600);

  final ValueNotifier<double> phase = ValueNotifier<double>(0);

  Ticker? _ticker;
  Duration _last = Duration.zero;

  /// 相位累计值（秒）。用累计量而不是 ticker 的 elapsed：
  /// ticker 每次重启 elapsed 都从 0 开始，直接拿它算相位会每次都跳回原点。
  double _elapsedSeconds = 0;
  Duration _tickerBase = Duration.zero;
  Duration _stopAfter = Duration.zero;

  /// 有交互发生：让背景流动起来（已经在动就只是续命）。
  void nudge() {
    final t = _ticker;
    if (t == null) {
      _tickerBase = Duration.zero;
      _last = Duration.zero;
      _stopAfter = _coast;
      _ticker = Ticker(_onTick)..start();
      return;
    }
    // 已经在跑：把停止时间往后推。
    _stopAfter = _tickerBase + _coast;
  }

  /// 立刻停掉流动（测试收尾用）。
  ///
  /// 单测里 widget 树被 dispose 之后如果 ticker 还挂着，
  /// Flutter 会报 "An animation is still running after dispose" 直接判失败。
  @visibleForTesting
  void stopForTest() {
    _ticker?.dispose();
    _ticker = null;
    _stopAfter = Duration.zero;
  }

  void _onTick(Duration elapsed) {
    _tickerBase = elapsed;
    if (elapsed > _stopAfter) {
      _ticker?.dispose();
      _ticker = null;
      return;
    }
    // 节流到 ~20fps：光斑是几百像素的软渐变，每帧重画纯属浪费。
    if (elapsed - _last < const Duration(milliseconds: 50)) return;
    final dt = (elapsed - _last).inMilliseconds / 1000.0;
    _last = elapsed;
    _elapsedSeconds += dt;
    phase.value = (_elapsedSeconds % period.inSeconds) / period.inSeconds;
  }
}

/// 把用户的触摸/滚动转成 [GlassFlow.nudge]。
///
/// 挂在 APP 最外层一次就够，全站都有效。`translucent` + 只旁听 Listener：
/// 不参与手势竞技场，不会抢走任何页面的点击和滑动。
class GlassFlowDriver extends StatelessWidget {
  const GlassFlowDriver({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => GlassFlow.instance.nudge(),
      onPointerMove: (_) => GlassFlow.instance.nudge(),
      child: NotificationListener<ScrollNotification>(
        // 惯性滚动阶段手指已经离开屏幕了，靠指针事件收不到，
        // 但那时画面还在动，正是"流动"最该出现的时候。
        onNotification: (n) {
          if (n is ScrollUpdateNotification) GlassFlow.instance.nudge();
          return false;
        },
        child: child,
      ),
    );
  }
}

/// 页面背景：流动的光斑 + 渐变底，玻璃需要有东西可模糊才好看。
///
/// "流动玻璃"的流动就在这一层：三团色斑沿着不同周期的正弦轨迹慢慢漂，
/// 上面那些半透明面板一模糊，颜色就跟着缓缓变化。
/// 标记"这条祖先链上已经有人画过背景了"。
///
/// 没有它的时候整个 APP 会同时存在 **7 层** 背景：外壳一层，
/// IndexedStack 里六个标签页各自的 GlassScaffold 又各一层。
/// IndexedStack 用 `Visibility.maintain` 保活，离屏页照样 build/layout，
/// 于是光斑每跳一格（50ms）就有 7 层背景 + 21 个径向渐变一起重建重排——
/// 实测单帧 build 146ms，等于交互时只有 ~7fps。用户看到的就是
/// "菜单一闪一闪 / 点了没反应 / 长按菜单出不来"。
/// HTML 动态背景开关。为修复全屏透明 WebView 的 Input ANR，
/// 改用 Hybrid Composition 承载 WebView（透明背景不再走 Surface 模式）。
const _enableHtmlThemeBackground = true;

/// 标记“这条祖先链或 App 根上已经有全局背景了”。
/// 页面里的 GlassBackdrop 看到它就直接透传，不再为每个路由建 WebView。
class ThemeBackgroundScope extends InheritedWidget {
  const ThemeBackgroundScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeBackgroundScope>() !=
      null;

  @override
  bool updateShouldNotify(ThemeBackgroundScope oldWidget) => false;
}

/// 全局唯一背景层：渐变/图片/HTML 主题 + 流动光斑。
///
/// 放在 MaterialApp.builder 的 Stack 最底层、Navigator 之下所有页面共用，
/// 这样进入/退出二级页面时不会再创建或销毁 WebView，返回也就不会卡。
class ThemeBackgroundLayer extends StatelessWidget {
  const ThemeBackgroundLayer({super.key});

  @override
  Widget build(BuildContext context) => const _GlassBackgroundView();
}

class _GlassBackgroundView extends StatelessWidget {
  const _GlassBackgroundView();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final visual = Theme.of(context).extension<ThemeVisual>();
    final bgPath = visual?.config.backgroundImage ?? '';
    final gradientColors = visual == null
        ? (dark
            ? [
                const Color(0xFF0A1311),
                const Color(0xFF0F1115),
                const Color(0xFF0E1A24),
              ]
            : [
                const Color(0xFFD7E7DC),
                const Color(0xFFEDF3EC),
                const Color(0xFFD8E3F0),
              ])
        : [visual.gradientStart, visual.gradientCenter, visual.gradientEnd];
    final bgHtml = visual?.backgroundHtml ?? '';
    final Widget pureBackground = bgPath.isEmpty
        ? DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradientColors,
              ),
            ),
          )
        : FutureBuilder<String>(
            future: ProotBridge()
                .hostPath(path: bgPath, scope: 'shell')
                .then((host) => host)
                .catchError((_) => ''),
            builder: (context, snap) {
              final host = snap.data ?? '';
              if (host.isNotEmpty && File(host).existsSync()) {
                return Image.file(
                  File(host),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradientColors,
                      ),
                    ),
                  ),
                );
              }
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: gradientColors,
                  ),
                ),
              );
            },
          );
    final Widget background = bgHtml.isNotEmpty && _enableHtmlThemeBackground
        ? Stack(
            fit: StackFit.expand,
            children: [
              // 有 HTML 动态背景时以 WebView 为主背景，不再叠 Flutter 背景图，
              // 否则图片层会盖住 WebView 而导致 CSS/JS 效果看不见。
              const ColoredBox(color: Color(0xFF101014)),
              Positioned.fill(
                child: IgnorePointer(
                  child: _WebThemeBackground(htmlPath: bgHtml, active: true),
                ),
              ),
            ],
          )
        : pureBackground;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: background),
        // 光斑单独一层并且 RepaintBoundary 包住：它每 50ms 重画一次，
        // 不隔离的话整页内容会跟着一起重画。
        Positioned.fill(
          child: RepaintBoundary(
            child: IgnorePointer(child: _FlowingBlobs(scheme: scheme)),
          ),
        ),
      ],
    );
  }
}

class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 根上已经有全局背景（ThemeBackgroundLayer）了：直接透传。
    // 背景是全屏同一套渐变+光斑+HTML 特效，叠多层和叠一层长得一模一样，
    // 但每层都建 WebView 会让切页/返回变卡。
    if (ThemeBackgroundScope.of(context)) return child;
    return ThemeBackgroundScope(
      child: Stack(
        children: [
          const Positioned.fill(child: _GlassBackgroundView()),
          Positioned.fill(child: child),
          // 主题包 JS 通过 DSHTheme 发来的万能特效覆盖层：默认空，不挡点击。
          const Positioned.fill(child: ThemeEffectsOverlay()),
        ],
      ),
    );
  }
}

/// HTML/CSS/JS 动态主题背景。
///
/// 主题包里放了 index.html 时用它：WebView 全屏垫底，Flutter UI 保持透明
/// 浮在上面，CSS/JS/视频/粒子/落叶都能跑，而且纯色主题没有这个字段 = 不建
/// WebView，不浪费渲染空间。
class _WebThemeBackground extends StatefulWidget {
  const _WebThemeBackground({required this.htmlPath, required this.active});

  final String htmlPath;

  /// 当前页面是否是可见的“声音源”。非 active 的背景 WebView 继续保活，
  /// 但它发来的 effect/clear 等桥消息会被忽略，避免多层背景互相覆盖。
  final bool active;

  @override
  State<_WebThemeBackground> createState() => _WebThemeBackgroundState();
}

class _WebThemeBackgroundState extends State<_WebThemeBackground> {
  /// 预处理后的 HTML 缓存：同一个主题包 HTML 会被多个路由反复加载，
  /// 文件读取 + CSS/JS 注入 + 桥注入不再每次重做，能明显缩短二级页
  /// 打开时“等待玻璃效果”的空窗。
  static final Map<String, String> _preparedHtmlCache = {};

  late final WebViewController _controller;

  bool _htmlLoadStarted = false;
  bool _htmlLoaded = false;

  /// 只有本页真正接管全局浮层后才处理桥消息；路由切换动画期间仍先缓冲，
  /// 避免切页瞬间 clear + 大量重建把导航卡住。
  bool _effectOwner = false;

  /// 非 active（被覆盖）页面预加载时，桥消息不再直接写全局浮层，
  /// 先按 id 保留“最新状态”，等本页真正显示时一次性接管，达到秒开。
  final Map<String, Object?> _bufferedEffects = {};
  final Set<String> _bufferedRemoved = {};
  final List<Map<String, dynamic>> _bufferedStyles = [];
  final List<Map<String, dynamic>> _bufferedRemoveStyles = [];

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'DSHThemeBridge',
        onMessageReceived: _onBridgeMessage,
      );
    // 无论是否当前页都预加载 HTML/CSS/JS：打开二级页时 WebView 已就绪，
    // 只有等 active 后把缓冲的特效一次性落到全局，避免 3~6 秒空窗。
    // 启动放到首帧之后，避免 WebView 初始化/路由首帧抢同一帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void didUpdateWidget(covariant _WebThemeBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.htmlPath != widget.htmlPath) {
      // 主题切换：清掉旧缓冲，重新预加载新主题。
      _bufferedEffects.clear();
      _bufferedRemoved.clear();
      _bufferedStyles.clear();
      _bufferedRemoveStyles.clear();
      _htmlLoadStarted = false;
      _htmlLoaded = false;
      _effectOwner = false;
      _load();
    } else if (!oldWidget.active && widget.active) {
      // 页面从被覆盖变成可见：先等路由动画结束再接管，秒切不卡。
      _scheduleActivate();
    } else if (oldWidget.active && !widget.active) {
      _effectOwner = false;
    }
  }

  void _scheduleActivate() {
    if (!widget.active) return;
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    if (animation == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _activate();
      });
      return;
    }
    void onStatus(AnimationStatus status) {
      if (status != AnimationStatus.completed) return;
      animation.removeStatusListener(onStatus);
      if (mounted && widget.active) _activate();
    }

    if (animation.status == AnimationStatus.completed) {
      _activate();
    } else {
      animation.addStatusListener(onStatus);
    }
  }

  void _activate() {
    if (!widget.active || !_htmlLoaded || _effectOwner) return;
    _effectOwner = true;
    // 当前页重新接管前清掉上一页留下的覆盖层特效和组件风格。
    ThemeEffectsController.instance.clear();
    ThemeEffectsController.instance.clearComponentStyles();
    // 交互事件回传 WebView：主题 JS 用 DSHTheme.onEffect('tap', fn) 监听。
    ThemeEffectsController.instance.onEffectTap = (id) {
      try {
        _controller.runJavaScript(
          'window.DSHTheme && window.DSHTheme.__emitEffect('
          "'tap', {id: '$id'});",
        );
      } catch (_) {}
    };
    ThemeEffectsController.instance.onEffectLongPress = (id) {
      try {
        _controller.runJavaScript(
          'window.DSHTheme && window.DSHTheme.__emitEffect('
          "'longPress', {id: '$id'});",
        );
      } catch (_) {}
    };
    final pkg = RegExp(r'/packages/([^/]+)/').firstMatch(widget.htmlPath);
    ThemeEffectsController.instance.currentPackageId = pkg?.group(1);
    _flushBuffer();
  }

  Future<void> _load() async {
    if (_htmlLoadStarted) return;
    _htmlLoadStarted = true;
    try {
      final host =
          await ProotBridge().hostPath(path: widget.htmlPath, scope: 'shell');
      if (!mounted || host.isEmpty) return;
      String? preparedHtml;
      if (File(host).existsSync()) {
        final cached = _preparedHtmlCache[host];
        if (cached != null) {
          preparedHtml = cached;
        } else {
          preparedHtml = await _prepareHtml(host, widget.htmlPath);
          _preparedHtmlCache[host] = preparedHtml;
        }
      }
      final platform = _controller.platform;
      if (platform is AndroidWebViewController) {
        await platform.setAllowFileAccess(true);
        await platform.setAllowContentAccess(true);
        await platform.setMediaPlaybackRequiresUserGesture(false);
      }
      if (preparedHtml != null) {
        // 用 loadHtmlString + baseUrl 而不是直接 loadFile：相对路径的
        // css/js 由 WebView 按 html 目录解析，比 file:// 直读更稳。
        final base = Uri.file('${File(host).parent.path}/');
        await _controller.loadHtmlString(preparedHtml,
            baseUrl: base.toString());
      } else {
        await _controller.loadFile(host);
      }
      _htmlLoaded = true;
      // HTML 已就绪，但等路由动画完成后再接管，保证导航本身不卡。
      if (widget.active) _scheduleActivate();
    } catch (_) {
      // HTML 加载失败就留着纯色/渐变兜底，不炸 App。
    }
  }

  /// 非 active 页面：把 WebView 发来的最新状态先按 id 缓冲，不写全局。
  void _bufferBridgeMessage(Map<String, dynamic> data) {
    final cmd = data['cmd']?.toString() ?? '';
    switch (cmd) {
      case 'effect':
        final effect = data['effect'];
        if (effect is Map) {
          final id = effect['id']?.toString() ?? '';
          if (id.isNotEmpty) {
            _bufferedEffects[id] = effect;
            _bufferedRemoved.remove(id);
          }
        }
        break;
      case 'effectBatch':
        final list = data['effects'];
        if (list is List) {
          for (final item in list) {
            if (item is Map) {
              final id = item['id']?.toString() ?? '';
              if (id.isNotEmpty) {
                _bufferedEffects[id] = item;
                _bufferedRemoved.remove(id);
              }
            }
          }
        }
        break;
      case 'remove':
        final id = data['id']?.toString() ?? '';
        if (id.isNotEmpty) {
          _bufferedEffects.remove(id);
          _bufferedRemoved.add(id);
        }
        break;
      case 'clear':
        _bufferedEffects.clear();
        _bufferedRemoved.clear();
        break;
      case 'styleComponent':
        final opts = data['options'];
        if (opts is Map) _bufferedStyles.add(Map<String, dynamic>.from(opts));
        break;
      case 'removeComponentStyle':
        final opts = data['options'];
        if (opts is Map) {
          _bufferedRemoveStyles.add(Map<String, dynamic>.from(opts));
        }
        break;
      default:
        break;
    }
  }

  /// active 接管时把预加载期间缓冲的最新特效/样式落到全局。
  void _flushBuffer() {
    for (final raw in _bufferedRemoveStyles) {
      _handleRemoveComponentStyle(raw);
    }
    for (final raw in _bufferedStyles) {
      _handleStyleComponent(raw);
    }
    for (final id in _bufferedRemoved) {
      ThemeEffectsController.instance.remove(id);
    }
    for (final raw in _bufferedEffects.values) {
      _handleEffectMessage(raw);
    }
    _bufferedEffects.clear();
    _bufferedRemoved.clear();
    _bufferedStyles.clear();
    _bufferedRemoveStyles.clear();
  }

  static const _effectMinInterval = Duration(milliseconds: 16);

  final Map<String, DateTime> _lastEffectAt = {};

  /// 主题 JS 常见的动画写法是 requestAnimationFrame 里每帧对同一个 effect id
  /// 发一次更新（桂花、粒子）。直接每个消息 parse + notify 会打爆主线程。
  /// 这里同一个 id 至少隔 16ms 才真正解析一次，再配合
  /// [ThemeEffectsController.upsert] 的合批落盘，把 60fps 洪水降成按帧刷新。
  void _handleEffectMessage(Object? raw) {
    if (raw is! Map) return;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final now = DateTime.now();
    final last = _lastEffectAt[id];
    if (last != null && now.difference(last) < _effectMinInterval) return;
    _lastEffectAt[id] = now;
    final effect = ThemeEffectBridge.parseEffect(raw);
    if (effect != null) ThemeEffectsController.instance.upsert(effect);
  }

  Future<void> _onBridgeMessage(JavaScriptMessage message) async {
    final raw = message.message;
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    if (data == null) return;
    // 尚未真正接管浮层（路由动画中或 HTML 未加载完）：
    // 先缓冲最新状态，等 _activate 后再一次性落到全局。
    if (!_effectOwner) {
      _bufferBridgeMessage(data);
      return;
    }
    final cmd = data['cmd']?.toString() ?? '';
    switch (cmd) {
      case 'effect':
        _handleEffectMessage(data['effect']);
        break;
      case 'effectBatch':
        final list = data['effects'];
        if (list is List) {
          for (final item in list) {
            _handleEffectMessage(item);
          }
        }
        break;
      case 'remove':
        final id = data['id']?.toString() ?? '';
        if (id.isNotEmpty) ThemeEffectsController.instance.remove(id);
        break;
      case 'clear':
        ThemeEffectsController.instance.clear();
        ThemeEffectsController.instance.clearComponentStyles();
        break;
      case 'styleComponent':
        _handleStyleComponent(data['options']);
        break;
      case 'removeComponentStyle':
        _handleRemoveComponentStyle(data['options']);
        break;
      case 'queryComponents':
        final id = data['id']?.toString() ?? '0';
        final page = data['page']?.toString();
        final type = data['type']?.toString();
        final list = ThemeComponentRegistry.instance
            .query(page: page, type: type)
            .map((a) => a.toJson())
            .toList();
        try {
          await _controller.runJavaScript(
            'window.DSHTheme && window.DSHTheme.__componentResult('
            '$id, ${jsonEncode(list)});',
          );
        } catch (_) {}
        break;
    }
  }

  void _handleStyleComponent(Object? options) {
    if (options is! Map) return;
    final style = ThemeEffectBridge.parseComponentStyle(options);
    if (style == null) return;
    final page = options['page']?.toString();
    final type = options['type']?.toString();
    final rawIndex = options['index'];
    final pageFilter = page == null || page == '*' ? null : page;
    final typeFilter = type == null || type == '*' ? null : type;
    final anchors = ThemeComponentRegistry.instance
        .query(page: pageFilter, type: typeFilter);
    final index = rawIndex is num ? rawIndex.toInt() : null;
    // 先把规则存成“可作用于未来组件”的通配样式：主题 JS 通常在 HTML 加载完
    // 就 style 一次，而 ListView 里很多卡片还没 build；不存规则的话，后面
    // 滚动出来的卡片永远拿不到玻璃效果。
    ThemeEffectsController.instance.storeComponentStyle(
      page: page,
      type: type,
      index: index,
      style: style,
    );
    for (final a in anchors) {
      if (index != null && a.index != index) continue;
      ThemeEffectsController.instance.applyComponentStyle(
        page: a.page,
        type: a.type,
        index: a.index,
        style: style,
      );
    }
  }

  void _handleRemoveComponentStyle(Object? options) {
    if (options is! Map) return;
    final page = options['page']?.toString();
    final type = options['type']?.toString();
    final rawIndex = options['index'];
    final index = rawIndex is num ? rawIndex.toInt() : null;
    ThemeEffectsController.instance.removeStoredComponentStyle(
      page: page,
      type: type,
      index: index,
    );
    final pageFilter = page == null || page == '*' ? null : page;
    final typeFilter = type == null || type == '*' ? null : type;
    final anchors = ThemeComponentRegistry.instance
        .query(page: pageFilter, type: typeFilter);
    for (final a in anchors) {
      if (index != null && a.index != index) continue;
      ThemeEffectsController.instance
          .removeComponentStyle(a.page, a.type, a.index);
    }
  }

  /// 自动把主题包里的 css/js 注入 html，并对 controller.js 里声明的
  /// 背景图片做一次 file:// 映射，否则 AI 生成的 html 经常光有 div/canvas、
  /// 忘了引 css/js，效果只剩换色。
  Future<String> _prepareHtml(String hostHtmlPath, String guestHtmlPath) async {
    final htmlFile = File(hostHtmlPath);
    var html = await htmlFile.readAsString();
    final htmlDir = htmlFile.parent;
    final packageRoot = Directory(htmlDir.parent.path);
    if (!packageRoot.existsSync()) return html;
    final guestPackageRoot = File(guestHtmlPath).parent.parent.path;

    // 只有已注入正确的 ../css/ 才跳过；旧的 css/（相对 html 目录）是
    // WebView 读不到的错误路径，不能当作已注入。
    final hasCssLink = html.contains('href="../css/') ||
        html.contains('href=\'../css/\'') ||
        html.contains('href="../styles/') ||
        html.contains('href=\'../styles/\'');
    final hasScriptTag = html.contains('<script src') &&
        (html.contains('../js/') || html.contains('../scripts/'));

    final styleOverride = await _backgroundImageOverride(packageRoot);
    final headParts = StringBuffer();
    if (!hasCssLink) {
      for (final dirName in ['css', 'styles']) {
        final dir = Directory('${packageRoot.path}/$dirName');
        if (!dir.existsSync()) continue;
        for (final f in dir.listSync().whereType<File>()) {
          if (!f.path.endsWith('.css')) continue;
          final name = f.uri.pathSegments.last;
          // html/index.html 在 html/ 目录里，标准主题包 css/ 是它的兄弟目录，
          // 所以要用 ../css/ 而不是 css/，否则 WebView 会去 html/css/ 找文件。
          final ref = '../$dirName/$name';
          if (html.contains('href="$ref"') || html.contains('href=\'$ref\'')) {
            continue;
          }
          headParts.writeln('<link rel="stylesheet" href="$ref">');
        }
      }
    }
    if (styleOverride != null && !html.contains('data-dsh-theme-bg')) {
      headParts.writeln(styleOverride);
    }
    // 万能主题桥：主题包 JS 用 window.DSHTheme 让 Flutter 在组件上方
    // 绘制图片/文字/气泡/动画等特效，并可查询组件真实坐标。
    // 必须先于主题 JS 注入，否则 background.js 首次执行时 DSHTheme 还没定义。
    if (!html.contains('data-dsh-theme-bridge')) {
      final guestPackageJs = guestPackageRoot.replaceAll('\\', '/');
      final bridge = '''
<script data-dsh-theme-bridge>
(function () {
  if (window.DSHTheme && window.DSHTheme.__dsh) return;

  // App 侧性能看门狗：不修改主题包文件，只在注入时对每个主题生效。
  // 1) HTML 动画使用 WebView 原生 rAF，不限制帧率，让高刷屏跑满设备刷新率；
  // 2) DSHTheme.effect / effectBatch 在 JS 侧合并最新值后批量发送，减少桥消息量；
  // 3) 主题自带的 document 点击/触摸监听保留，允许主题自身处理互动。
  var oldRaf = window.requestAnimationFrame && window.requestAnimationFrame.bind(window);
  var oldCaf = window.cancelAnimationFrame && window.cancelAnimationFrame.bind(window);
  window.requestAnimationFrame = function (cb) {
    var now = typeof performance !== 'undefined' ? performance.now() : Date.now();
    // 不节流：直接交给 WebView 原生 rAF，由系统/设备刷新率决定实际帧率。
    return oldRaf ? oldRaf(cb) : setTimeout(function () { cb(now); }, 16);
  };
  window.cancelAnimationFrame = function (id) {
    if (typeof id === 'number') clearTimeout(id);
    if (oldCaf) oldCaf(id);
  };

  window.DSH_PACKAGE_ROOT = '$guestPackageJs';
  window.__dshCallbacks = window.__dshCallbacks || {};
  function post(msg) {
    try { DSHThemeBridge.postMessage(JSON.stringify(msg)); } catch (e) {}
  }
  // 特效几何信息：Flutter 手势 tap 需要转发回 WebView document 时，
  // 用这个矩形中心生成合成事件，让主题自己的命中检测照常工作。
  var effectGeometries = {};

  // 特效更新合并队列：同一帧内同一个 id 只保留最新状态，每 ~16ms
  // 批量发给 Flutter。相比“掉了不给”的节流，这是“合并最新值”，
  // 动画再频繁也不会丢最终位置，且桥消息量被压缩到每帧一条 batch。
  var effectLatest = {};
  var effectDirty = {};
  var effectFlushTimer = null;
  var effectFlushMs = 16;

  function rememberEffect(e) {
    if (e && e.id) {
      effectGeometries[e.id] = {
        x: e.x || 0, y: e.y || 0,
        w: e.width || 0, h: e.height || 0
      };
    }
    return e;
  }

  function scheduleEffectFlush() {
    if (effectFlushTimer !== null) return;
    effectFlushTimer = setTimeout(function () {
      effectFlushTimer = null;
      var ids = Object.keys(effectDirty);
      if (!ids.length) return;
      var effects = [];
      for (var i = 0; i < ids.length; i++) {
        var id = ids[i];
        if (!effectLatest[id]) continue;
        effects.push(forceBackgroundEffect(effectLatest[id]));
      }
      effectDirty = {};
      post({ cmd: 'effectBatch', effects: effects });
    }, effectFlushMs);
  }

  function queueEffect(e) {
    rememberEffect(e);
    if (!e || !e.id) return;
    effectLatest[e.id] = e;
    effectDirty[e.id] = true;
    scheduleEffectFlush();
  }

  function forceBackgroundEffect(e) {
    // 特效层保持主题原样：动画 + interactive 都保留。
    // 通用接口不针对任何固定主题做特判。
    return e;
  }

  function removeEffect(id) {
    if (!id) return;
    delete effectLatest[id];
    delete effectDirty[id];
    delete effectGeometries[id];
    post({ cmd: 'remove', id: id });
  }

  function clearEffects() {
    effectLatest = {};
    effectDirty = {};
    effectGeometries = {};
    if (effectFlushTimer !== null) {
      clearTimeout(effectFlushTimer);
      effectFlushTimer = null;
    }
    post({ cmd: 'clear' });
  }
  window.DSHTheme = {
    __dsh: true,
    effect: queueEffect,
    effectBatch: function (effects) {
      if (Object.prototype.toString.call(effects) === '[object Array]') {
        for (var i = 0; i < effects.length; i++) queueEffect(effects[i]);
      }
    },
    remove: removeEffect,
    clear: clearEffects,
    styleComponent: function (options) { post({ cmd: 'styleComponent', options: options || {} }); },
    removeComponentStyle: function (options) {
      post({ cmd: 'removeComponentStyle', options: options || {} });
    },
    onEffect: function (type, handler) {
      window.__dshEffectListeners = window.__dshEffectListeners || {};
      window.__dshEffectListeners[type] = handler;
    },
    __emitEffect: function (type, data) {
      var h = (window.__dshEffectListeners || {})[type];
      if (typeof h === 'function') h(data || {});
      // 通用桥接：Flutter 浮层手势吃到点击后，WebView 的 document 监听
      // 收不到原生事件。这里按特效几何中心生成合成 pointerdown/click，
      // 使主题的 document 命中检测（气泡/按钮等）保持可用。
      if (type === 'tap' && data && data.id && effectGeometries[data.id]) {
        var r = effectGeometries[data.id];
        var cx = r.x + r.w / 2;
        var cy = r.y + r.h / 2;
        var opts = { clientX: cx, clientY: cy, bubbles: true, cancelable: true };
        try {
          if (window.PointerEvent) {
            document.dispatchEvent(new PointerEvent('pointerdown', opts));
          } else {
            document.dispatchEvent(new MouseEvent('mousedown', opts));
          }
        } catch (e) {}
        try {
          document.dispatchEvent(new MouseEvent('mousedown', opts));
          document.dispatchEvent(new MouseEvent('click', opts));
        } catch (e) {}
      }
    },
    queryComponents: function (opts) {
      opts = opts || {};
      window.__dshQid = (window.__dshQid || 0) + 1;
      var id = window.__dshQid;
      window.__dshCallbacks[id] = opts.callback || null;
      post({ cmd: 'queryComponents', id: id, page: opts.page, type: opts.type });
    },
    __componentResult: function (id, list) {
      var cb = window.__dshCallbacks[id];
      if (typeof cb === 'function') cb(list);
      delete window.__dshCallbacks[id];
    }
  };
})();
</script>
''';
      // 桥必须插在**所有主题脚本之前**：html 里手工写的 <script src=...> 可能
      // 已经在尾部了，往 </body> 前插桥仍然晚于这些脚本，它们执行时
      // DSHTheme 还没定义，只能静默 return（流星/气泡等特效直接消失）。
      final bodyStart = html.indexOf('<body');
      final bodyTagEnd = bodyStart >= 0 ? html.indexOf('>', bodyStart) : -1;
      final bodyEnd = html.lastIndexOf('</body>');
      if (bodyTagEnd >= 0) {
        html = html.replaceRange(
          bodyTagEnd + 1,
          bodyTagEnd + 1,
          '\n$bridge\n',
        );
      } else if (bodyEnd >= 0) {
        html = html.replaceFirst('</body>', '$bridge</body>');
      } else {
        html = '$html$bridge';
      }
    }

    // 脚本统一放到 </body> 前，避免阻塞渲染。
    if (!hasScriptTag) {
      final scriptParts = StringBuffer();
      for (final dirName in ['js', 'scripts']) {
        final dir = Directory('${packageRoot.path}/$dirName');
        if (!dir.existsSync()) continue;
        for (final f in dir.listSync().whereType<File>()) {
          if (!f.path.endsWith('.js')) continue;
          final name = f.uri.pathSegments.last;
          // 和 css 同理，html 在 html/ 子目录，脚本是兄弟目录 ../js/。
          final ref = '../$dirName/$name';
          if (html.contains('src="$ref"')) continue;
          scriptParts.writeln('<script src="$ref"></script>');
        }
      }
      final scriptText = scriptParts.toString();
      if (scriptText.isNotEmpty) {
        final bodyEnd = html.lastIndexOf('</body>');
        if (bodyEnd >= 0) {
          html = html.replaceFirst(
            '</body>',
            '$scriptText</body>',
          );
        } else {
          html = '$html$scriptText';
        }
      }
    }

    if (headParts.isNotEmpty) {
      final headPartsText = headParts.toString();
      final headEnd = html.indexOf('</head>');
      if (headEnd >= 0) {
        html = html.replaceFirst('</head>', '$headPartsText</head>');
      } else {
        html = '$headPartsText$html';
      }
    }
    return html;
  }

  /// 从 controller.js 读 backgroundImage，把 guest 路径映射成宿主绝对
  /// file:// URL，并整段写进 style（不影响原 css 文件内容）。
  Future<String?> _backgroundImageOverride(Directory packageRoot) async {
    final controllerPath = '${packageRoot.path}/controller.js';
    if (!File(controllerPath).existsSync()) return null;
    try {
      final text = await File(controllerPath).readAsString();
      final match = RegExp(
        r'''backgroundImage\s*:\s*['"]([^'"]+)['"]''',
      ).firstMatch(text);
      final guest = match?.group(1);
      if (guest == null || guest.isEmpty) return null;
      final host = await ProotBridge().hostPath(path: guest, scope: 'shell');
      if (host.isEmpty) return null;
      final fileUrl = Uri.file(host).toString();
      return '<style data-dsh-theme-bg>'
          '#sakura-bg{background-image:url("$fileUrl")!important}'
          '</style>';
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 保持默认 Surface 渲染。早期怀疑需要 Hybrid Composition，但在当前
    // Android 上 Hybrid 反而会触发 FocusEvent ANR；rAF 已不做帧率限制，
    // effect/effectBatch 只在 JS 侧合并批量发送，Surface 模式全屏动态背景稳定。
    return WebViewWidget(controller: _controller);
  }
}

/// 三团慢慢漂的色斑。
class _FlowingBlobs extends StatelessWidget {
  const _FlowingBlobs({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    // 离屏的标签页不订阅相位：IndexedStack 用 Visibility.maintain 保活，
    // 六个页面都还在树上，不掐断的话光斑每跳一格就把六页背景全重建一遍。
    if (!TickerMode.of(context)) return const SizedBox.expand();
    return ValueListenableBuilder<double>(
      valueListenable: GlassFlow.instance.phase,
      builder: (context, t, _) {
        final dark = scheme.brightness == Brightness.dark;
        return LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final h = box.maxHeight;
            // 三条不同周期的轨迹（1 圈 / 1.3 圈 / 0.7 圈）：周期互质才不会
            // 三团一起同步来回，那样看起来像整块画面在平移而不是"流动"。
            final a = 2 * math.pi * t;
            final blobs = <_BlobSpec>[
              _BlobSpec(
                color: scheme.primary,
                size: w * 0.85,
                dx: w * (0.62 + 0.16 * math.sin(a)),
                dy: h * (0.06 + 0.10 * math.cos(a * 1.1)),
                alpha: dark ? 0.30 : 0.42,
              ),
              _BlobSpec(
                color: scheme.tertiary,
                size: w * 0.72,
                dx: w * (0.10 + 0.18 * math.cos(a * 1.3)),
                dy: h * (0.66 + 0.12 * math.sin(a * 1.3)),
                alpha: dark ? 0.26 : 0.36,
              ),
              _BlobSpec(
                color: scheme.secondary,
                size: w * 0.6,
                dx: w * (0.42 + 0.22 * math.sin(a * 0.7 + 1.2)),
                dy: h * (0.38 + 0.16 * math.cos(a * 0.7)),
                alpha: dark ? 0.16 : 0.22,
              ),
            ];
            return Stack(
              children: [
                for (final b in blobs)
                  Positioned(
                    left: b.dx - b.size / 2,
                    top: b.dy - b.size / 2,
                    child: _Blob(
                      color: b.color,
                      size: b.size,
                      alpha: b.alpha,
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _BlobSpec {
  const _BlobSpec({
    required this.color,
    required this.size,
    required this.dx,
    required this.dy,
    required this.alpha,
  });

  final Color color;
  final double size;
  final double dx;
  final double dy;
  final double alpha;
}

class _Blob extends StatelessWidget {
  const _Blob({required this.color, required this.size, this.alpha = 0.28});

  final Color color;
  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: alpha * 0.45),
              color.withValues(alpha: 0.0),
            ],
            stops: const [0, 0.45, 1],
          ),
        ),
      ),
    );
  }
}

/// 聊天流里所有"信息卡片"的统一外观：左侧一条彩色脊、圆角 16、
/// 半透明底色 + 细描边。比原来的实心灰块干净得多，也和玻璃风格对得上。
class InfoCardShell extends StatelessWidget {
  const InfoCardShell({
    super.key,
    required this.child,
    required this.accent,
    this.margin = const EdgeInsets.only(bottom: 8),
  });

  final Widget child;
  final Color accent;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        // 透一点：聊天流里这种卡一排十几张，做成实色就是一堵砖墙。
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.surfaceContainerLow.withValues(alpha: 0.62),
            scheme.surfaceContainerLow.withValues(alpha: 0.44),
          ],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.30)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: scheme.brightness == Brightness.dark ? 0.2 : 0.05,
            ),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      // 左侧彩色脊用 Stack + 上下拉伸的 Positioned，**不能**用
      // Row(crossAxisAlignment: stretch)：这张卡活在 ListView 里，
      // 纵向约束是无限的，stretch 会给脊条一个无限高度，
      // 整页布局直接抛异常、白屏（AI 页就这么黑过一次）。
      child: Stack(
        children: [
          // 内容整体右移 3：正好让开脊条，不被它压住文字。
          Padding(padding: const EdgeInsets.only(left: 3), child: child),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 3,
            child: ColoredBox(color: accent.withValues(alpha: 0.75)),
          ),
        ],
      ),
    );
  }
}

/// 卡片左上角的圆角图标底座。
class InfoCardBadge extends StatelessWidget {
  const InfoCardBadge({super.key, required this.child, required this.color});

  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}
