import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme_effects_controller.dart';

/// 用户可调的“组件发光”偏好：内发光/外发光分开设置大小与强度。
///
/// 这些值独立于主题包 JS，存在 SharedPreferences，切主题/重启都会保留；
/// 通过 [ThemeEffectsController.setUserStyle] 作为用户层覆盖，压在主题
/// 自己的组件风格之上，避免“主题把所有组件都点亮、想关都关不掉”。
class ThemeGlowSettings {
  const ThemeGlowSettings({
    this.outerEnabled = false,
    this.outerRadius = 0,
    this.outerOpacity = 0.6,
    this.innerEnabled = false,
    this.innerRadius = 0,
    this.innerOpacity = 0.6,
  });

  final bool outerEnabled;
  final double outerRadius;
  final double outerOpacity;
  final bool innerEnabled;
  final double innerRadius;
  final double innerOpacity;

  ThemeGlowSettings copyWith({
    bool? outerEnabled,
    double? outerRadius,
    double? outerOpacity,
    bool? innerEnabled,
    double? innerRadius,
    double? innerOpacity,
  }) {
    return ThemeGlowSettings(
      outerEnabled: outerEnabled ?? this.outerEnabled,
      outerRadius: outerRadius ?? this.outerRadius,
      outerOpacity: outerOpacity ?? this.outerOpacity,
      innerEnabled: innerEnabled ?? this.innerEnabled,
      innerRadius: innerRadius ?? this.innerRadius,
      innerOpacity: innerOpacity ?? this.innerOpacity,
    );
  }

  Map<String, Object> toPrefs() => {
        'outerEnabled': outerEnabled,
        'outerRadius': outerRadius,
        'outerOpacity': outerOpacity,
        'innerEnabled': innerEnabled,
        'innerRadius': innerRadius,
        'innerOpacity': innerOpacity,
      };

  static ThemeGlowSettings fromPrefs(SharedPreferences prefs) {
    return ThemeGlowSettings(
      outerEnabled: prefs.getBool('theme_glow_outer_enabled') ?? false,
      outerRadius: prefs.getDouble('theme_glow_outer_radius') ?? 0,
      outerOpacity: prefs.getDouble('theme_glow_outer_opacity') ?? 0.6,
      innerEnabled: prefs.getBool('theme_glow_inner_enabled') ?? false,
      innerRadius: prefs.getDouble('theme_glow_inner_radius') ?? 0,
      innerOpacity: prefs.getDouble('theme_glow_inner_opacity') ?? 0.6,
    );
  }
}

/// 全局发光设置单例：负责持久化 + 实时应用。
class ThemeGlowController {
  ThemeGlowController._();

  static final ThemeGlowController instance = ThemeGlowController._();

  ThemeGlowSettings _settings = const ThemeGlowSettings();

  /// 供 UI 监听。
  final ValueNotifier<ThemeGlowSettings> notifier =
      ValueNotifier(const ThemeGlowSettings());

  ThemeGlowSettings get settings => _settings;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _settings = ThemeGlowSettings.fromPrefs(prefs);
    notifier.value = _settings;
    apply();
  }

  Future<void> setOuter({
    bool? enabled,
    double? radius,
    double? opacity,
  }) async {
    _settings = _settings.copyWith(
      outerEnabled: enabled,
      outerRadius: radius,
      outerOpacity: opacity,
    );
    notifier.value = _settings;
    await _persist();
    apply();
  }

  Future<void> setInner({
    bool? enabled,
    double? radius,
    double? opacity,
  }) async {
    _settings = _settings.copyWith(
      innerEnabled: enabled,
      innerRadius: radius,
      innerOpacity: opacity,
    );
    notifier.value = _settings;
    await _persist();
    apply();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final s = _settings;
    await prefs.setBool('theme_glow_outer_enabled', s.outerEnabled);
    await prefs.setDouble('theme_glow_outer_radius', s.outerRadius);
    await prefs.setDouble('theme_glow_outer_opacity', s.outerOpacity);
    await prefs.setBool('theme_glow_inner_enabled', s.innerEnabled);
    await prefs.setDouble('theme_glow_inner_radius', s.innerRadius);
    await prefs.setDouble('theme_glow_inner_opacity', s.innerOpacity);
  }

  /// 把当前偏好作为用户层风格压到组件上。
  ///
  /// 外发光关掉时用透明色“盖掉”主题给的外发光；内发光同理。
  void apply() {
    final s = _settings;
    final style = ComponentStyle(
      glowColor: s.outerEnabled
          ? const Color(0xFF00D4FF)
          : Colors.transparent,
      glowRadius: s.outerRadius,
      glowOpacity: s.outerOpacity,
      innerGlowColor: s.innerEnabled
          ? const Color(0xFF7DF9FF)
          : Colors.transparent,
      innerGlowRadius: s.innerRadius,
      innerGlowOpacity: s.innerOpacity,
    );
    ThemeEffectsController.instance.setUserStyle(style);
  }
}
