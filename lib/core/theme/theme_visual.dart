import 'package:flutter/material.dart';

import 'theme_config.dart';

/// 挂在 ThemeData 上的“玻璃视觉”扩展：背景图、渐变底、描边、阴影、
/// 模糊、圆角、动画时长等全局效果参数。
///
/// [GlassPanel] 和 [GlassBackdrop] 从这里取值，让主题方案不只是换几个
/// Material 颜色，而是连玻璃质感、悬浮深度、背景图一起整包替换。
class ThemeVisual extends ThemeExtension<ThemeVisual> {
  const ThemeVisual({
    required this.config,
    required this.borderColor,
    required this.shadowColor,
    required this.gradientStart,
    required this.gradientCenter,
    required this.gradientEnd,
    required this.glassBlur,
    required this.glassBorderOpacity,
    required this.glassShadowY,
    required this.glassShadowOpacity,
    required this.glassRadius,
    required this.cardRadius,
    required this.floatingDepth,
    required this.animationDurationMs,
    required this.animatedGradient,
  });

  final ThemeConfig config;

  final Color borderColor;
  final Color shadowColor;
  final Color gradientStart;
  final Color gradientCenter;
  final Color gradientEnd;

  final double glassBlur;
  final double glassBorderOpacity;
  final double glassShadowY;
  final double glassShadowOpacity;
  final double glassRadius;
  final double cardRadius;
  final double floatingDepth;
  final int animationDurationMs;
  final bool animatedGradient;

  static ThemeVisual fromConfig(ThemeConfig config) {
    final dark = config.isDark;
    return ThemeVisual(
      config: config,
      borderColor: config.color('border', Colors.white),
      shadowColor: config.color('shadow', Colors.black),
      gradientStart: config.color(
        'gradientStart',
        dark ? const Color(0xFF0A1311) : const Color(0xFFD7E7DC),
      ),
      gradientCenter: config.color(
        'gradientCenter',
        dark ? const Color(0xFF16201A) : const Color(0xFFEDF3EC),
      ),
      gradientEnd: config.color(
        'gradientEnd',
        dark ? const Color(0xFF0E1A24) : const Color(0xFFD8E3F0),
      ),
      glassBlur: config.effect('glassBlur', 26),
      glassBorderOpacity:
          config.effect('glassBorderOpacity', dark ? 0.16 : 0.78),
      glassShadowY: config.effect('glassShadowY', 8),
      glassShadowOpacity:
          config.effect('glassShadowOpacity', dark ? 0.42 : 0.14),
      glassRadius: config.effect('glassRadius', 22),
      cardRadius: config.effect('cardRadius', 16),
      floatingDepth: config.effect('floatingDepth', 4),
      animationDurationMs: config.effect('animationDurationMs', 250).round(),
      animatedGradient: config.effect('animatedGradient', 0) != 0,
    );
  }

  @override
  ThemeVisual copyWith({
    ThemeConfig? config,
    Color? borderColor,
    Color? shadowColor,
    Color? gradientStart,
    Color? gradientCenter,
    Color? gradientEnd,
    double? glassBlur,
    double? glassBorderOpacity,
    double? glassShadowY,
    double? glassShadowOpacity,
    double? glassRadius,
    double? cardRadius,
    double? floatingDepth,
    int? animationDurationMs,
    bool? animatedGradient,
  }) {
    return ThemeVisual(
      config: config ?? this.config,
      borderColor: borderColor ?? this.borderColor,
      shadowColor: shadowColor ?? this.shadowColor,
      gradientStart: gradientStart ?? this.gradientStart,
      gradientCenter: gradientCenter ?? this.gradientCenter,
      gradientEnd: gradientEnd ?? this.gradientEnd,
      glassBlur: glassBlur ?? this.glassBlur,
      glassBorderOpacity: glassBorderOpacity ?? this.glassBorderOpacity,
      glassShadowY: glassShadowY ?? this.glassShadowY,
      glassShadowOpacity: glassShadowOpacity ?? this.glassShadowOpacity,
      glassRadius: glassRadius ?? this.glassRadius,
      cardRadius: cardRadius ?? this.cardRadius,
      floatingDepth: floatingDepth ?? this.floatingDepth,
      animationDurationMs: animationDurationMs ?? this.animationDurationMs,
      animatedGradient: animatedGradient ?? this.animatedGradient,
    );
  }

  @override
  ThemeVisual lerp(covariant ThemeVisual? other, double t) {
    if (other == null) return this;
    return ThemeVisual(
      config: t < 0.5 ? config : other.config,
      borderColor: Color.lerp(borderColor, other.borderColor, t)!,
      shadowColor: Color.lerp(shadowColor, other.shadowColor, t)!,
      gradientStart: Color.lerp(gradientStart, other.gradientStart, t)!,
      gradientCenter: Color.lerp(gradientCenter, other.gradientCenter, t)!,
      gradientEnd: Color.lerp(gradientEnd, other.gradientEnd, t)!,
      glassBlur: glassBlur + (other.glassBlur - glassBlur) * t,
      glassBorderOpacity: glassBorderOpacity +
          (other.glassBorderOpacity - glassBorderOpacity) * t,
      glassShadowY: glassShadowY + (other.glassShadowY - glassShadowY) * t,
      glassShadowOpacity: glassShadowOpacity +
          (other.glassShadowOpacity - glassShadowOpacity) * t,
      glassRadius: glassRadius + (other.glassRadius - glassRadius) * t,
      cardRadius: cardRadius + (other.cardRadius - cardRadius) * t,
      floatingDepth: floatingDepth + (other.floatingDepth - floatingDepth) * t,
      animationDurationMs:
          t < 0.5 ? animationDurationMs : other.animationDurationMs,
      animatedGradient: t < 0.5 ? animatedGradient : other.animatedGradient,
    );
  }
}
