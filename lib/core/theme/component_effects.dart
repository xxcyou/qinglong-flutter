import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme_visual.dart';

/// 组件级特效：AI 在 controller.js 的 `componentEffects` 数组里声明。
///
/// 目前支持：
/// - 匹配：all / type / page / index（index 暂由使用方显式传入）
/// - 边框整体发光、四角/单角局部发光
/// - 角标图标挂件
/// - 静态浮动偏移（后续接入动画帧）
class ComponentEffect {
  const ComponentEffect({
    this.page,
    this.type,
    this.index,
    this.all = false,
    this.border,
    this.corner,
    this.float,
  });

  /// 匹配的页面标识（如 home / chat / settings），缺省匹配任意页。
  final String? page;

  /// 匹配的组件类型（panel / card / input / list / chip ...），缺省匹配任意类型。
  final String? type;

  /// 匹配第几个同类型组件（1 起），缺省匹配任意序号。
  final int? index;

  /// 是否匹配所有组件（与 type/index 互斥时优先）。
  final bool all;

  final ComponentBorderEffect? border;
  final ComponentCornerEffect? corner;
  final ComponentFloatEffect? float;

  factory ComponentEffect.fromMap(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : null;
    if (map == null) return const ComponentEffect();
    return ComponentEffect(
      page: map['page']?.toString(),
      type: map['type']?.toString(),
      index: (map['index'] as num?)?.toInt(),
      all: map['all'] == true,
      border: map['border'] == null
          ? null
          : ComponentBorderEffect.fromMap(map['border']),
      corner: map['corner'] == null
          ? null
          : ComponentCornerEffect.fromMap(map['corner']),
      float: map['float'] == null
          ? null
          : ComponentFloatEffect.fromMap(map['float']),
    );
  }

  bool matches({
    required String targetPage,
    required String targetType,
    int? targetIndex,
  }) {
    if (all) return true;
    if (page != null && page != targetPage) return false;
    if (type != null && type != targetType) return false;
    if (index != null && index != targetIndex) return false;
    // all 为 false 且没有任何筛选条件时，视为匹配（AI 只写了效果没写匹配）。
    return true;
  }
}

/// 边框发光：整体或指定角落局部发光。
class ComponentBorderEffect {
  const ComponentBorderEffect({
    this.color = const Color(0xFF7DF9FF),
    this.width = 1.5,
    this.glowRadius = 10,
    this.glowOpacity = 0.7,
    this.corners = const ['tl', 'tr', 'bl', 'br'],
    this.allSides = true,
  });

  final Color color;
  final double width;
  final double glowRadius;
  final double glowOpacity;

  /// ['tl','tr','bl','br']，只对这些角落画局部弧光。
  final List<String> corners;

  /// true = 整圈边缘都发光；false = 只画 corners 指定的角。
  final bool allSides;

  factory ComponentBorderEffect.fromMap(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : null;
    if (map == null) return const ComponentBorderEffect();
    final rawCorners = map['corners'];
    return ComponentBorderEffect(
      color: _parseColor(map['color']?.toString()) ?? const Color(0xFF7DF9FF),
      width: (map['width'] as num?)?.toDouble() ?? 1.5,
      glowRadius: (map['glowRadius'] as num?)?.toDouble() ?? 10,
      glowOpacity: (map['glowOpacity'] as num?)?.toDouble() ?? 0.7,
      corners: rawCorners is List
          ? rawCorners.map((e) => e.toString()).toList()
          : const ['tl', 'tr', 'bl', 'br'],
      allSides: map['allSides'] != false,
    );
  }
}

/// 角标挂件：在组件某个角放一个小图标/图片。
class ComponentCornerEffect {
  const ComponentCornerEffect({
    this.icon = Icons.auto_awesome,
    this.position = 'topRight',
    this.size = 22,
    this.color = const Color(0xFFFF9EC4),
    this.glow = true,
  });

  final IconData icon;
  final String position;
  final double size;
  final Color color;
  final bool glow;

  static const staticIcons = <String, IconData>{
    'sparkle': Icons.auto_awesome,
    'star': Icons.star,
    'heart': Icons.favorite,
    'flower': Icons.local_florist,
    'paw': Icons.pets,
    'fire': Icons.local_fire_department,
    'bolt': Icons.bolt,
    'smile': Icons.sentiment_satisfied_alt,
    'ghost': Icons.mood_bad,
    'magic': Icons.auto_fix_high,
  };

  factory ComponentCornerEffect.fromMap(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : null;
    if (map == null) return const ComponentCornerEffect();
    final iconName = map['icon']?.toString();
    return ComponentCornerEffect(
      icon: iconName == null
          ? Icons.auto_awesome
          : staticIcons[iconName.toLowerCase()] ?? Icons.auto_awesome,
      position: map['position']?.toString() ?? 'topRight',
      size: (map['size'] as num?)?.toDouble() ?? 22,
      color: _parseColor(map['color']?.toString()) ?? const Color(0xFFFF9EC4),
      glow: map['glow'] != false,
    );
  }
}

/// 浮动偏移：让组件相对默认位置悬浮。
class ComponentFloatEffect {
  const ComponentFloatEffect({
    this.dx = 0,
    this.dy = -4,
    this.durationMs = 0,
  });

  final double dx;
  final double dy;
  final int durationMs;

  factory ComponentFloatEffect.fromMap(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : null;
    if (map == null) return const ComponentFloatEffect();
    return ComponentFloatEffect(
      dx: (map['dx'] as num?)?.toDouble() ?? 0,
      dy: (map['dy'] as num?)?.toDouble() ?? -4,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
    );
  }
}

