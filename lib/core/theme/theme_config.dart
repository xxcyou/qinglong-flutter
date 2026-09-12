import 'package:flutter/material.dart';

/// 主题方案配置。
///
/// 一个主题由四部分组成：
/// - 基础信息：id / 名称 / 亮度
/// - 背景图路径（空 = 纯配色 + 流动渐变）
/// - 配色表：主色、背景、表面、文字、描边、阴影、语义色……方方面面
/// - 效果表：玻璃模糊、描边透明度、悬浮深度、圆角、动画时长等
///
/// 配置文件是单文件 JSON：`/workspace/.ql_themes/themes.json`。
class ThemeConfig {
  const ThemeConfig({
    required this.id,
    required this.name,
    this.brightness = 'dark',
    this.backgroundImage = '',
    this.backgroundHtml = '',
    this.colors = const {},
    this.effects = const {},
  });

  final String id;
  final String name;

  /// 'light' / 'dark'
  final String brightness;

  /// 背景图路径（guest 路径，如 /workspace/wallpapers/ocean.png）。
  /// 空字符串 = 纯配色，不显示背景图。
  final String backgroundImage;

  /// 动态背景入口 HTML（guest 路径，如 /workspace/.ql_themes/packages/x/index.html）。
  /// 非空时优先用 HTML/CSS/JS/视频背景，backgroundImage 和纯渐变作为加载中的兜底。
  final String backgroundHtml;

  /// 配色表。见 [defaultColors]。
  final Map<String, String> colors;

  /// 效果表。见 [defaultEffects]。
  final Map<String, double> effects;

  bool get isDark => brightness != 'light';

  Color color(String key, Color fallback) {
    final raw = colors[key]?.trim() ?? '';
    if (raw.isEmpty) return fallback;
    final hex = raw.replaceFirst('#', '');
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return fallback;
    if (hex.length == 6) return Color(0xFF000000 | value);
    if (hex.length == 8) return Color(value);
    return fallback;
  }

  double effect(String key, double fallback) => effects[key] ?? fallback;

  ColorScheme scheme() {
    final dark = isDark;
    return ColorScheme(
      brightness: dark ? Brightness.dark : Brightness.light,
      primary: color('primary', const Color(0xFF66BB6A)),
      onPrimary:
          color('onPrimary', dark ? const Color(0xFF0B1F12) : Colors.white),
      primaryContainer: color('primaryContainer',
          dark ? const Color(0xFF1C4030) : const Color(0xFFC8E6C9)),
      onPrimaryContainer: color('onPrimaryContainer',
          dark ? const Color(0xFFB9F6CA) : const Color(0xFF0B3D0B)),
      secondary: color('accent', const Color(0xFF4FC3F7)),
      onSecondary:
          color('onSecondary', dark ? const Color(0xFF06222E) : Colors.white),
      secondaryContainer: color('secondaryContainer',
          dark ? const Color(0xFF134A5C) : const Color(0xFFB3E5FC)),
      onSecondaryContainer: color('onSecondaryContainer',
          dark ? const Color(0xFFB3E5FC) : const Color(0xFF00344C)),
      tertiary: color('accent', const Color(0xFF4FC3F7)),
      onTertiary:
          color('onSecondary', dark ? const Color(0xFF06222E) : Colors.white),
      tertiaryContainer: color('secondaryContainer',
          dark ? const Color(0xFF134A5C) : const Color(0xFFB3E5FC)),
      onTertiaryContainer: color('onSecondaryContainer',
          dark ? const Color(0xFFB3E5FC) : const Color(0xFF00344C)),
      error: color('error', const Color(0xFFE57373)),
      onError: Colors.white,
      errorContainer: color('errorContainer',
          dark ? const Color(0xFF5F1111) : const Color(0xFFF8BBD0)),
      onErrorContainer: color('onErrorContainer',
          dark ? const Color(0xFFF8BBD0) : const Color(0xFF2B0A0A)),
      surface: color('background',
          dark ? const Color(0xFF0F1115) : const Color(0xFFF7FAF8)),
      onSurface: color('onSurface',
          dark ? const Color(0xFFE8EAED) : const Color(0xFF1A1C1E)),
      surfaceContainerLowest: color('surfaceLowest',
          dark ? const Color(0xFF0B0D10) : const Color(0xFFFFFFFF)),
      surfaceContainerLow: color('surfaceLow',
          dark ? const Color(0xFF14171C) : const Color(0xFFF2F6F3)),
      surfaceContainer: color(
          'surface', dark ? const Color(0xFF1A1D24) : const Color(0xFFE9EFEB)),
      surfaceContainerHigh: color('surfaceHigh',
          dark ? const Color(0xFF22262F) : const Color(0xFFDDE6E0)),
      surfaceContainerHighest: color('surfaceHighest',
          dark ? const Color(0xFF2A2F38) : const Color(0xFFD2DDD6)),
      onSurfaceVariant: color('onSurfaceVariant',
          dark ? const Color(0xFF9AA0A6) : const Color(0xFF44484C)),
      outline: color(
          'outline', dark ? const Color(0xFF8A9096) : const Color(0xFF74777B)),
      outlineVariant: color('outlineVariant',
          dark ? const Color(0xFF3A4048) : const Color(0xFFC1C7C2)),
      shadow: color('shadow', Colors.black),
      scrim: color('shadow', Colors.black),
      inverseSurface: color('inverseSurface',
          dark ? const Color(0xFFE8EAED) : const Color(0xFF2A2E33)),
      onInverseSurface: color('onInverseSurface',
          dark ? const Color(0xFF1A1C1E) : const Color(0xFFF2F2F2)),
      inversePrimary: color('accent', const Color(0xFF80D8FF)),
      surfaceTint: color('primary', const Color(0xFF66BB6A)),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'brightness': brightness,
        'backgroundImage': backgroundImage,
        'backgroundHtml': backgroundHtml,
        'colors': colors,
        'effects': effects,
      };

  static ThemeConfig fromJson(Map<String, dynamic> json) {
    return ThemeConfig(
      id: json['id']?.toString() ??
          'theme${DateTime.now().millisecondsSinceEpoch}',
      name: json['name']?.toString() ?? '未命名主题',
      brightness: json['brightness']?.toString() == 'light' ? 'light' : 'dark',
      backgroundImage: json['backgroundImage']?.toString() ?? '',
      backgroundHtml: json['backgroundHtml']?.toString() ?? '',
      colors: {
        for (final e in (json['colors'] as Map?)?.entries ??
            <MapEntry<String, dynamic>>[])
          e.key.toString(): e.value.toString(),
      },
      effects: {
        for (final e in (json['effects'] as Map?)?.entries ??
            <MapEntry<String, dynamic>>[])
          e.key.toString(): (e.value as num?)?.toDouble() ?? 0,
      },
    );
  }

  ThemeConfig copyWith({
    String? id,
    String? name,
    String? brightness,
    String? backgroundImage,
    String? backgroundHtml,
    Map<String, String>? colors,
    Map<String, double>? effects,
  }) {
    return ThemeConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      brightness: brightness ?? this.brightness,
      backgroundImage: backgroundImage ?? this.backgroundImage,
      backgroundHtml: backgroundHtml ?? this.backgroundHtml,
      colors: colors ?? this.colors,
      effects: effects ?? this.effects,
    );
  }

