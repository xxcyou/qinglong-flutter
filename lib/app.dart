import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/debug/api_debug_log.dart';
import 'core/llm/llm_registry_provider.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_config.dart';
import 'core/theme/glass.dart';
import 'core/theme/theme_store.dart';
import 'features/ai/floating/ai_dock_overlay.dart';
import 'features/browser/browser_host.dart';
import 'features/panels/providers/panel_list_provider.dart';
import 'features/settings/providers/settings_provider.dart';
import 'router.dart';
import 'shared/float_stack.dart';

/// 应用根组件：主题、语言、路由全部挂载在这里。
class QingLongApp extends ConsumerStatefulWidget {
  const QingLongApp({super.key});

  @override
  ConsumerState<QingLongApp> createState() => _QingLongAppState();
}

class _QingLongAppState extends ConsumerState<QingLongApp> {
  @override
  void initState() {
    super.initState();
    ref.listenManual(currentPanelProvider, (previous, next) {
      configureDioForPanel(next);
    });
    Future.microtask(() async {
      await ref.read(settingsProvider.notifier).load();
      await ref.read(themeProvider.notifier).load();
      ApiDebugLog.enabled = ref.read(settingsProvider).debugLogEnabled;
      // 提供商总表要在设置之后读：第一次启动时它会把老的单份 AI 配置
      // （llmBaseUrl / 那把全局 Key / 模型缓存）迁移成一家提供商，
      // 迁移的数据源就是刚读好的设置。
      await ref.read(llmRegistryProvider.notifier).load();
      await ref.read(panelListProvider.notifier).load();
      configureDioForPanel(ref.read(currentPanelProvider));
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final themeState = ref.watch(themeProvider);
    final activeTheme = themeState.active;
    final router = ref.watch(routerProvider);
    final defaultLight = ThemeConfig(
      id: 'builtin-light',
      name: '默认亮色',
      brightness: 'light',
      colors: ThemeConfig.defaultColorsForBrightness('light'),
      effects: ThemeConfig.defaultEffects,
    );
    final defaultDark = ThemeConfig(
      id: 'builtin-dark',
      name: '默认暗色',
      brightness: 'dark',
      colors: ThemeConfig.defaultColorsForBrightness('dark'),
      effects: ThemeConfig.defaultEffects,
    );
    final effectiveThemeMode = activeTheme == null
        ? settings.themeMode
        : (activeTheme.isDark ? ThemeMode.dark : ThemeMode.light);

    return MaterialApp.router(
      title: '青龙面板',
      debugShowCheckedModeBanner: false,
      themeMode: effectiveThemeMode,
      theme: AppTheme.fromConfig(activeTheme ?? defaultLight),
      darkTheme: AppTheme.fromConfig(activeTheme ?? defaultDark),
      routerConfig: router,
      // 悬浮 AI 挂在 Navigator 之上：push 出去的脚本页、日志页也能随手问 AI。
      // GlassFlowDriver 包住整棵树：它只旁听指针/滚动事件，用来把背景光斑
      // "推"起来（空闲时背景一帧都不画，实测省下一整个核）。
      builder: (context, child) => GlassFlowDriver(
        child: Stack(
          children: [
            // key 必不可少：这个 Stack 的孩子个数会变（child 可能为 null），
            // 没 key 就按下标配对，Element 会被挪到别的槽位上去——
            // home_shell 里同样的坑造成过"菜单出来了却点不动"。
            if (child != null)
              Positioned.fill(key: const ValueKey('app-router'), child: child),
            // 两个悬浮窗的上下顺序由 FloatStack 在运行时决定：新弹出的置前、
            // 点谁谁置前。写死顺序的话总有一个永远被压住——压住的那个就点不到了
            // （浏览器压着聊天窗时点聊天窗只会点到网页，反之会挡住人机验证）。
            //
            // 外面这层 Positioned.fill 不能省：Stack 的非定位子节点拿到的是
            // 松约束，而里面那层 Stack 的孩子全是 Positioned.fill（没有任何
            // 非定位子节点），于是它会把自己缩成 0×0，两个悬浮窗一起消失。
            //
            // 两个宿主都始终挂在树上（只是换顺序）：WebView 一旦被摘下来，
            // 页面里的定时器和 CF 挑战脚本就断了，票白拿。
            Positioned.fill(
              key: const ValueKey('app-floats'),
              child: AnimatedBuilder(
                animation: FloatStack.instance,
                builder: (context, _) => Stack(
                  children: [
                    for (final id in FloatStack.instance.order)
                      if (id == FloatStack.ai)
                        const Positioned.fill(
                          key: ValueKey('float-ai'),
                          child: AiDockHost(),
                        )
                      else
                        const Positioned.fill(
                          key: ValueKey('float-browser'),
                          child: BrowserHost(),
                        ),
                    // 悬浮球永远画在两个窗口之上：浏览器一最大化就盖住整块屏幕，
                    // 气泡要是跟着聊天窗沉下去，用户就没有任何入口能把 AI 叫回来。
                    const Positioned.fill(
                      key: ValueKey('float-bubble'),
                      child: AiBubbleHost(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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
    );
  }
}