Color? _parseColor(String? raw) {
  if (raw == null) return null;
  final hex = raw.trim().replaceFirst('#', '');
  final v = int.tryParse(hex, radix: 16);
  if (v == null) return null;
  if (hex.length == 6) return Color(0xFF000000 | v);
  if (hex.length == 8) return Color(v);
  return null;
}

/// 找出第一个命中的组件特效。
List<ComponentEffect> matchComponentEffects(
  List<ComponentEffect> effects, {
  required String page,
  required String type,
  int? index,
}) {
  return effects
      .where((e) => e.matches(
            targetPage: page,
            targetType: type,
            targetIndex: index,
          ))
      .toList();
}

/// 组件特效渲染器：给 GlassPanel / GlassCard 等玻璃组件挂特效。
///
/// 页面名目前取路由 settings.name；没有就按 default 处理。后续可以
/// 通过页面级 scope 传入更准确的页面标识。
class ComponentEffectsDecorator extends StatelessWidget {
  const ComponentEffectsDecorator({
    super.key,
    required this.child,
    this.type = 'component',
    this.index,
    this.radius = 18,
  });

  final Widget child;
  final String type;
  final int? index;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final visual = Theme.of(context).extension<ThemeVisual>();
    final effects = visual?.componentEffects ?? const <ComponentEffect>[];
    if (effects.isEmpty) return child;
    final route = ModalRoute.of(context);
    final page = route?.settings.name ?? 'default';
    final matched = matchComponentEffects(
      effects,
      page: page,
      type: type,
      index: index,
    );
    if (matched.isEmpty) return child;

    Widget result = child;
    var radius = this.radius;
    for (final effect in matched) {
      if (effect.border != null) {
        result = _BorderGlow(
          child: result,
          radius: radius,
          effect: effect.border!,
        );
        radius = radius; // 外发光不改变圆角。
      }
      if (effect.float != null) {
        result = Transform.translate(
          offset: Offset(effect.float!.dx, effect.float!.dy),
          child: result,
        );
      }
      if (effect.corner != null) {
        result = _CornerBadge(
          child: result,
          radius: radius,
          effect: effect.corner!,
        );
      }
    }
    return result;
  }
}

class _BorderGlow extends StatelessWidget {
  const _BorderGlow({
    required this.child,
    required this.radius,
    required this.effect,
  });

  final Widget child;
  final double radius;
  final ComponentBorderEffect effect;

  @override
  Widget build(BuildContext context) {
    final glow = effect.color.withValues(alpha: effect.glowOpacity);
    Widget content = child;
    if (!effect.allSides) {
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _CornerGlowPainter(
                  color: glow,
                  cornerRadius: radius,
                  glowRadius: effect.glowRadius,
                  corners: effect.corners,
                ),
              ),
            ),
          ),
          child,
        ],
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: effect.allSides
            ? [
                BoxShadow(
                  color: glow,
                  blurRadius: effect.glowRadius,
                  spreadRadius: effect.glowRadius * 0.25,
                ),
                BoxShadow(
                  color: glow.withValues(alpha: effect.glowOpacity * 0.35),
                  blurRadius: effect.glowRadius * 2.2,
                  spreadRadius: effect.glowRadius * 0.1,
                ),
              ]
            : null,
      ),
      child: content,
    );
  }
}

class _CornerBadge extends StatelessWidget {
  const _CornerBadge({
    required this.child,
    required this.radius,
    required this.effect,
  });

  final Widget child;
  final double radius;
  final ComponentCornerEffect effect;

  @override
  Widget build(BuildContext context) {
    final align = switch (effect.position) {
      'topLeft' => Alignment.topLeft,
      'bottomLeft' => Alignment.bottomLeft,
      'bottomRight' => Alignment.bottomRight,
      _ => Alignment.topRight,
    };
    final icon = Icon(effect.icon, size: effect.size, color: effect.color);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: child),
        Positioned(
          left: align.x < 0 ? -4 : null,
          right: align.x > 0 ? -4 : null,
          top: align.y < 0 ? -4 : null,
          bottom: align.y > 0 ? -4 : null,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: effect.glow
                  ? effect.color.withValues(alpha: 0.12)
                  : Colors.transparent,
              shape: BoxShape.circle,
              boxShadow: effect.glow
                  ? [
                      BoxShadow(
                        color: effect.color.withValues(alpha: 0.55),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: icon,
          ),
        ),
      ],
    );
  }
}

class _CornerGlowPainter extends CustomPainter {
  _CornerGlowPainter({
    required this.color,
    required this.cornerRadius,
    required this.glowRadius,
    required this.corners,
  });

  final Color color;
  final double cornerRadius;
  final double glowRadius;
  final List<String> corners;

  static const _cornersMap = {
    'tl': (Alignment.topLeft, 0.0),
    'tr': (Alignment.topRight, math.pi / 2),
    'br': (Alignment.bottomRight, math.pi),
    'bl': (Alignment.bottomLeft, math.pi * 3 / 2),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..color = color
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, glowRadius);
    for (final c in corners) {
      final spec = _cornersMap[c];
      if (spec == null) continue;
      final anchor = Alignment.lerp(Alignment.center, spec.$1, 1)!;
      final cx = anchor.x * size.width / 2 + size.width / 2;
      final cy = anchor.y * size.height / 2 + size.height / 2;
      // 在角上画一段 90° 弧，半径比组件圆角略大。
      final r = (cornerRadius + glowRadius * 0.5).clamp(6.0, 40.0);
      final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
      canvas.drawArc(rect, spec.$2, math.pi / 2 + 0.5, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CornerGlowPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.cornerRadius != cornerRadius ||
      oldDelegate.glowRadius != glowRadius ||
      oldDelegate.corners.join(',') != corners.join(',');
}