  /// 默认配色表（AI 生成新主题时至少补这些键，缺的用默认值）。
  static const List<String> colorKeys = [
    'primary',
    'primaryContainer',
    'onPrimaryContainer',
    'accent',
    'background',
    'surface',
    'surfaceLow',
    'surfaceHigh',
    'surfaceHighest',
    'onSurface',
    'onSurfaceVariant',
    'outline',
    'outlineVariant',
    'border',
    'shadow',
    'success',
    'warning',
    'error',
    'errorContainer',
    'onErrorContainer',
  ];

  static const Map<String, String> defaultColors = {
    'primary': '#66BB6A',
    'primaryContainer': '#1C4030',
    'onPrimaryContainer': '#B9F6CA',
    'accent': '#4FC3F7',
    'background': '#0F1115',
    'surface': '#1A1D24',
    'surfaceLow': '#14171C',
    'surfaceHigh': '#22262F',
    'surfaceHighest': '#2A2F38',
    'onSurface': '#E8EAED',
    'onSurfaceVariant': '#9AA0A6',
    'outline': '#8A9096',
    'outlineVariant': '#3A4048',
    'border': '#FFFFFF',
    'shadow': '#000000',
    'success': '#4CAF50',
    'warning': '#FFB300',
    'error': '#E57373',
    'errorContainer': '#5F1111',
    'onErrorContainer': '#F8BBD0',
  };

  static const Map<String, double> defaultEffects = {
    'glassBlur': 26,
    'glassBorderOpacity': 0.16,
    'glassShadowY': 8,
    'glassShadowOpacity': 0.42,
    'glassRadius': 22,
    'cardRadius': 16,
    'floatingDepth': 4,
    'animationDurationMs': 250,
    'animatedGradient': 0,
  };

  static Map<String, String> defaultColorsForBrightness(String brightness) {
    final dark = brightness != 'light';
    return {
      ...defaultColors,
      if (dark) ...defaultColors,
      if (!dark) ...{
        'primary': '#2E7D32',
        'primaryContainer': '#C8E6C9',
        'onPrimaryContainer': '#0B3D0B',
        'accent': '#0288D1',
        'background': '#F7FAF8',
        'surface': '#FFFFFF',
        'surfaceLow': '#F2F6F3',
        'surfaceHigh': '#E9EFEB',
        'surfaceHighest': '#DDE6E0',
        'onSurface': '#1A1C1E',
        'onSurfaceVariant': '#44484C',
        'outline': '#74777B',
        'outlineVariant': '#C1C7C2',
        'border': '#FFFFFF',
        'shadow': '#000000',
        'success': '#2E7D32',
        'warning': '#F9A825',
        'error': '#C62828',
        'errorContainer': '#F8BBD0',
        'onErrorContainer': '#2B0A0A',
      },
    };
  }
}
