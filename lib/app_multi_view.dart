import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_store.dart';
import 'features/external/external_float_shell.dart';
import 'features/settings/providers/settings_provider.dart';

/// 多 View 根：同一个 FlutterEngine 里，主 Activity 的 view 渲染 APP 页面，
/// 外部悬浮窗服务的 view 渲染悬浮层。
///
/// 这样不需要 finish Activity，也不会出现“内置悬浮球/外悬浮球”两套入口；
/// 所有悬浮窗都只存在于系统覆盖窗口里，点开 AI 悬浮球就是 APP 外悬浮球。
class MultiViewRoot extends StatefulWidget {
  const MultiViewRoot({super.key});

  @override
  State<MultiViewRoot> createState() => _MultiViewRootState();
}

class _MultiViewRootState extends State<MultiViewRoot>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // View 增加/移除时 engine 也会走 onMetricsChanged，重建 ViewCollection。
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    final views = dispatcher.views.toList();
    if (views.isEmpty) return const QingLongApp();
    final implicit = dispatcher.implicitView ?? views.first;
    return ViewCollection(
      views: [
        for (final view in views)
          View(
            key: ValueKey<int>(view.viewId),
            view: view,
            child: identical(view, implicit)
                ? const QingLongApp()
                : const ExternalFloatView(),
          ),
      ],
    );
  }
}

/// 外部悬浮窗 view 的根：只画悬浮层，不画 APP 页面。
class ExternalFloatView extends ConsumerWidget {
  const ExternalFloatView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeProvider);
    final settings = ref.watch(settingsProvider);
    final active = themeState.active;
    final mode = active == null
        ? settings.themeMode
        : (active.isDark ? ThemeMode.dark : ThemeMode.light);
    return MaterialApp(
      title: '青龙AI 悬浮窗',
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: active == null ? AppTheme.light() : AppTheme.fromConfig(active),
      darkTheme: active == null ? AppTheme.dark() : AppTheme.fromConfig(active),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      locale: const Locale('zh', 'CN'),
      home: const ExternalFloatShell(),
    );
  }
}
