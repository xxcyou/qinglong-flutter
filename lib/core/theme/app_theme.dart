import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme_config.dart';
import 'theme_visual.dart';

/// 亮/暗/跟随系统三态主题。
class AppTheme {
  const AppTheme._();

  static ThemeData light() => fromConfig(
        ThemeConfig(
          id: 'default-light',
          name: '默认亮色',
          brightness: 'light',
          colors: ThemeConfig.defaultColorsForBrightness('light'),
          effects: ThemeConfig.defaultEffects,
        ),
      );

  static ThemeData dark() => fromConfig(
        ThemeConfig(
          id: 'default-dark',
          name: '默认暗色',
          brightness: 'dark',
          colors: ThemeConfig.defaultColorsForBrightness('dark'),
          effects: ThemeConfig.defaultEffects,
        ),
      );

  /// 从主题方案构建 ThemeData。
  static ThemeData fromConfig(ThemeConfig config) {
    return _base(config.scheme(), visual: ThemeVisual.fromConfig(config));
  }

  static ThemeData _base(ColorScheme scheme, {ThemeVisual? visual}) {
    final isDark = scheme.brightness == Brightness.dark;
    final v = visual ??
        ThemeVisual.fromConfig(ThemeConfig(
          id: 'default',
          name: '默认',
          brightness: isDark ? 'dark' : 'light',
          colors:
              ThemeConfig.defaultColorsForBrightness(isDark ? 'dark' : 'light'),
          effects: ThemeConfig.defaultEffects,
        ));
    final borderColor = v.borderColor.withValues(alpha: v.glassBorderOpacity);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      extensions: [v],
      // 背景由 GlassBackdrop 绘制，Scaffold 自身透明，玻璃才有东西可模糊。
      scaffoldBackgroundColor: Colors.transparent,
      // 全面屏：AppBar 不再画背景色块（"额头"），内容自己延伸到状态栏下。
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness:
              isDark ? Brightness.light : Brightness.dark,
        ),
      ),
      // 还在用 Card 的老页面（设置、面板、技能、记忆…）也跟着透：
      // 逐个换成 GlassCard 是几百行改动，把主题里的默认底色调成半透明
      // 一次就全生效了。
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow.withValues(alpha: isDark ? 0.5 : 0.6),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(v.cardRadius),
          side: BorderSide(
            color: borderColor.withValues(alpha: isDark ? 0.1 : 0.55),
          ),
        ),
        margin: EdgeInsets.zero,
      ),
      // 输入框：也做成一小块玻璃（填充 + 柔和描边），
      // 原来的纯描边框在流动背景上看起来是浮在空气里的一圈线。
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: (isDark ? Colors.white : Colors.white).withValues(
          alpha: isDark ? 0.05 : 0.42,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(v.cardRadius),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(v.cardRadius),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.3),
        ),
        isDense: true,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurfaceVariant,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      // 弹窗/菜单/底部面板统统改成半透明的玻璃板。
      //
      // 之前它们是"完全透明"：内容直接飘在被压暗的页面上，浅色主题下文字和
      // 背景卡片糊在一起。给一层带透明度的底 + 大圆角 + 白棱边之后，
      // 它既是玻璃（底下流动的光斑仍然透出来），也终于有边界了。
      dialogTheme: DialogThemeData(
        backgroundColor:
            (isDark ? scheme.surfaceContainerHigh : Colors.white).withValues(
          alpha: isDark ? 0.86 : 0.9,
        ),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(v.glassRadius),
          side: BorderSide(color: borderColor),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: (isDark ? scheme.surfaceContainerHigh : Colors.white).withValues(
          alpha: isDark ? 0.88 : 0.92,
        ),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(v.cardRadius),
          side: BorderSide(color: borderColor),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor:
            (isDark ? scheme.surfaceContainerHigh : Colors.white).withValues(
          alpha: isDark ? 0.84 : 0.9,
        ),
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: Colors.black.withValues(alpha: isDark ? 0.5 : 0.28),
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        titleTextStyle: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
        subtitleTextStyle: TextStyle(fontSize: 12),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        thickness: 0.6,
      ),
    );
  }
}
