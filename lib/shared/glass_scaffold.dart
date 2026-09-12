import 'package:flutter/material.dart';

import '../core/theme/component_effects.dart';
import '../core/theme/glass.dart';

/// 全站统一的页面骨架：全面屏（内容自己延伸到状态栏下）+ 玻璃标题条。
///
/// 取代各页面的 `Scaffold(appBar: AppBar(...))`：AppBar 会画一条不透明的
/// "额头"色块，玻璃背景就被切断了。这里改成把标题条浮在内容上方。
class GlassScaffold extends StatelessWidget {
  const GlassScaffold({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.leading,
    this.headerBottom,
    this.headerInline,
    this.floatingActionButton,
    this.bottomBar,
    this.showBack = false,
    this.bodyTopPadding = 8,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> actions;
  final Widget? leading;

  /// 标题条下面的附加内容（搜索框、筛选 chips 等）。
  final Widget? headerBottom;

  /// 与右上动作按钮挤在同一行的内容（通常是搜索框），省一整排高度。
  final Widget? headerInline;
  final Widget? floatingActionButton;

  /// 底部浮动操作条（批量选择等），会自动避开系统手势条。
  final Widget? bottomBar;
  final bool showBack;
  final double bodyTopPadding;

  @override
  Widget build(BuildContext context) {
    // 用 ModalRoute.canPop 而不是 Navigator.canPop：后者会随"当前是否有别的
    // 页面压在上面"变化，导致 IndexedStack 里的标签页在某次重建后错误地长出返回箭头。
    final canPop = showBack || (ModalRoute.of(context)?.canPop ?? false);
    return Scaffold(
      extendBody: true,
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      floatingActionButton: floatingActionButton,
      body: GlassBackdrop(
        child: Stack(
          children: [
            // 内容整体下移，避免被操作条盖住；操作条高度不固定，
            // 所以用一个测量后的 padding 占位。标题水印也交给它，
            // 好让水印落在操作条**下方**，不跟搜索框叠在一起。
            Positioned.fill(
              child: _BodyWithHeaderInset(
                watermark:
                    GlassTitleWatermark(title: title, subtitle: subtitle),
                header: GlassHeader(
                  actions: actions,
                  leading: leading ??
                      (canPop
                          ? IconButton(
                              tooltip: '返回',
                              onPressed: () => Navigator.of(context).maybePop(),
                              icon: const Icon(Icons.arrow_back, size: 21),
                            )
                          : null),
                  bottom: headerBottom,
                  inlineLeft: headerInline,
                ),
                extraTop: bodyTopPadding,
                child: body,
              ),
            ),
            if (bottomBar != null)
              Positioned(
                left: 10,
                right: 10,
                bottom: 10 + MediaQuery.paddingOf(context).bottom * 0.4,
                child: bottomBar!,
              ),
          ],
        ),
      ),
    );
  }
}

/// 用 Stack 叠标题条时，内容需要知道标题条到底多高。
/// 这里先渲染一次标题条测出高度，再给内容加相应的顶部内边距。
class _BodyWithHeaderInset extends StatefulWidget {
  const _BodyWithHeaderInset({
    required this.header,
    required this.child,
    required this.watermark,
    this.extraTop = 0,
  });

  final Widget header;
  final Widget child;

  /// 标题水印，画在内容底下、操作条下方。
  final Widget watermark;
  final double extraTop;

  @override
  State<_BodyWithHeaderInset> createState() => _BodyWithHeaderInsetState();
}

class _BodyWithHeaderInsetState extends State<_BodyWithHeaderInset> {
  double _headerHeight = 0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 水印在最底层：不吃布局空间、不拦手势，滑到顶部时从卡片缝隙透出来。
        Positioned(
          top: _headerHeight,
          left: 0,
          right: 0,
          child: widget.watermark,
        ),
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(
              top: _headerHeight + widget.extraTop,
            ),
            child: widget.child,
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _MeasureSize(
            onChange: (size) {
              if ((size.height - _headerHeight).abs() < 0.5) return;
              setState(() => _headerHeight = size.height);
            },
            child: widget.header,
          ),
        ),
      ],
    );
  }
}

class _MeasureSize extends StatefulWidget {
  const _MeasureSize({required this.onChange, required this.child});

  final ValueChanged<Size> onChange;
  final Widget child;

  @override
  State<_MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<_MeasureSize> {
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = _key.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) widget.onChange(box.size);
    });
    return SizedBox(key: _key, child: widget.child);
  }
}

/// 玻璃卡片：列表项统一用它，视觉与悬浮层一致。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.all(14),
    this.radius = 18,
    this.selected = false,
    this.accent,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool selected;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final br = BorderRadius.circular(radius);
    final card = Container(
      decoration: BoxDecoration(
        borderRadius: br,
        // 列表卡也要透：底下那三团流动的光斑要能从卡片里透出来，
        // 不然只有浮层是玻璃、列表还是一片实色板，风格是断的。
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            // 浅色下取纯白而不是 surface：surface 本身就接近背景色，
            // 半透明叠上去等于没画（实测卡内外只差 6 个灰阶）。
            (dark ? scheme.surface : Colors.white)
                .withValues(alpha: dark ? 0.46 : 0.78),
            (dark ? scheme.surface : Colors.white)
                .withValues(alpha: dark ? 0.28 : 0.56),
          ],
        ),
        border: Border.all(
          color: selected
              ? scheme.primary
              : (accent ?? Colors.white).withValues(
                  alpha: selected
                      ? 1
                      : accent != null
                          ? 0.42
                          : (dark ? 0.12 : 0.6),
                ),
          width: selected ? 1.4 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.22 : 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // 镜面反光：和 GlassPanel 同一套光向，卡片和浮层才像同一种材质。
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: Glass.sheen(scheme)),
              ),
            ),
          ),
          Material(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.35)
                : Colors.transparent,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(padding: padding, child: child),
            ),
          ),
        ],
      ),
    );
    return ComponentEffectsDecorator(
      type: 'card',
      radius: radius,
      child: card,
    );
  }
}

/// 分区小标题。
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
