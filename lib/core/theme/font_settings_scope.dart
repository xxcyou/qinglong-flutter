import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/settings/providers/settings_provider.dart';
import '../local_shell/proot_bridge.dart';
import 'theme_config.dart';

/// 字体文件动态加载。
///
/// TextStyle 的 fontFamily 只认“已注册的字体族名”，不认路径。
/// 用户/主题包给的 .ttf/.otf 文件先在这里注册成固定族名，
/// 之后所有 Text 用 `dshUserFont` / `dshThemeFont` 就能渲染。
class FontLoaderService {
  FontLoaderService._();

  static const userFamily = 'dshUserFont';
  static const themeFamily = 'dshThemeFont';
  static String _loadedUserPath = '';
  static String _loadedThemePath = '';
  static bool _loadingUser = false;
  static bool _loadingTheme = false;

  static bool isFontFile(String family) {
    final lower = family.toLowerCase();
    return lower.endsWith('.ttf') || lower.endsWith('.otf');
  }

  /// 从 guest 路径读取字体字节并注册为 [userFamily]。
  static Future<void> loadUserFont(String guestPath,
      {String scope = 'shell'}) async {
    if (guestPath.isEmpty || guestPath == _loadedUserPath || _loadingUser) {
      if (guestPath.isNotEmpty && guestPath != _loadedUserPath) return;
      return;
    }
    _loadingUser = true;
    try {
      final bytes = await _readBytes(guestPath, scope: scope);
      if (bytes.isEmpty) return;
      final loader = FontLoader(userFamily)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loadedUserPath = guestPath;
    } catch (_) {
      // 字体文件坏/找不到时静默回退系统字体。
    } finally {
      _loadingUser = false;
    }
  }

  /// 从 guest 路径读取字体字节并注册为 [themeFamily]。
  static Future<void> loadThemeFont(String guestPath,
      {String scope = 'shell'}) async {
    if (guestPath.isEmpty || guestPath == _loadedThemePath || _loadingTheme) {
      if (guestPath.isNotEmpty && guestPath != _loadedThemePath) return;
      return;
    }
    _loadingTheme = true;
    try {
      final bytes = await _readBytes(guestPath, scope: scope);
      if (bytes.isEmpty) return;
      final loader = FontLoader(themeFamily)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loadedThemePath = guestPath;
    } catch (_) {
      // 字体文件坏/找不到时静默回退系统字体。
    } finally {
      _loadingTheme = false;
    }
  }

  static Future<Uint8List> _readBytes(String guestPath,
      {String scope = 'shell'}) async {
    final host = await ProotBridge().hostPath(path: guestPath, scope: scope);
    return File(host).readAsBytes();
  }
}

/// 把 App 字体设置 + 主题包 typography 合并成全局 [DefaultTextStyle]。
class FontSettingsScope extends StatefulWidget {
  const FontSettingsScope({
    super.key,
    required this.settings,
    required this.theme,
    required this.child,
  });

  final AppSettings settings;
  final ThemeConfig? theme;
  final Widget child;

  @override
  State<FontSettingsScope> createState() => _FontSettingsScopeState();
}

class _FontSettingsScopeState extends State<FontSettingsScope> {
  @override
  void initState() {
    super.initState();
    _scheduleFontLoad();
  }

  @override
  void didUpdateWidget(FontSettingsScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.fontFamily != widget.settings.fontFamily ||
        oldWidget.settings.fontCustomEnabled !=
            widget.settings.fontCustomEnabled ||
        oldWidget.theme?.fontStyle.family != widget.theme?.fontStyle.family) {
      _scheduleFontLoad();
    }
  }

  void _scheduleFontLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFonts());
  }

  Future<void> _loadFonts() async {
    final themeFont = widget.theme?.fontStyle ?? const ThemeFontConfig();
    if (widget.settings.fontCustomEnabled &&
        FontLoaderService.isFontFile(widget.settings.fontFamily)) {
      await FontLoaderService.loadUserFont(widget.settings.fontFamily);
    }
    if (FontLoaderService.isFontFile(themeFont.family)) {
      await FontLoaderService.loadThemeFont(themeFont.family);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final theme = widget.theme;
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.onSurface;
    final effective = _effective();
    final themeFont = theme?.fontStyle ?? const ThemeFontConfig();

    String? family;
    String? familyName;
    if (FontLoaderService.isFontFile(effective.family)) {
      if (settings.fontCustomEnabled &&
          settings.fontFamily.isNotEmpty &&
          FontLoaderService.isFontFile(settings.fontFamily)) {
        familyName = FontLoaderService.userFamily;
      } else if (themeFont.family.isNotEmpty &&
          FontLoaderService.isFontFile(themeFont.family)) {
        familyName = FontLoaderService.themeFamily;
      }
      family = familyName;
    } else if (effective.family.isNotEmpty) {
      family = effective.family;
    }

    final rawColor = effective.color ?? base;
    final opacity = effective.opacity.clamp(0.0, 1.0);
    final color = rawColor.withValues(
      alpha: (rawColor.a * opacity).clamp(0.0, 1.0),
    );

    final shadows = effective.goldBorder
        ? [
            const Shadow(
              color: Color(0xFFFFE082),
              blurRadius: 8,
              offset: Offset.zero,
            ),
            const Shadow(
              color: Color(0xFFD4AF37),
              blurRadius: 2,
              offset: Offset.zero,
            ),
            const Shadow(
              color: Color(0xFFB8860B),
              blurRadius: 1,
              offset: Offset.zero,
            ),
          ]
        : null;

    final style = TextStyle(
      fontFamily: family,
      fontSize: effective.size,
      fontWeight: effective.weight,
      color: color,
      decoration: effective.strikethrough ? TextDecoration.lineThrough : null,
      decorationColor: effective.goldBorder ? const Color(0xFFD4AF37) : color,
      shadows: shadows,
    );

    return DefaultTextStyle(
      style: style,
      child: widget.child,
    );
  }

  ThemeFontConfig _effective() {
    final themeFont = widget.theme?.fontStyle ?? const ThemeFontConfig();
    if (!widget.settings.fontCustomEnabled) return themeFont;
    final user = ThemeFontConfig(
      family: widget.settings.fontFamily,
      size: widget.settings.fontSize,
      weight: switch (widget.settings.fontWeight.round()) {
        100 => FontWeight.w100,
        200 => FontWeight.w200,
        300 => FontWeight.w300,
        400 => FontWeight.w400,
        500 => FontWeight.w500,
        600 => FontWeight.w600,
        700 => FontWeight.w700,
        800 => FontWeight.w800,
        _ => FontWeight.w900,
      },
      color: Color(widget.settings.fontColor),
      opacity: widget.settings.fontOpacity,
      strikethrough: widget.settings.fontStrikethrough,
      goldBorder: widget.settings.fontGoldBorder,
    );
    return themeFont.merge(user);
  }
}
