import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme/glass.dart';
import '../../router.dart';
import '../../shared/code_editor.dart';
import '../../shared/code_language.dart';
import '../../shared/editor_bus.dart';
import '../../shared/float_stack.dart';
import '../../shared/highlighting_code_controller.dart';
import 'browser_engine.dart';
import 'browser_window.dart';
import 'web_bridge.dart';
import 'intercept_js.dart';
import 'models/browser_models.dart';
import 'models/browser_profile.dart';
import 'models/intercept_script.dart';
import '../../shared/mono_text.dart';

/// 浏览器内部弹窗用的 builder 类型。
typedef BrowserDialogBuilder<T> =
    Widget Function(BuildContext context, void Function([T?]) pop);

/// 在浏览器自己的 Overlay 里弹一个对话框。
///
/// 浏览器宿主挂在主 App Navigator 外面，直接 showDialog 会因为找不到
/// Navigator 而静默失败。这里用 OverlayEntry 手搓一个不需要 Navigator 的
/// 模态层：barrier + 居中内容 + pop 回调。
Future<T?> showBrowserDialog<T>({
  required BuildContext context,
  required BrowserDialogBuilder<T> builder,
  bool barrierDismissible = true,
}) {
  final overlay = Overlay.of(context);
  final completer = Completer<T?>();
  var closed = false;
  late final OverlayEntry entry;
  void finish([T? result]) {
    if (closed) return;
    closed = true;
    entry.remove();
    if (!completer.isCompleted) completer.complete(result);
  }

  entry = OverlayEntry(
    opaque: false,
    maintainState: false,
    builder: (dialogContext) => _BrowserDialogHost<T>(
      child: builder(dialogContext, finish),
      onDismiss: barrierDismissible ? () => finish(null) : null,
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _BrowserDialogHost<T> extends StatelessWidget {
  const _BrowserDialogHost({required this.child, this.onDismiss});

  final Widget child;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: ModalBarrier(
            dismissible: onDismiss != null,
            color: Colors.black54,
            onDismiss: onDismiss,
          ),
        ),
        Center(
          child: SafeArea(
            child: Material(
              type: MaterialType.transparency,
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

/// 浏览器宿主：一个常驻的悬浮窗浏览器。
///
/// 两条硬约束决定了这个文件的结构：
///
/// 1. **WebView 部件必须一直挂在树上**，只在"看不见"时挪到屏幕外。
///    若按可见性创建/销毁，Android 会把 WebView 从视图树摘掉，页面里的定时器
///    和 Cloudflare 的挑战脚本会被挂起——用户点完验证切走再回来，票就没了。
///    所以 WebViewWidget 在这里只有**一个**挂点，变的只是它的 Positioned 几何。
///
/// 2. **人机验证不需要专门的组件**。它就是一个网页：把窗口亮给用户，用户像用
///    普通浏览器那样点掉验证、登录、输验证码，内核里自然就带上票和登录态了。
///    所以这里没有"CF 验证界面"，只有一个正常浏览器 + 一条"AI 在等你"的提示。
///
/// 用户可以随手拖动、按边缩放、最大化，也能自己输网址当普通浏览器用；
/// AI 通过 browser_* 工具控制同一个内核，两边看到的是同一个页面。
class BrowserHost extends StatelessWidget {
  const BrowserHost({super.key});

  @override
  Widget build(BuildContext context) {
    // 必须自带一个 Overlay。
    //
    // 这个宿主挂在 MaterialApp.builder 的 Stack 里，是路由 Navigator 的**兄弟**，
    // 不在它内部，所以拿不到 Navigator 提供的 Overlay。而工具条上的
    // IconButton(tooltip:) 里的 Tooltip 会 assert "No Overlay widget found"，
    // 直接把整个浏览器画成红屏（RenderErrorBox 高 100000，于是又叠一条
    // "BOTTOM OVERFLOWED BY …" 黄条）。AI 悬浮窗当初也踩过同一个坑。
    return Directionality(
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            opaque: false,
            maintainState: true,
            builder: (_) => const BrowserView(),
          ),
        ],
      ),
    );
  }
}

/// 浏览器窗口本体。外面必须有 Overlay（见 [BrowserHost]）。
class BrowserView extends StatefulWidget {
  const BrowserView({super.key});

  @override
  State<BrowserView> createState() => _BrowserViewState();
}

class _BrowserViewState extends State<BrowserView> with WidgetsBindingObserver {
  final _engine = BrowserEngine.instance;
  final _window = BrowserWindow.instance;
  final _urlController = TextEditingController();

  /// 0 页面 / 1 抓包 / 2 日志 / 3 脚本
  int _tab = 0;

  /// 抓包详情：点列表项后在这里看结构化内容，null = 回到列表。
  CapturedRequest? _detailRequest;

  /// 抓包列表搜索关键字。
  String _captureQuery = '';

  /// 抓包列表快捷过滤：all / error / json。
  String _captureFilter = 'all';

  /// 用户正在编辑地址栏时不要被导航事件覆盖输入。
  bool _urlFocusIdle = true;

  /// 缩放热区宽度。比 AI 悬浮窗窄一点：这里边缘底下是网页，
  /// 热区太宽会把页面的横向滑动吃掉。
  static const _grip = 15.0;

  @override
  void initState() {
    super.initState();
    _window.load();
    _codeController = HighlightingCodeController(
      language: languageForPath('hook.js'),
      languageName: languageNameForPath('hook.js'),
    );
    _engine.externalJumpPrompt = _promptExternalJump;
    // 预创建 WebView：为避免和启动首帧抢主线程（首帧卡 5~15 秒会触发 ANR），
    // 延迟到首帧 3 秒后再挂载内核；用户/AI 在此之前打开网址时 ensure() 会自动
    // 即时创建，不受影响。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) unawaited(_engine.ensure());
      });
    });
    // WebView 第一次 created 后必须让 BrowserView 自己 setState 重建：
    // BrowserHost 外层重建不会穿透 OverlayEntry，只有这里的监听能保证
    // WebViewWidget 第一时间挂出来。
    _engine.controllerRevision.addListener(_onControllerRevision);
    // 接管系统返回键。
    //
    // 浏览器窗口挂在路由 Navigator **之上**，不属于任何 route，所以 PopScope
    // 管不到它：不接管的话，用户在网页里按返回会把 APP 的页面弹掉，
    // 浏览器还开着——完全不是他想要的。观察者按注册的逆序被询问，
    // 我们比 WidgetsApp 后注册，所以能先拿到返回事件。
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _engine.externalJumpPrompt = null;
    _engine.controllerRevision.removeListener(_onControllerRevision);
    WidgetsBinding.instance.removeObserver(this);
    _detachBus();
    _urlController.dispose();
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _onControllerRevision() {
    if (mounted) setState(() {});
  }

  void _openUrlFromPanel(String url) {
    _engine.claimByUser();
    setState(() => _tab = 0);
    unawaited(_engine.open(url));
  }

  Future<void> _showBrowserMenu() async {
    final url = _engine.currentUrl.value.trim();
    final action = await showBrowserDialog<String>(
      context: context,
      builder: (dialogContext, pop) {
        final scheme = Theme.of(dialogContext).colorScheme;
        Widget tile({
          required IconData icon,
          required String title,
          String? subtitle,
          Widget? trailing,
          required String value,
        }) {
          return ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Icon(icon, size: 18, color: scheme.primary),
            title: Text(title, style: const TextStyle(fontSize: 12)),
            subtitle: subtitle == null
                ? null
                : Text(subtitle, style: const TextStyle(fontSize: 10)),
            trailing: trailing,
            onTap: () => pop(value),
          );
        }

        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          title: const Text('浏览器工具', style: TextStyle(fontSize: 14)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                tile(
                  icon: _engine.isDesktopMode
                      ? Icons.smartphone_outlined
                      : Icons.desktop_windows_outlined,
                  title: _engine.isDesktopMode ? '恢复手机版网页' : '桌面版网站',
                  subtitle: '切换 User-Agent 后刷新当前页',
                  value: 'desktop',
                ),
                tile(
                  icon: Icons.visibility_off_outlined,
                  title: _engine.privacyMode.value ? '无痕模式：开' : '无痕模式',
                  subtitle: '开启后不再写入浏览历史',
                  trailing: Icon(
                    _engine.privacyMode.value
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 16,
                    color: _engine.privacyMode.value
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                  value: 'privacy',
                ),
                if (url.isNotEmpty)
                  tile(
                    icon: Icons.copy_outlined,
                    title: '复制链接',
                    value: 'copy',
                  ),
                if (url.isNotEmpty)
                  tile(
                    icon: Icons.open_in_new_rounded,
                    title: '用系统浏览器打开',
                    value: 'external',
                  ),
                tile(
                  icon: Icons.home_outlined,
                  title: '主页',
                  subtitle: '打开 Bing 搜索',
                  value: 'home',
                ),
                tile(
                  icon: Icons.star_outline_rounded,
                  title: '收藏当前页',
                  value: 'bookmark',
                ),
                tile(
                  icon: Icons.refresh_rounded,
                  title: '刷新页面',
                  value: 'reload',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => pop(null),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'desktop':
        await _engine.toggleDesktopMode();
        break;
      case 'privacy':
        _engine.privacyMode.value = !_engine.privacyMode.value;
        break;
      case 'copy':
        if (url.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: url));
          if (!mounted) return;
          final messenger = ScaffoldMessenger.of(context);
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            SnackBar(
              content: Text('链接已复制'),
              duration: const Duration(seconds: 1),
              behavior: SnackBarBehavior.floating,
              width: 160,
            ),
          );
        }
        break;
      case 'external':
        if (url.isNotEmpty) {
          await _engine.openInSystemBrowser(url);
        }
        break;
      case 'home':
        await _engine.open('https://www.bing.com');
        setState(() => _tab = 0);
        break;
      case 'bookmark':
        if (url.isNotEmpty) {
          await _engine.addBookmark(url, title: _engine.title.value);
          if (!mounted) return;
          final messenger = ScaffoldMessenger.of(context);
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            const SnackBar(
              content: Text('已收藏当前页'),
              duration: Duration(seconds: 1),
              behavior: SnackBarBehavior.floating,
              width: 180,
            ),
          );
        }
        break;
      case 'reload':
        await _engine.reload();
        break;
    }
  }

  /// 脚本编辑器开着时编辑的是谁。null = 编辑器没开。
  /// id < 0 表示"新脚本，还没存过"。
  InterceptScript? _editing;
  final _nameController = TextEditingController();
  late final HighlightingCodeController _codeController;
  final _codeEditorKey = GlobalKey<CodeEditorFieldState>();

  /// 编辑器总线上的注册 id（只在编辑器打开期间有值）。
  ///
  /// 只有"编辑器真的开着"才注册，AI 才不会在用户没开抓包脚本编辑器时
  /// 把代码写进这里——那种情况它应该走 browser_hook 直接改脚本表。
  int? _busId;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从外部 App 完成登录/授权返回时，把内置浏览器带回跳转前的页面，
    // 别让用户停留在系统浏览器里。
    if (state == AppLifecycleState.resumed) {
      _engine.handleAppResumed();
    }
  }

  @override
  Future<bool> didPopRoute() async {
    // 编辑器开着：返回键先关编辑器，别把整个浏览器收走。
    if (_editing != null) {
      _closeEditor();
      return true;
    }
    if (!_engine.visible.value) return false;
    // 先在抓包/日志标签页退回"页面"，再走网页历史，最后才收起窗口。
    if (_tab != 0) {
      setState(() => _tab = 0);
      return true;
    }
    if (await _engine.back()) return true;
    await _engine.persist();
    _engine.hide();
    return true;
  }

  Future<bool> _promptExternalJump(ExternalJumpRequest req) async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return false;
    final allow = await showDialog<bool>(
      context: ctx,
      builder: (dialogContext) => AlertDialog(
        title: Text('是否跳转到「${_externalAppName(req.url)}」？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('网页请求打开以下外部链接：'),
              const SizedBox(height: 8),
              SelectableText(
                req.url,
                style: const TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: Colors.black87,
                ),
              ),
              if ((req.sourceUrl ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '来源页面：${req.sourceUrl}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
              const SizedBox(height: 10),
              const Text(
                '可能是第三方登录（QQ/微信/支付宝），也可能是流氓下载/拉起其它 App。'
                '确认是你要的操作再跳转。',
                style: TextStyle(fontSize: 12.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.primary,
            ),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    return allow ?? false;
  }

  String _externalAppName(String url) {
    final lower = url.toLowerCase();
    if (lower.startsWith('weixin://') || lower.startsWith('wechat://')) {
      return '微信';
    }
    if (lower.startsWith('mqq://') ||
        lower.startsWith('wtloginmqq://') ||
        lower.startsWith('qq://')) {
      return 'QQ';
    }
    if (lower.startsWith('alipays://') || lower.startsWith('alipay://')) {
      return '支付宝';
    }
    if (lower.startsWith('taobao://') || lower.startsWith('tbopen://')) {
      return '淘宝';
    }
    if (lower.startsWith('jd://') || lower.startsWith('openapp.jdmobile://')) {
      return '京东';
    }
    if (lower.startsWith('bilibili://')) {
      return '哔哩哔哩';
    }
    if (lower.startsWith('douyin://') || lower.startsWith('snssdk1128://')) {
      return '抖音';
    }
    if (lower.startsWith('intent://')) {
      final pkg = RegExp(r'[?&]package=([^&]+)').firstMatch(url)?.group(1);
      return pkg ?? 'Android 应用';
    }
    if (lower.startsWith('mailto:')) return '邮件';
    if (lower.startsWith('tel:')) return '电话';
    if (lower.startsWith('sms:')) return '短信';
    final scheme = Uri.tryParse(url)?.scheme;
    if (scheme == null || scheme.isEmpty) return '外部 App';
    return '「$scheme」App';
  }

  @override
  Widget build(BuildContext context) {
    // controllerRevision 必须参与重建：第一次 ensure() 建 WebViewController
    // 后，如果宿主不重建，WebViewWidget 就不会挂上来，open() 的第一次
    // loadRequest 发给一个还不存在的控件，表现就是转圈但地址栏/标题为空。
    return ValueListenableBuilder<int>(
      valueListenable: _engine.controllerRevision,
      builder: (context, _, __) {
        return ValueListenableBuilder<bool>(
          valueListenable: _engine.visible,
          builder: (context, visible, _) {
            return ValueListenableBuilder<BrowserWindowState>(
              valueListenable: _window,
              builder: (context, win, _) {
                // 等待提示会改变工具条高度，所以它也要参与重建。
                return ValueListenableBuilder<String>(
                  valueListenable: _engine.waitingHint,
                  builder: (context, hint, _) =>
                      _build(context, visible, win, hint),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _build(
    BuildContext context,
    bool visible,
    BrowserWindowState win,
    String hint,
  ) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final web = _engine.controller;
    final rect = _windowRect(media, win, visible);
    final chromeH = _chromeHeight(media, win, hint);
    // 内容区（网页 / 抓包 / 日志 共用这一块）。
    final content = Rect.fromLTWH(
      rect.left,
      rect.top + chromeH,
      rect.width,
      (rect.height - chromeH).clamp(0.0, double.infinity),
    );
    final radius = win.maximized ? 0.0 : 20.0;

    // Material 包一层：Overlay 里没有 Material 祖先，IconButton 的墨水扩散、
    // TextField 的填充都需要它，缺了会在点击时抛 "No Material widget found"。
    return Material(
      type: MaterialType.transparency,
      // 点这个窗口就把它抬到最上层。Listener 默认 deferToChild：
      // 只有真的落在窗口部件上的触摸才算，空白处照旧穿透给下面的页面。
      child: Listener(
        onPointerDown: (_) {
          if (visible) FloatStack.instance.raise(FloatStack.browser);
        },
        child: Stack(
          children: [
            // 窗口外壳：玻璃底 + 顶部工具条。画在 WebView **之前**，
            // 网页盖在玻璃上，而工具条区域不与网页重叠，点击不打架。
            if (visible)
              Positioned(
                left: rect.left,
                top: rect.top,
                width: rect.width,
                height: rect.height,
                child: _shell(context, win, chromeH, hint),
              ),
            // 内核本体：唯一挂点。隐藏时整体挪到屏幕外，保持挂载。
            if (web != null)
              Positioned(
                left: visible ? content.left : -size.width - 100,
                top: visible ? content.top : 0,
                width: visible ? content.width : size.width,
                height: visible ? content.height : size.height,
                child: Offstage(
                  // 切到抓包/日志时把网页藏起来但不卸载：定时器继续跑。
                  offstage: visible && _tab != 0,
                  child: RepaintBoundary(
                    key: _engine.webViewBoundaryKey,
                    child: ClipRRect(
                      borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(radius),
                      ),
                      child: WebViewWidget(controller: web),
                    ),
                  ),
                ),
              ),
            if (visible && _tab != 0)
              Positioned(
                left: content.left,
                top: content.top,
                width: content.width,
                height: content.height,
                child: ClipRRect(
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(radius),
                  ),
                  child: switch (_tab) {
                    1 => _captureList(),
                    2 => _consoleList(),
                    3 => _scriptList(),
                    4 => _devtoolsList(),
                    5 => _BookmarksPanel(
                      engine: _engine,
                      onOpenUrl: _openUrlFromPanel,
                    ),
                    6 => _HistoryPanel(
                      engine: _engine,
                      onOpenUrl: _openUrlFromPanel,
                    ),
                    7 => _ProfilePanel(engine: _engine),
                    _ => _scriptList(),
                  },
                ),
              ),
            // 缩放热区：只在悬浮态出现，最大化时没意义。
            if (visible && !win.maximized) ..._grips(rect, media),
            // 脚本编辑器：必须在最上面，且只在浏览器可见时才有意义。
            if (visible && _editing != null) _editorPanel(rect, media),
          ],
        ),
      ),
    );
  }

  /// 左右两侧的保留宽度：窗口边框永远不许贴到屏幕边。
  ///
  /// 这不是审美问题，是能不能用的问题。系统的"边缘返回"手势占着屏幕左右各
  /// 一小条，窗口边框落进去，那条边的缩放热区就永远摸不到——手指一划先被系统
  /// 吃掉当返回（在这台 MIUI 上直接把浏览器关了）。更糟的是全屏手势模式下
  /// systemGestureInsets 报 0，照它算等于没躲。所以这里取"系统报的值"和
  /// 一个够手指落下的下限里的大者。
  static const _sideKeepOut = 26.0;

  ({double left, double top, double width, double height}) _field(
    MediaQueryData media,
  ) {
    final size = media.size;
    final gesture = media.systemGestureInsets;
    final left = gesture.left > _sideKeepOut ? gesture.left : _sideKeepOut;
    final right = gesture.right > _sideKeepOut ? gesture.right : _sideKeepOut;
    final top = media.padding.top + 4;
    final bottomInset = media.padding.bottom > gesture.bottom
        ? media.padding.bottom
        : gesture.bottom;
    // 底边同理：小白条那一条要让出来，否则拖下边框会变成"回桌面"。
    final bottom =
        (bottomInset > _sideKeepOut ? bottomInset : _sideKeepOut) + 4;
    return (
      left: left,
      top: top,
      width: (size.width - left - right).clamp(1.0, size.width),
      height: (size.height - top - bottom).clamp(1.0, size.height),
    );
  }

  /// 悬浮窗几何。隐藏时返回一个屏幕外的框，省掉一堆 null 判断。
  Rect _windowRect(
    MediaQueryData media,
    BrowserWindowState win,
    bool visible,
  ) {
    final size = media.size;
    if (!visible) {
      return Rect.fromLTWH(-size.width - 100, 0, size.width, size.height);
    }
    // 最大化就是真铺满：这时候用户要的是看网页，手势冲突交给系统边缘手势本身。
    if (win.maximized) return Rect.fromLTWH(0, 0, size.width, size.height);
    final f = _field(media);
    final w = (win.w * f.width).clamp(BrowserWindow.minW * f.width, f.width);
    final h = (win.h * f.height).clamp(BrowserWindow.minH * f.height, f.height);
    var left = f.left + win.x * f.width;
    var y = f.top + win.y * f.height;
    // 键盘弹起时整窗上移：登录框在页面下半部分时最需要这个。
    final keyboard = media.viewInsets.bottom;
    if (keyboard > 0) {
      final limit = size.height - keyboard - 6 - h;
      if (y > limit) y = limit;
      if (y < f.top) y = f.top;
    }
    left = left.clamp(f.left, f.left + f.width - w);
    y = y.clamp(f.top, f.top + f.height - h);
    return Rect.fromLTWH(left, y, w, h);
  }

  /// 顶部工具条高度：最大化时要把状态栏让出来，等待提示多占一行。
  double _chromeHeight(
    MediaQueryData media,
    BrowserWindowState win,
    String hint,
  ) {
    final top = win.maximized ? media.padding.top : 0.0;
    return top + (hint.isEmpty ? 88 : 124);
  }

  Widget _shell(
    BuildContext context,
    BrowserWindowState win,
    double chromeH,
    String hint,
  ) {
    return GlassPanel(
      radius: win.maximized ? 0 : 20,
      blur: Glass.blurStrong,
      shadowY: win.maximized ? 0 : 16,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          SizedBox(height: chromeH, child: _chrome(context, win, hint)),
          // 剩下的空间交给网页/抓包层（它们是独立 Positioned，这里只占位）。
          const Expanded(child: SizedBox.shrink()),
        ],
      ),
    );
  }

  Widget _chrome(BuildContext context, BrowserWindowState win, String hint) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    // 按住工具条空白处拖窗口。最大化时不给拖，避免误触。
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanUpdate: win.maximized
          ? null
          : (d) {
              _engine.claimByUser();
              final f = _field(media);
              _window.moveBy(d.delta.dx / f.width, d.delta.dy / f.height);
            },
      onPanEnd: win.maximized ? null : (_) => _window.commit(),
      child: Padding(
        padding: EdgeInsets.only(top: win.maximized ? media.padding.top : 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _iconBtn(
                  Icons.keyboard_arrow_down_rounded,
                  '收起（页面留着，登录态不丢）',
                  () {
                    // 收起前落一次盘：用户可能刚登录完就切走，
                    // 进程被系统回收的话内存里的 cookie 就没了。
                    _engine.persist();
                    _engine.hide();
                  },
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _engine.canGoBack,
                  builder: (context, can, _) => _iconBtn(
                    Icons.arrow_back_rounded,
                    '返回上一页',
                    can ? _engine.back : null,
                  ),
                ),
                Expanded(child: _urlBar(scheme)),
                _iconBtn(Icons.refresh_rounded, '刷新', _engine.reload),
                _iconBtn(
                  Icons.more_horiz_rounded,
                  '更多',
                  _showBrowserMenu,
                ),
                _iconBtn(
                  win.maximized
                      ? Icons.close_fullscreen_rounded
                      : Icons.open_in_full_rounded,
                  win.maximized ? '缩回悬浮窗' : '最大化',
                  () {
                    HapticFeedback.selectionClick();
                    _engine.claimByUser();
                    _window.toggleMax();
                  },
                ),
              ],
            ),
            // 标签行必须能横向滚动。
            //
            // 窗口缩到最小时（minW 约占可用宽的一半），四个标签加两个按钮的
            // 固有宽度会超过这一行——Row 溢出画的就是那条黄黑斑马线，
            // 贴在窗口右边缘上。用 Spacer 顶不住：Spacer 只吃剩余空间，
            // 空间为负时照样溢出。所以让标签自己滚，右边两个按钮固定不动。
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        _tabChip('页面', 0, Icons.web_outlined),
                        const SizedBox(width: 5),
                        ValueListenableBuilder<List<CapturedRequest>>(
                          valueListenable: _engine.requests,
                          builder: (context, list, _) => _tabChip(
                            '抓包 ${list.length}',
                            1,
                            Icons.travel_explore_outlined,
                          ),
                        ),
                        const SizedBox(width: 5),
                        ValueListenableBuilder<List<ConsoleLine>>(
                          valueListenable: _engine.console,
                          builder: (context, list, _) => _tabChip(
                            '日志 ${list.length}',
                            2,
                            Icons.terminal_outlined,
                          ),
                        ),
                        const SizedBox(width: 5),
                        ValueListenableBuilder<int>(
                          valueListenable: _engine.scriptsRevision,
                          builder: (context, _, __) => _tabChip(
                            _engine.scripts.isEmpty
                                ? '脚本'
                                : '脚本 ${_engine.scripts.length}',
                            3,
                            Icons.data_object_rounded,
                          ),
                        ),
                        const SizedBox(width: 5),
                        _tabChip(
                          '开发者',
                          4,
                          Icons.developer_mode_outlined,
                        ),
                        const SizedBox(width: 5),
                        _tabChip('收藏', 5, Icons.star_border_outlined),
                        const SizedBox(width: 5),
                        _tabChip('历史', 6, Icons.history_outlined),
                        const SizedBox(width: 5),
                        _tabChip('快照', 7, Icons.account_tree_outlined),
                      ],
                    ),
                  ),
                ),
                _iconBtn(Icons.arrow_forward_rounded, '前进', _engine.forward),
                _iconBtn(
                  Icons.delete_sweep_outlined,
                  '清空抓包与日志',
                  _engine.clearCaptures,
                ),
                const SizedBox(width: 2),
              ],
            ),
            // AI 在等你接手：登录、人机验证、扫码、短信码都走这一条。
            // 没有"验证组件"——验证就是个网页，你在上面点掉就行。
            if (hint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 2, 8, 2),
                child: Row(
                  children: [
                    Icon(
                      Icons.touch_app_outlined,
                      size: 15,
                      color: Colors.orange.shade700,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        'AI 在等你：$hint',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.orange.shade800,
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        _engine.ackUser();
                      },
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 30),
                      ),
                      child: const Text(
                        '我弄好了',
                        style: TextStyle(fontSize: 11.5),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _urlBar(ColorScheme scheme) {
    return ValueListenableBuilder<String>(
      valueListenable: _engine.currentUrl,
      builder: (context, url, _) {
        if (_urlFocusIdle) _urlController.text = url;
        return SizedBox(
          height: 36,
          child: TextField(
            controller: _urlController,
            style: const TextStyle(fontSize: 12),
            textInputAction: TextInputAction.go,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
              hintText: '输入网址或搜索词',
              hintStyle: const TextStyle(fontSize: 12),
              prefixIcon: ValueListenableBuilder<bool>(
                valueListenable: _engine.loading,
                builder: (context, loading, _) => loading
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : Icon(
                        Icons.public,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
              ),
            ),
            onTap: () {
              _urlFocusIdle = false;
              _engine.claimByUser();
            },
            onTapOutside: (_) {
              if (!_urlFocusIdle) setState(() => _urlFocusIdle = true);
            },
            onSubmitted: (value) {
              _urlFocusIdle = true;
              final text = value.trim();
              if (text.isEmpty) return;
              FocusScope.of(context).unfocus();
              // 不像网址就当搜索词：普通浏览器都这么干，
              // 省掉"先去搜索引擎首页"那一步。
              // 本地路径（/workspace/a.html）必须先判，否则会被当成搜索词。
              final looksLikeUrl = BrowserEngine.isLocalTarget(text) ||
                  text.startsWith('http') ||
                  (!text.contains(' ') && text.contains('.'));
              _engine.open(
                looksLikeUrl
                    ? text
                    : 'https://www.bing.com/search?q='
                        '${Uri.encodeQueryComponent(text)}',
              );
            },
          ),
        );
      },
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback? onTap) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      padding: EdgeInsets.zero,
      icon: Icon(icon, size: 19),
    );
  }

  List<Widget> _grips(Rect rect, MediaQueryData media) {
    final f = _field(media);
    final field = Size(f.width, f.height);
    void commit() {
      _engine.claimByUser();
      _window.commit();
    }

    return [
      _Grip(
        rect: Rect.fromLTWH(rect.left, rect.top, _grip, rect.height),
        cursor: SystemMouseCursors.resizeLeftRight,
        onDrag: (d) => _window.resize(dLeft: d.dx / field.width),
        onEnd: commit,
      ),
      _Grip(
        rect: Rect.fromLTWH(
          rect.right - _grip,
          rect.top,
          _grip,
          (rect.height - _grip * 2).clamp(0.0, double.infinity),
        ),
        cursor: SystemMouseCursors.resizeLeftRight,
        onDrag: (d) => _window.resize(dRight: d.dx / field.width),
        onEnd: commit,
      ),
      _Grip(
        rect: Rect.fromLTWH(
          rect.left + _grip,
          rect.bottom - _grip,
          (rect.width - _grip * 3).clamp(0.0, double.infinity),
          _grip,
        ),
        cursor: SystemMouseCursors.resizeUpDown,
        onDrag: (d) => _window.resize(dBottom: d.dy / field.height),
        onEnd: commit,
      ),
      // 右下角给一个看得见的把手：新用户不会知道边框能拖，角上有图标就会试。
      _Grip(
        rect: Rect.fromLTWH(
          rect.right - _grip * 2,
          rect.bottom - _grip * 2,
          _grip * 2,
          _grip * 2,
        ),
        cursor: SystemMouseCursors.resizeDownRight,
        indicator: true,
        onDrag: (d) => _window.resize(
          dRight: d.dx / field.width,
          dBottom: d.dy / field.height,
        ),
        onEnd: commit,
      ),
    ];
  }

  Widget _tabChip(String label, int index, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _tab == index;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        _engine.claimByUser();
        setState(() => _tab = index);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.16)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.4)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 13,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _captureMatches(CapturedRequest r) {
    final q = _captureQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      final haystack = [
        r.method,
        r.url,
        r.status.toString(),
        r.requestBody,
        r.responseBody,
        r.requestHeaders,
        r.responseHeaders,
        r.error,
        r.contentType,
      ].join('\n').toLowerCase();
      if (!haystack.contains(q)) return false;
    }
    if (_captureFilter == 'error') {
      return r.error.isNotEmpty || r.status >= 400;
    }
    if (_captureFilter == 'json') {
      return _isJsonText(r.requestBody) || _isJsonText(r.responseBody);
    }
    return true;
  }

  static bool _isJsonText(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return false;
    if (!text.startsWith('{') && !text.startsWith('[')) return false;
    try {
      jsonDecode(text);
      return true;
    } catch (_) {
      return false;
    }
  }

  Widget _captureFilterChip(ColorScheme scheme, String value, String label) {
    final selected = _captureFilter == value;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      selected: selected,
      onSelected: (_) => setState(() => _captureFilter = value),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      selectedColor: scheme.primaryContainer,
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      side: BorderSide.none,
    );
  }

  Widget _captureList() {
    final scheme = Theme.of(context).colorScheme;
    return GlassBackdrop(
      child: ValueListenableBuilder<List<CapturedRequest>>(
        valueListenable: _engine.requests,
        builder: (context, list, _) {
          if (list.isEmpty) {
            return Center(
              child: Text(
                '还没抓到请求\n打开一个页面，它自己发的 fetch/XHR 都会记在这里',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            );
          }
          if (_detailRequest != null) {
            return _CaptureDetail(
              request: _detailRequest!,
              onBack: () => setState(() => _detailRequest = null),
              onMakeHook: () => _newScriptFrom(_detailRequest!),
            );
          }
          final filtered = [
            for (final r in list)
              if (_captureMatches(r)) r,
          ];
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
                child: TextField(
                  onChanged: (v) => setState(() => _captureQuery = v),
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: '搜索 URL / 方法 / 状态 / 请求体 / 响应体',
                    hintStyle: const TextStyle(fontSize: 11.5),
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor:
                        scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Row(
                  children: [
                    _captureFilterChip(scheme, 'all', '全部'),
                    const SizedBox(width: 6),
                    _captureFilterChip(scheme, 'error', '报错'),
                    const SizedBox(width: 6),
                    _captureFilterChip(scheme, 'json', 'JSON'),
                    const Spacer(),
                    Text(
                      '${filtered.length}/${list.length}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          '没有匹配的抓包记录',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 4, 10, 24),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) => _RequestTile(
                          request: filtered[index],
                          onOpen: () => setState(
                            () => _detailRequest = filtered[index],
                          ),
                          onMakeHook: () => _newScriptFrom(filtered[index]),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 脚本页：看得见、能改、能停用、能删。
  ///
  /// 为什么要有这一页：脚本是"长期生效且看不见"的东西——它会静默改掉用户之后
  /// 自己上网的请求。必须给一个随时能看清"现在有哪些脚本在改我的包、各改了
  /// 几个包、有没有报错、一键关掉"的地方，否则出问题根本查不出来。
  ///
  /// 可视化只是给人用的旁路：这套能力的主用户是 AI（browser_hook 工具）。
  Widget _scriptList() {
    final scheme = Theme.of(context).colorScheme;
    return GlassBackdrop(
      child: ValueListenableBuilder<int>(
        valueListenable: _engine.scriptsRevision,
        builder: (context, _, __) {
          final scripts = _engine.scripts;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        scripts.isEmpty
                            ? '没有抓包脚本，请求原样通过'
                            : '${scripts.length} 个脚本在改请求（按顺序执行）',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _newScript,
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: const Text('新建', style: TextStyle(fontSize: 11.5)),
                    ),
                    if (scripts.isNotEmpty)
                      IconButton(
                        tooltip: '清空全部脚本',
                        visualDensity: VisualDensity.compact,
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.maybeOf(
                            appNavigatorKey.currentContext ?? context,
                          );
                          await _engine.clearScripts();
                          messenger?.showSnackBar(
                            const SnackBar(
                              content: Text('已清空全部抓包脚本'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        icon: const Icon(Icons.delete_sweep_outlined, size: 17),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: scripts.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            '脚本两种写法：\n'
                            '1）onRequest(req) / onResponse(res) 改包：改地址、改头、'
                            '改请求体、改返回体、block / mock。\n'
                            '2）自启动脚本：顶部代码装 WebSocket / EventSource 监听等，'
                            '不写 onRequest/onResponse 也有效。\n\n'
                            '点「新建」自己写，或在「抓包」里点开一条请求 → '
                            '「按这个包写脚本」；AI 用 browser_hook 也能装。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.55,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 24),
                        itemCount: scripts.length,
                        itemBuilder: (context, index) =>
                            _scriptTile(scripts[index], scheme),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _scriptTile(InterceptScript script, ColorScheme scheme) {
    return GlassPanel(
      radius: 14,
      blur: 14,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
      child: Row(
        children: [
          Expanded(
            // 整块点开编辑：脚本管理器里"点一下看代码"是最常做的事。
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openEditor(script),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '#${script.id}',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            script.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: script.enabled
                                  ? null
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      [
                        script.hooks,
                        if (script.hits > 0) '改了 ${script.hits} 个包',
                        if (!script.enabled) '已停用',
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (script.error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          script.error,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Switch(
            value: script.enabled,
            onChanged: (value) =>
                _engine.updateScript(script.id, enabled: value),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '删除',
            onPressed: () => _engine.removeScript(script.id),
            icon: const Icon(Icons.close_rounded, size: 16),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 脚本编辑器

  void _openEditor(InterceptScript script) {
    _nameController.text = script.name;
    _codeController.text = script.code;
    setState(() => _editing = script);
    _attachBus(script);
  }

  void _closeEditor() {
    _detachBus();
    setState(() => _editing = null);
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 把当前打开的抓包脚本挂上编辑器总线，供 AI 的 editor_* 直接改。
  void _attachBus(InterceptScript script) {
    _detachBus();
    _busId = EditorBus.instance.register(
      kind: EditorKind.browserHook,
      title: script.name.isEmpty ? '未命名脚本' : script.name,
      path: script.id < 0 ? 'hook:new' : 'hook:${script.id}',
      controller: _codeController,
      editorKey: _codeEditorKey,
      language: 'javascript',
      save: () async {
        await _saveEditing();
        return _editing == null ? '已保存抓包脚本，并已推给页面生效。' : '保存失败（脚本无效），看编辑器上的提示。';
      },
      remove: () async {
        final current = _editing;
        if (current == null || current.id < 0) {
          return '这个脚本还没创建，直接关掉编辑器就行。';
        }
        final id = current.id;
        _closeEditor();
        final ok = await _engine.removeScript(id);
        return ok ? '已删除抓包脚本 #$id。' : '删除失败：没找到 #$id。';
      },
    );
  }

  void _detachBus() {
    final id = _busId;
    if (id == null) return;
    EditorBus.instance.unregister(id);
    _busId = null;
  }

  void _newScript() {
    _openEditor(
      InterceptScript(
        id: -1,
        name: '新脚本 ${_engine.scripts.length + 1}',
        code: interceptScriptTemplate,
      ),
    );
  }

  /// 照着一条抓到的请求起草脚本：把 URL 和方法填进 if 里，省得手抄。
  void _newScriptFrom(CapturedRequest request) {
    final path = request.shortUrl.split('?').first;
    final isRead = request.method.toUpperCase() == 'GET';
    final buffer = StringBuffer();
    if (isRead) {
      buffer.writeln('// 改这个包的返回体');
      buffer.writeln('function onResponse(res) {');
      buffer.writeln("  if (res.url.indexOf('$path') < 0) return;");
      buffer.writeln("  QL.log('命中', res.status, res.url);");
      buffer.writeln("  // res.body = res.body.replace('旧的', '新的');");
      buffer.writeln('  // var d = JSON.parse(res.body);');
      buffer.writeln('  // d.vip = true;');
      buffer.writeln('  // res.body = JSON.stringify(d);');
      buffer.writeln('}');
    } else {
      buffer.writeln('// 改这个包的请求体');
      buffer.writeln('function onRequest(req) {');
      buffer.writeln("  if (req.url.indexOf('$path') < 0) return;");
      buffer.writeln("  if (req.method !== '${request.method}') return;");
      buffer.writeln("  QL.log('命中', req.method, req.url, req.body);");
      buffer.writeln("  // req.body = req.body.replace('旧的', '新的');");
      buffer.writeln("  // req.headers['X-Debug'] = '1';");
      buffer.writeln('  // req.block = true;');
      buffer.writeln("  // req.mock = {status: 200, body: '{\"ok\":true}'};");
      buffer.writeln('}');
      buffer.writeln();
      buffer.writeln('// 也可以顺手改它的返回');
      buffer.writeln('function onResponse(res) {');
      buffer.writeln("  if (res.url.indexOf('$path') < 0) return;");
      buffer.writeln("  // res.body = res.body.replace('旧的', '新的');");
      buffer.writeln('}');
    }
    _openEditor(
      InterceptScript(
        id: -1,
        name: '${request.method} $path',
        code: buffer.toString(),
      ),
    );
  }

  Future<void> _saveEditing() async {
    final script = _editing;
    if (script == null) return;
    final name = _nameController.text.trim();
    final code = _codeController.text;
    final result = script.id < 0
        ? await _engine.addScript(name: name, code: code)
        : await _engine.updateScript(script.id, name: name, code: code);
    if (!mounted) return;
    // 失败（名字空、没钩子）就留在编辑器里，别把用户写的东西弄丢。
    if (!result.startsWith('脚本无效：')) {
      _closeEditor();
      setState(() => _tab = 3);
    }
    _toast(result);
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(
      appNavigatorKey.currentContext ?? context,
    );
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  /// 脚本编辑器面板。
  ///
  /// 为什么就地画一块而不是 showModalBottomSheet：这个宿主挂在
  /// MaterialApp.builder 的 Stack 里，画在路由 Navigator **之上**。走 Navigator
  /// 的弹窗会渲染在 Navigator 内部，也就是在浏览器窗口**下面**——弹出来了却被
  /// 浏览器整块盖住，看起来就是"点了没反应"。所以编辑器必须待在这棵子树里。
  ///
  /// 几何跟着窗口走：窗口小编辑器就小，绝不越出窗口；键盘弹起时改贴键盘上沿，
  /// 否则在小窗里根本看不见自己在写什么。
  Widget _editorPanel(Rect rect, MediaQueryData media) {
    final scheme = Theme.of(context).colorScheme;
    final script = _editing!;
    final keyboard = media.viewInsets.bottom;
    // 顶边永远让开状态栏。窗口最大化时 rect.top 是 0，照它算的话编辑器的
    // 名字输入框和「保存 / 关闭」两颗按钮正好钻到状态栏底下——看得见、点不到。
    final minTop = media.padding.top + 6;
    final wanted = keyboard > 0 ? minTop : rect.top + 6;
    final top = wanted < minTop ? minTop : wanted;
    // 底边同理让开手势条，否则最大化时最后一行代码压在小白条上。
    final minBottom = media.padding.bottom * 0.5 + 6;
    final wantedBottom =
        keyboard > 0 ? keyboard + 6 : (media.size.height - rect.bottom + 6);
    final bottom = wantedBottom < minBottom ? minBottom : wantedBottom;
    final height =
        (media.size.height - top - bottom).clamp(140.0, media.size.height);
    return Positioned(
      left: rect.left + 6,
      top: top,
      width: (rect.width - 12).clamp(1.0, media.size.width),
      height: height,
      child: GlassPanel(
        radius: 18,
        blur: Glass.blurStrong,
        padding: const EdgeInsets.fromLTRB(10, 4, 4, 6),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.data_object_rounded,
                    size: 15, color: scheme.primary),
                const SizedBox(width: 5),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      hintText: '脚本名字',
                      hintStyle: TextStyle(fontSize: 13),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭（不保存）',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: _closeEditor,
                  icon: const Icon(Icons.close_rounded, size: 17),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: _saveEditing,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    script.id < 0 ? '创建' : '保存',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CodeEditorField(
                  key: _codeEditorKey,
                  controller: _codeController,
                  path: 'hook.js',
                  initialFontSize: 12,
                  padding: const EdgeInsets.all(8),
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'onRequest(req)：改 url/method/headers/body，'
              'req.block 拦掉、req.mock 假返回；'
              'onResponse(res)：改 status/headers/body。QL.log(...) 打日志。',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                height: 1.3,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _devtoolsList() {
    return _DevToolsPanel(engine: _engine);
  }

  Widget _consoleList() {
    // 日志和可执行 JS 已合并成一个控制台：页面 console 输出 + 手动 JS 都在这。
    return GlassBackdrop(
      child: _ConsolePanel(engine: _engine),
    );
  }
}

/// 一块缩放热区。用绝对矩形而不是 Align：窗口本身是绝对定位的，
/// 热区跟着窗口边框走才不会在缩放过程中漂移。
class _Grip extends StatelessWidget {
  const _Grip({
    required this.rect,
    required this.cursor,
    required this.onDrag,
    required this.onEnd,
    this.indicator = false,
  });

  final Rect rect;
  final MouseCursor cursor;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onEnd;
  final bool indicator;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => onDrag(d.delta),
          onPanEnd: (_) => onEnd(),
          child: indicator
              ? Padding(
                  padding: const EdgeInsets.all(5),
                  child: Icon(
                    Icons.open_with_rounded,
                    size: 14,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                )
              : const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.request,
    required this.onOpen,
    this.onMakeHook,
  });

  final CapturedRequest request;
  final VoidCallback onOpen;
  final VoidCallback? onMakeHook;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = request;
    final color = r.pending
        ? scheme.onSurfaceVariant
        : (r.status >= 400 || r.error.isNotEmpty)
            ? scheme.error
            : Colors.green.shade600;
    return GlassPanel(
      radius: 14,
      blur: 14,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    r.pending ? '···' : '${r.status}',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  r.method,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (r.live) ...[
                  const SizedBox(width: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '● 通讯中',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: Colors.green.shade700,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    r.shortUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                    ),
                  ),
                ),
                if (r.ms > 0)
                  Text(
                    '${r.ms}ms',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (r.mutation.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  children: [
                    Icon(
                      Icons.published_with_changes_outlined,
                      size: 12,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '已改写：${r.mutation}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (r.responseBody.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        r.responseBody.replaceAll('\n', ' '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (onMakeHook != null)
                      IconButton(
                        tooltip: '按这个包写脚本',
                        visualDensity: VisualDensity.compact,
                        constraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        icon: const Icon(Icons.data_object_rounded),
                        onPressed: onMakeHook,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 抓包详情：像专业抓包工具一样按「总览 / 请求头 / 请求体 / 响应头 / 响应体」
/// 分 Tab 展示，正文不再截断。
class _CaptureDetail extends StatelessWidget {
  const _CaptureDetail({
    required this.request,
    required this.onBack,
    this.onMakeHook,
  });

  final CapturedRequest request;
  final VoidCallback onBack;
  final VoidCallback? onMakeHook;

  static String _sizeLabel(String text) {
    final bytes = utf8.encode(text).length;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = request;
    final color = r.pending
        ? scheme.onSurfaceVariant
        : (r.status >= 400 || r.error.isNotEmpty)
            ? scheme.error
            : Colors.green.shade600;
    if (r.kind == 'ws' || r.kind == 'sse') {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity != null &&
              details.primaryVelocity! > 250) {
            onBack();
          }
        },
        child: GlassBackdrop(
          child: _WsSessionDetail(
            request: r,
            onBack: onBack,
          ),
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 250) {
          onBack();
        }
      },
      child: GlassBackdrop(
        child: DefaultTabController(
          length: 6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 12, 2),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回列表',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                r.pending ? '···' : '${r.status}',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: color,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                r.method,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          r.url,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.2,
                            fontFamily: kMonoFamily,
                            fontFamilyFallback: kMonoFallback,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          [
                            if (r.host.isNotEmpty) r.host,
                            if (r.contentType.isNotEmpty) r.contentType,
                            if (r.ms > 0) '${r.ms} ms',
                            '响应 ${_sizeLabel(r.responseBody)}',
                            if (r.kind.isNotEmpty) r.kind,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '复制返回体',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: r.responseBody));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('返回体已复制'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                  if (onMakeHook != null)
                    IconButton(
                      tooltip: '按这个包写脚本',
                      onPressed: onMakeHook,
                      icon: const Icon(Icons.data_object_rounded),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
              unselectedLabelStyle: const TextStyle(fontSize: 12),
              indicatorSize: TabBarIndicatorSize.label,
              tabs: const [
                Tab(text: '总览'),
                Tab(text: '请求头'),
                Tab(text: '请求体'),
                Tab(text: '响应头'),
                Tab(text: '响应体'),
                Tab(text: '重发'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _OverviewTab(request: r),
                  _HeadersTab(
                    title: '请求头',
                    raw: r.requestHeaders,
                    emptyText: '（无请求头）',
                  ),
                  _BodyTab(
                    title: '请求体',
                    body: r.requestBody,
                    copyLabel: '复制请求体',
                  ),
                  _HeadersTab(
                    title: '响应头',
                    raw: r.responseHeaders,
                    emptyText: '（无响应头）',
                  ),
                  _BodyTab(
                    title: '响应体',
                    body: r.responseBody,
                    copyLabel: '复制响应体',
                  ),
                  _ReplayTab(request: r),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// WS/SSE 会话右侧的“消息结构预览图”：像代码编辑器 minimap 一样，
/// 用色条表示每条消息的位置和长短；点击/拖动某个位置，会话列表滚动到对应消息。
class _WsSessionMinimap extends StatefulWidget {
  const _WsSessionMinimap({
    required this.request,
    required this.expanded,
    required this.estimateHeight,
    required this.onTap,
    required this.scheme,
    required this.scrollFraction,
  });

  final CapturedRequest request;
  final Set<int> expanded;
  final double Function(WsMessage, int) estimateHeight;
  final ValueChanged<int> onTap;
  final ColorScheme scheme;
  final ValueListenable<double> scrollFraction;

  @override
  State<_WsSessionMinimap> createState() => _WsSessionMinimapState();
}

class _WsSessionMinimapState extends State<_WsSessionMinimap> {
  int? _activeIndex;
  bool _dragging = false;
  int _lastHapticIndex = -1;

  @override
  void initState() {
    super.initState();
    widget.scrollFraction.addListener(_syncFromScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncFromScroll();
    });
  }

  @override
  void didUpdateWidget(covariant _WsSessionMinimap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollFraction != widget.scrollFraction) {
      oldWidget.scrollFraction.removeListener(_syncFromScroll);
      widget.scrollFraction.addListener(_syncFromScroll);
    }
  }

  @override
  void dispose() {
    widget.scrollFraction.removeListener(_syncFromScroll);
    super.dispose();
  }

  List<double> _heights() => [
        for (var i = 0; i < widget.request.wsMessages.length; i++)
          widget.estimateHeight(widget.request.wsMessages[i], i),
      ];

  int? _indexAtFraction(double fraction) {
    final heights = _heights();
    final total = heights.fold<double>(0, (a, b) => a + b);
    if (total <= 0 || heights.isEmpty) return null;
    final f = fraction.clamp(0.0, 1.0).toDouble();
    var acc = 0.0;
    for (var i = 0; i < heights.length; i++) {
      acc += heights[i] / total;
      if (f <= acc) return i;
    }
    return heights.length - 1;
  }

  int? _indexAt(Offset local, Size size) {
    if (size.height <= 0) return null;
    return _indexAtFraction(local.dy / size.height);
  }

  /// 普通滑动列表时，ScrollNotification 更新 fraction，
  /// 这里把放大块同步到“当前屏幕大概位置”，实现绑定。
  void _syncFromScroll() {
    if (!mounted || _dragging) return;
    final idx = _indexAtFraction(widget.scrollFraction.value);
    if (idx != null && idx != _activeIndex) {
      setState(() => _activeIndex = idx);
    }
  }

  void _handle(Offset local, Size size) {
    final index = _indexAt(local, size);
    if (index == null) return;
    if (_activeIndex != index || !_dragging) {
      setState(() {
        _activeIndex = index;
        _dragging = true;
      });
    }
    if (index != _lastHapticIndex) {
      _lastHapticIndex = index;
      HapticFeedback.selectionClick();
    }
    widget.onTap(index);
  }

  void _end() {
    if (!_dragging) return;
    // 松手不取消选中：放大块保留在当前轴上，作为“现在大概在哪”的指示。
    setState(() => _dragging = false);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(34, constraints.maxHeight);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _handle(d.localPosition, size),
            onVerticalDragStart: (d) => _handle(d.localPosition, size),
            onVerticalDragUpdate: (d) => _handle(d.localPosition, size),
            onVerticalDragEnd: (_) => _end(),
            onVerticalDragCancel: _end,
            onTapUp: (_) => _end(),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CustomPaint(
                size: size,
                painter: _MinimapPainter(
                  heights: _heights(),
                  messages: widget.request.wsMessages,
                  scheme: widget.scheme,
                  activeIndex: _activeIndex,
                  isDragging: _dragging,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  _MinimapPainter({
    required this.heights,
    required this.messages,
    required this.scheme,
    this.activeIndex,
    this.isDragging = false,
  });

  final List<double> heights;
  final List<WsMessage> messages;
  final ColorScheme scheme;
  final int? activeIndex;
  final bool isDragging;

  static const _stepFactors = [1.0, 0.82, 0.66, 0.52, 0.40, 0.30];

  double _widthFactor(int index) {
    if (activeIndex == null) return 0.42;
    final step = (index - activeIndex!).abs();
    if (step < _stepFactors.length) return _stepFactors[step];
    return 0.24;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final total = heights.fold<double>(0, (a, b) => a + b);
    if (total <= 0 || size.height <= 0) return;
    final trackPaint = Paint()
      ..color = scheme.surfaceContainerHighest.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        const Radius.circular(8),
      ),
      trackPaint,
    );

    double? activeCenterY;
    var y = 0.0;
    for (var i = 0; i < heights.length; i++) {
      final rawH = heights[i] / total * size.height;
      final h = rawH < 2 ? 2.0 : rawH;
      if (y + h > size.height) break;
      final msg = messages[i];
      final baseColor = msg.sent
          ? scheme.primary
          : (_isSystemLike(msg)
              ? scheme.outline
              : scheme.onSurfaceVariant);
      final alpha = (activeIndex != null && i == activeIndex) ? 0.95 : 0.55;
      final paint = Paint()
        ..color = baseColor.withValues(alpha: alpha)
        ..style = PaintingStyle.fill;

      final factor = _widthFactor(i);
      final w = size.width * factor;
      final x = (size.width - w) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, w, h - 0.5),
          const Radius.circular(2),
        ),
        paint,
      );
      if (i == activeIndex) activeCenterY = y + h / 2;
      y += h;
    }

    // 选中放大镜：固定尺寸，不随消息数量缩小；松手也不消失，作为轴位置指示。
    if (activeCenterY != null) {
      final cy = activeCenterY.clamp(0.0, size.height).toDouble();
      final magnifyFill = Paint()
        ..color = scheme.primary.withValues(alpha: 0.22)
        ..style = PaintingStyle.fill;
      final magnifyStroke = Paint()
        ..color = scheme.primary.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width / 2, cy),
          width: size.width - 1,
          height: 28,
        ),
        const Radius.circular(9),
      );
      canvas.drawRRect(rect, magnifyFill);
      canvas.drawRRect(rect, magnifyStroke);
    }
  }

  static bool _isSystemLike(WsMessage m) {
    return !m.sent &&
        (m.text.startsWith('WebSocket 已连接') ||
            m.text.startsWith('SSE 已连接') ||
            m.text.contains('已关闭') ||
            m.text.startsWith('错误：'));
  }

  @override
  bool shouldRepaint(_MinimapPainter oldDelegate) =>
      oldDelegate.heights != heights ||
      oldDelegate.messages != messages ||
      oldDelegate.scheme != scheme ||
      oldDelegate.activeIndex != activeIndex ||
      oldDelegate.isDragging != isDragging;
}

class _WsSessionDetail extends StatefulWidget {
  const _WsSessionDetail({required this.request, required this.onBack});

  final CapturedRequest request;
  final VoidCallback onBack;

  @override
  State<_WsSessionDetail> createState() => _WsSessionDetailState();
}

class _WsSessionDetailState extends State<_WsSessionDetail> {
  static const _collapseThreshold = 220;
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<double> _scrollFraction = ValueNotifier(0);
  final Set<int> _expandedMessages = {};
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _scrollFraction.dispose();
    super.dispose();
  }

  String _prettyMessage(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return raw;
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        return const JsonEncoder.withIndent('  ').convert(jsonDecode(t));
      } catch (_) {}
    }
    return raw;
  }

  TextSpan _highlightWsText(String text, ColorScheme scheme) {
    final spans = <TextSpan>[];
    var i = 0;
    final plain = TextStyle(
      color: scheme.onSurface,
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
    );
    final stringColor = Colors.green.shade600;
    final keyColor = const Color(0xFF4FC1FF);
    final numberColor = const Color(0xFFD19A66);
    final boolColor = const Color(0xFFC678DD);
    final punctColor = scheme.onSurfaceVariant;

    bool isIdent(int at, String word) {
      if (at + word.length > text.length) return false;
      if (text.substring(at, at + word.length) != word) return false;
      final before = at == 0 ? '' : text[at - 1];
      final after = at + word.length >= text.length
          ? ''
          : text[at + word.length];
      return !RegExp(r'[A-Za-z0-9_]').hasMatch(before) &&
          !RegExp(r'[A-Za-z0-9_]').hasMatch(after);
    }

    while (i < text.length) {
      final ch = text[i];
      if (ch == '"') {
        final start = i;
        i++;
        final buffer = <String>[text[start]];
        while (i < text.length) {
          buffer.add(text[i]);
          if (text[i] == '\\' && i + 1 < text.length) {
            buffer.add(text[i + 1]);
            i += 2;
            continue;
          }
          if (text[i] == '"') {
            i++;
            break;
          }
          i++;
        }
        final rawToken = buffer.join();
        // 对象键后面的非空白是冒号 -> 高亮成键的颜色。
        var look = i;
        while (look < text.length && (text[look] == ' ' || text[look] == '\n' || text[look] == '\t')) {
          look++;
        }
        final isKey = look < text.length && text[look] == ':';
        spans.add(
          TextSpan(
            text: rawToken,
            style: TextStyle(color: isKey ? keyColor : stringColor),
          ),
        );
        continue;
      }
      if (ch == '-' ||
          (text.codeUnitAt(i) >= 48 && text.codeUnitAt(i) <= 57)) {
        final match = RegExp(r'-?\d+(\.\d+)?([eE][+-]?\d+)?')
            .matchAsPrefix(text, i);
        if (match != null) {
          spans.add(
            TextSpan(text: match.group(0), style: TextStyle(color: numberColor)),
          );
          i += match.group(0)!.length;
          continue;
        }
      }
      const words = ['true', 'false', 'null'];
      String? word;
      for (final w in words) {
        if (isIdent(i, w)) {
          word = w;
          break;
        }
      }
      if (word != null) {
        spans.add(
          TextSpan(text: word, style: TextStyle(color: boolColor)),
        );
        i += word.length;
        continue;
      }
      if ('{}[]:,.'.contains(ch)) {
        spans.add(TextSpan(text: ch, style: TextStyle(color: punctColor)));
        i++;
        continue;
      }
      final start = i;
      while (i < text.length &&
          text[i] != '"' &&
          !'{}[]:,.'.contains(text[i]) &&
          !(text.codeUnitAt(i) >= 48 && text.codeUnitAt(i) <= 57)) {
        i++;
      }
      if (i == start) {
        spans.add(TextSpan(text: text[i], style: plain));
        i++;
      } else {
        spans.add(TextSpan(text: text.substring(start, i), style: plain));
      }
    }
    return TextSpan(children: spans);
  }

  void _copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('消息已复制'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 160,
      ),
    );
  }

  bool _isSystemMessage(WsMessage m) {
    return !m.sent &&
        (m.text.startsWith('WebSocket 已连接') ||
            m.text.startsWith('SSE 已连接') ||
            m.text.contains('已关闭') ||
            m.text.startsWith('错误：'));
  }

  bool _isLongMessage(String text) => text.length > _collapseThreshold;

  String _previewText(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  void _toggleExpanded(int index) {
    setState(() {
      if (!_expandedMessages.remove(index)) _expandedMessages.add(index);
    });
  }

  /// 估算每条消息在 ListView 里占的高度，用于 minimap 分段和点击跳转。
  /// 不需要精确到像素，能按消息长短分档即可。
  double _estimateMessageHeight(WsMessage m, int index) {
    if (_isSystemMessage(m)) return 28;
    final pretty = _prettyMessage(m.text);
    final full = _expandedMessages.contains(index) || pretty.length <= _collapseThreshold;
    final chars = full ? pretty.length : _collapseThreshold;
    final lines = (chars / 40).ceil().clamp(1, 2000);
    return 34 + lines * 16.5;
  }

  void _scrollToMessage(int index) {
    final msgs = widget.request.wsMessages;
    if (index < 0 || index >= msgs.length) return;
    if (!_scrollController.hasClients) return;
    var estTotal = 0.0;
    for (var i = 0; i < msgs.length; i++) {
      estTotal += _estimateMessageHeight(msgs[i], i);
    }
    if (estTotal <= 0) return;
    var acc = 0.0;
    for (var i = 0; i < index; i++) {
      acc += _estimateMessageHeight(msgs[i], i);
    }
    // 归一化成比例再乘真实滚动范围：展开/折叠导致估算总高和真实高度不一致时，
    // 点击仍然落在整条消息流对应的“比例位置”，不会越拉越偏。
    final target = (acc / estTotal) * _scrollController.position.maxScrollExtent;
    // minimap 拖动用 jumpTo：手指滑到哪，列表立刻跟到哪，像滚动条。
    _scrollController.jumpTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
    );
  }

  Future<void> _send() async {
    final data = _controller.text;
    if (data.isEmpty || widget.request.connId.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    final result = await BrowserEngine.instance.wsSend(
      widget.request.connId,
      data,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (result == 'sent') {
      _controller.clear();
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(result == 'sent' ? '已发送' : '发送失败：$result'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 220,
      ),
    );
  }

  Future<void> _close() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = widget.request.kind == 'ws'
        ? await BrowserEngine.instance.wsClose(widget.request.connId)
        : await BrowserEngine.instance.sseClose(widget.request.connId);
    messenger.showSnackBar(
      SnackBar(
        content: Text(result == 'closed' ? '已断开' : '断开失败：$result'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 220,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = widget.request;
    final isWs = r.kind == 'ws';
    final color = r.live
        ? Colors.green.shade600
        : (r.error.isNotEmpty ? scheme.error : scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 12, 2),
          child: Row(
            children: [
              IconButton(
                tooltip: '返回列表',
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back_rounded),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            r.live ? '● 通讯中' : '已结束',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: color,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isWs ? 'WebSocket' : 'SSE',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      r.url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.2,
                        color: scheme.onSurfaceVariant,
                        fontFamily: kMonoFamily,
                        fontFamilyFallback: kMonoFallback,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '连接 ID：${r.connId.isEmpty ? '未知' : r.connId}'
                      ' · 共 ${r.wsMessages.length} 条消息'
                      ' · 发送 ${r.wsMessages.where((m) => m.sent).length}'
                      ' / 接收 ${r.wsMessages.where((m) => !m.sent).length}',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (r.live) ...[
                IconButton(
                  tooltip: '主动断开${isWs ? ' WebSocket' : ' SSE'}',
                  visualDensity: VisualDensity.compact,
                  onPressed: _close,
                  icon: Icon(
                    Icons.link_off_rounded,
                    size: 16,
                    color: scheme.error,
                  ),
                ),
              ],
              IconButton(
                tooltip: '复制会话信息',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy_rounded, size: 16),
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(
                      text: [
                        r.url,
                        for (final m in r.wsMessages)
                          (m.sent ? '↑ ' : '↓ ') + m.text,
                      ].join('\n'),
                    ),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('会话内容已复制'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: r.wsMessages.isEmpty
              ? Center(
                  child: Text(
                    isWs ? '等待 WebSocket 消息…' : '等待 SSE 推送…',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : Row(
                  children: [
                    Expanded(
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          final m = n.metrics;
                          if (m.maxScrollExtent > 0) {
                            _scrollFraction.value =
                                (m.pixels / m.maxScrollExtent)
                                    .clamp(0.0, 1.0)
                                    .toDouble();
                          }
                          return false;
                        },
                        child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(10, 4, 6, 8),
                        itemCount: r.wsMessages.length,
                        itemBuilder: (context, index) {
                          final m = r.wsMessages[index];
                          final isSystem = _isSystemMessage(m);
                          if (isSystem) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.surfaceContainerHighest
                                        .withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: scheme.outlineVariant
                                          .withValues(alpha: 0.2),
                                      width: 0.5,
                                    ),
                                  ),
                                  child: Text(
                                    m.text,
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }
                          final time =
                              '${m.at.hour.toString().padLeft(2, '0')}:'
                              '${m.at.minute.toString().padLeft(2, '0')}:'
                              '${m.at.second.toString().padLeft(2, '0')}';
                          final pretty = _prettyMessage(m.text);
                          final long = _isLongMessage(pretty);
                          final expanded = _expandedMessages.contains(index);
                          final shown = long && !expanded
                              ? _previewText(pretty, 160)
                              : pretty;
                          final bubbleColor = m.sent
                              ? scheme.primaryContainer.withValues(alpha: 0.7)
                              : scheme.surfaceContainerHighest.withValues(alpha: 0.85);
                          final border = m.sent
                              ? Border.all(
                                  color: scheme.primary.withValues(alpha: 0.18),
                                  width: 1,
                                )
                              : Border.all(
                                  color: scheme.outlineVariant.withValues(alpha: 0.22),
                                  width: 1,
                                );
                          return Align(
                            alignment: m.sent
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              constraints: BoxConstraints(
                                maxWidth: MediaQuery.of(context).size.width * 0.72,
                              ),
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              padding: const EdgeInsets.fromLTRB(9, 5, 4, 5),
                              decoration: BoxDecoration(
                                color: bubbleColor,
                                borderRadius: BorderRadius.circular(11),
                                border: border,
                              ),
                              child: Column(
                                crossAxisAlignment: m.sent
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        m.sent
                                            ? Icons.arrow_upward_rounded
                                            : Icons.arrow_downward_rounded,
                                        size: 11,
                                        color: m.sent
                                            ? scheme.primary
                                            : scheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        '${m.sent ? '发送' : '接收'}  $time',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w600,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(width: 2),
                                      InkWell(
                                        borderRadius: BorderRadius.circular(4),
                                        onTap: () => _copyText(m.text),
                                        child: Padding(
                                          padding: const EdgeInsets.all(2),
                                          child: Icon(
                                            Icons.copy_rounded,
                                            size: 12,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Padding(
                                    padding: const EdgeInsets.only(right: 5),
                                    child: SelectableText.rich(
                                      _highlightWsText(shown, scheme),
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        height: 1.45,
                                        fontFamily: kMonoFamily,
                                        fontFamilyFallback: kMonoFallback,
                                      ),
                                    ),
                                  ),
                                  if (long)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(6),
                                        onTap: () => _toggleExpanded(index),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 3,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                expanded
                                                    ? Icons.unfold_less_rounded
                                                    : Icons.unfold_more_rounded,
                                                size: 13,
                                                color: scheme.primary,
                                              ),
                                              const SizedBox(width: 2),
                                              Text(
                                                expanded
                                                    ? '收起'
                                                    : '展开完整（${pretty.length} 字符）',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w600,
                                                  color: scheme.primary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      ),
                    ),
                    if (r.wsMessages.length > 1)
                      _WsSessionMinimap(
                        request: r,
                        expanded: _expandedMessages,
                        estimateHeight: _estimateMessageHeight,
                        onTap: _scrollToMessage,
                        scheme: scheme,
                        scrollFraction: _scrollFraction,
                      ),
                  ],
                ),
        ),
        if (isWs) ...[
          Container(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.6),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                    ),
                    decoration: InputDecoration(
                      hintText: r.live ? '输入要发送的消息' : '连接已结束',
                      isDense: true,
                      filled: true,
                      fillColor:
                          scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => r.live ? _send() : null,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  tooltip: '发送',
                  onPressed: r.live && !_sending ? _send : null,
                  icon: _sending
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded, size: 16),
                ),
                if (r.live) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '关闭连接',
                    onPressed: _close,
                    icon: const Icon(Icons.close_rounded, size: 16),
                  ),
                ],
              ],
            ),
          ),
        ] else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Text(
              'SSE 是单向服务端推送，不支持主动发送数据。',
              style: TextStyle(
                fontSize: 10.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.request});

  final CapturedRequest request;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = request;
    final rows = <(String, String, bool)>[
      ('URL', r.url, true),
      ('请求方式', r.method, true),
      ('状态码', r.pending ? '等待响应' : '${r.status}', true),
      ('主机', r.host, true),
      ('类型', r.contentType.isEmpty ? r.kind : '${r.kind} · ${r.contentType}', true),
      ('耗时', r.ms > 0 ? '${r.ms} ms' : '—', false),
      ('请求体大小', _bodySize(r.requestBody), false),
      ('响应体大小', _bodySize(r.responseBody), false),
      if (r.error.isNotEmpty) ('错误', r.error, true),
      if (r.mutation.isNotEmpty) ('已被脚本改写', r.mutation, true),
    ];
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (context, index) {
        final (label, value, mono) = rows[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 90,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: SelectableText(
                  value.isEmpty ? '—' : value,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    fontFamily: mono ? kMonoFamily : null,
                    fontFamilyFallback: mono ? kMonoFallback : null,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _bodySize(String body) {
    final bytes = utf8.encode(body).length;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class _HeadersTab extends StatelessWidget {
  const _HeadersTab({
    required this.title,
    required this.raw,
    required this.emptyText,
  });

  final String title;
  final String raw;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: lines.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: scheme.outlineVariant.withValues(alpha: 0.4),
      ),
      itemBuilder: (context, index) {
        final line = lines[index];
        final split = line.indexOf(':');
        final key = split <= 0 ? line.trim() : line.substring(0, split).trim();
        final value = split <= 0 ? '' : line.substring(split + 1).trim();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: Text(
                  key,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                  ),
                ),
              ),
              Expanded(
                child: SelectableText(
                  value,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: scheme.onSurface,
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _BodyViewMode { tree, formatted, raw, hex }

class _BodyTab extends StatefulWidget {
  const _BodyTab({
    required this.title,
    required this.body,
    required this.copyLabel,
  });

  final String title;
  final String body;
  final String copyLabel;

  @override
  State<_BodyTab> createState() => _BodyTabState();
}

class _BodyTabState extends State<_BodyTab> {
  late final bool _isJson = _isJsonText(widget.body);
  late _BodyViewMode _mode = _isJson ? _BodyViewMode.tree : _BodyViewMode.raw;

  static bool _isJsonText(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return false;
    if (!text.startsWith('{') && !text.startsWith('[')) return false;
    try {
      jsonDecode(text);
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _hexDump(String text) {
    final bytes = utf8.encode(text);
    final sb = StringBuffer();
    for (var i = 0; i < bytes.length; i += 16) {
      sb
        ..write(i.toRadixString(16).padLeft(8, '0'))
        ..write('  ');
      for (var j = 0; j < 16; j++) {
        if (i + j < bytes.length) {
          sb.write(bytes[i + j].toRadixString(16).padLeft(2, '0'));
        } else {
          sb.write('  ');
        }
        sb.write(j == 7 ? '  ' : ' ');
      }
      sb.write('  |');
      for (var j = 0; j < 16 && i + j < bytes.length; j++) {
        final c = bytes[i + j];
        sb.write(c >= 32 && c < 127 ? String.fromCharCode(c) : '.');
      }
      sb.writeln('|');
    }
    return sb.toString().trimRight();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = widget.body;
    if (body.isEmpty) {
      return Center(
        child: Text(
          '（无）',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }
    final pretty = _isJson
        ? const JsonEncoder.withIndent('  ').convert(jsonDecode(body.trim()))
        : body;
    final shown = switch (_mode) {
      _BodyViewMode.tree => pretty,
      _BodyViewMode.formatted => pretty,
      _BodyViewMode.raw => body,
      _BodyViewMode.hex => _hexDump(body),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_sizeLabel(body)} · ${body.split('\n').length} 行'
                  '${_isJson ? ' · JSON' : ''}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: body));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('${widget.title}已复制'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 14),
                label: Text(
                  widget.copyLabel,
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ToggleButtons(
              isSelected: _isJson
                  ? [
                      _mode == _BodyViewMode.tree,
                      _mode == _BodyViewMode.formatted,
                      _mode == _BodyViewMode.raw,
                      _mode == _BodyViewMode.hex,
                    ]
                  : [
                      _mode == _BodyViewMode.formatted,
                      _mode == _BodyViewMode.raw,
                      _mode == _BodyViewMode.hex,
                    ],
              onPressed: (i) => setState(() {
                _mode = _isJson
                    ? _BodyViewMode.values[i]
                    : _BodyViewMode.values[i + 1];
              }),
              constraints: const BoxConstraints(minHeight: 26, minWidth: 52),
              children: _isJson
                  ? const [
                      Text('树形'),
                      Text('格式化'),
                      Text('原始'),
                      Text('HEX'),
                    ]
                  : const [
                      Text('格式化'),
                      Text('原始'),
                      Text('HEX'),
                    ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            child: _mode == _BodyViewMode.tree
                ? _JsonTreeView(root: jsonDecode(body.trim()))
                : _mode == _BodyViewMode.hex
                    ? SelectableText(
                        shown,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.35,
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                          color: scheme.onSurface,
                        ),
                      )
                    : SelectableText.rich(
                        _isJson
                            ? _jsonSpan(shown, scheme)
                            : TextSpan(text: shown),
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.35,
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                          color: scheme.onSurface,
                        ),
                      ),
          ),
        ),
      ],
    );
  }

  TextSpan _jsonSpan(String text, ColorScheme scheme) {
    final spans = <TextSpan>[];
    var i = 0;

    void push(String value, Color color) {
      if (value.isEmpty) return;
      spans.add(
        TextSpan(
          text: value,
          style: TextStyle(color: color),
        ),
      );
    }

    while (i < text.length) {
      final ch = text[i];
      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
        final start = i;
        while (i < text.length &&
            (text[i] == ' ' ||
                text[i] == '\t' ||
                text[i] == '\r' ||
                text[i] == '\n')) {
          i++;
        }
        push(text.substring(start, i), scheme.onSurfaceVariant);
        continue;
      }
      if ('{}[],:'.contains(ch)) {
        push(ch, scheme.outline);
        i++;
        continue;
      }
      if (ch == '"') {
        final start = i;
        i++;
        while (i < text.length) {
          if (text[i] == '\\' && i + 1 < text.length) {
            i += 2;
            continue;
          }
          if (text[i] == '"') {
            i++;
            break;
          }
          i++;
        }
        final token = text.substring(start, i);
        var j2 = i;
        while (j2 < text.length && (text[j2] == ' ' || text[j2] == '\t')) {
          j2++;
        }
        final isKey = j2 < text.length && text[j2] == ':';
        push(token, isKey ? scheme.primary : Colors.green.shade600);
        continue;
      }
      final rest = text.substring(i);
      final numMatch =
          RegExp(r'^-?\d+(\.\d+)?([eE][+-]?\d+)?').firstMatch(rest);
      if (numMatch != null) {
        push(numMatch.group(0)!, Colors.orange.shade700);
        i += numMatch.group(0)!.length;
        continue;
      }
      if (rest.startsWith('true') ||
          rest.startsWith('false') ||
          rest.startsWith('null')) {
        final word = rest.startsWith('true')
            ? 'true'
            : (rest.startsWith('false') ? 'false' : 'null');
        push(word, Colors.redAccent);
        i += word.length;
        continue;
      }
      push(ch, scheme.onSurface);
      i++;
    }
    return TextSpan(children: spans);
  }

  static String _sizeLabel(String text) {
    final bytes = utf8.encode(text).length;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}


/// 可折叠的 JSON 树：长属性、深层嵌套都能收起来，只留一条摘要。
class _JsonTreeView extends StatefulWidget {
  const _JsonTreeView({required this.root});

  final dynamic root;

  @override
  State<_JsonTreeView> createState() => _JsonTreeViewState();
}

class _JsonTreeViewState extends State<_JsonTreeView> {
  late final _JsonNode _root = _JsonNode(
    key: null,
    value: widget.root,
    expanded: true,
  );

  void _toggle(_JsonNode node) {
    setState(() => node.expanded = !node.expanded);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildNode(_root, 0, scheme),
      ],
    );
  }

  Widget _buildNode(_JsonNode node, int depth, ColorScheme scheme) {
    final indent = depth * 16.0;
    final container = node.value is Map || node.value is List;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: container ? () => _toggle(node) : null,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: EdgeInsets.only(left: 4 + indent, top: 1.5, bottom: 1.5, right: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 20,
                  child: container
                      ? Icon(
                          node.expanded
                              ? Icons.expand_more_rounded
                              : Icons.chevron_right_rounded,
                          size: 17,
                          color: scheme.onSurfaceVariant,
                        )
                      : null,
                ),
                if (node.key != null) ...[
                  Flexible(
                    child: Builder(
                      builder: (context) {
                        final key = node.key!;
                        return Text(
                          key.endsWith(']') ? key : '$key:',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontFamily: kMonoFamily,
                            fontFamilyFallback: kMonoFallback,
                            color: scheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    _preview(node),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                      color: _valueColor(node.value, scheme),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (container && node.expanded)
          for (final child in node.children) _buildNode(child, depth + 1, scheme),
      ],
    );
  }

  String _preview(_JsonNode node) {
    final v = node.value;
    if (v is Map) {
      final count = v.length;
      return node.expanded ? '{...}' : '{ $count 项 }';
    }
    if (v is List) {
      final count = v.length;
      return node.expanded ? '[...]' : '[ $count 项 ]';
    }
    final text = v.toString();
    if (text.length <= 80) return text;
    return '${text.substring(0, 77)}…';
  }

  Color _valueColor(dynamic value, ColorScheme scheme) {
    if (value is String) return Colors.green.shade600;
    if (value is num) return Colors.orange.shade700;
    if (value is bool) return Colors.redAccent;
    if (value == null) return scheme.outline;
    return scheme.onSurface;
  }
}

class _JsonNode {
  _JsonNode({
    required this.key,
    required this.value,
    required this.expanded,
  });

  final String? key;
  final dynamic value;
  bool expanded;

  late final List<_JsonNode> children = _buildChildren();

  List<_JsonNode> _buildChildren() {
    if (value is Map) {
      final map = value as Map;
      return [
        for (final entry in map.entries)
          _JsonNode(
            key: entry.key.toString(),
            value: entry.value,
            expanded: false,
          ),
      ];
    }
    if (value is List) {
      final list = value as List;
      return [
        for (var i = 0; i < list.length; i++)
          _JsonNode(key: '[$i]', value: list[i], expanded: false),
      ];
    }
    return const [];
  }
}

/// 重发请求：可以改方法、URL、请求头、请求体，改完直接发出去看结果。
class _ReplayTab extends StatefulWidget {
  const _ReplayTab({required this.request});

  final CapturedRequest request;

  @override
  State<_ReplayTab> createState() => _ReplayTabState();
}

class _ReplayTabState extends State<_ReplayTab> {
  late final TextEditingController _methodController =
      TextEditingController(text: widget.request.method);
  late final TextEditingController _urlController =
      TextEditingController(text: widget.request.url);
  late final TextEditingController _headersController =
      TextEditingController(text: widget.request.requestHeaders);
  late final TextEditingController _bodyController =
      TextEditingController(text: widget.request.requestBody);
  final TextEditingController _wsController = TextEditingController();

  ReplayResult? _result;
  bool _busy = false;
  bool _wsBusy = false;

  @override
  void dispose() {
    _methodController.dispose();
    _urlController.dispose();
    _headersController.dispose();
    _bodyController.dispose();
    _wsController.dispose();
    super.dispose();
  }

  Map<String, String> _parseHeaders(String raw) {
    final map = <String, String>{};
    for (final line in raw.split('\n')) {
      final l = line.trim();
      if (l.isEmpty) continue;
      final i = l.indexOf(':');
      if (i <= 0) continue;
      map[l.substring(0, i).trim()] = l.substring(i + 1).trim();
    }
    return map;
  }

  Widget _wsSendView(ColorScheme scheme) {
    final r = widget.request;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            children: [
              Text(
                'WebSocket 连接',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '连接 ID：${r.connId.isEmpty ? '未知' : r.connId}',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                ),
              ),
              Text(
                r.url,
                style: TextStyle(
                  fontSize: 10.5,
                  color: scheme.onSurfaceVariant,
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _wsController,
                maxLines: 4,
                minLines: 2,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                ),
                decoration: const InputDecoration(
                  labelText: '要发送的数据',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _wsBusy ? null : _sendWs,
                      icon: _wsBusy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded, size: 16),
                      label: Text(_wsBusy ? '发送中…' : '发送到连接'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _closeWs,
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: const Text('关闭'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '发送后抓包列表会新增一条「WS ↑ 发送」记录；服务端回包会出现「WS ↓ 接收」。',
                style: TextStyle(
                  fontSize: 10.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _sendWs() async {
    final data = _wsController.text;
    if (widget.request.connId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('这条记录没有连接 ID，无法发送'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _wsBusy = true);
    final result = await BrowserEngine.instance.wsSend(
      widget.request.connId,
      data,
    );
    if (!mounted) return;
    setState(() => _wsBusy = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(result == 'sent' ? '已发送到 WebSocket' : '发送失败：$result'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 260,
      ),
    );
  }

  Future<void> _closeWs() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await BrowserEngine.instance.wsClose(widget.request.connId);
    messenger.showSnackBar(
      SnackBar(
        content: Text(result == 'closed' ? '已关闭 WebSocket' : '关闭结果：$result'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 260,
      ),
    );
  }

  Future<void> _send() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('URL 不能为空'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _result = null;
    });
    final result = await BrowserEngine.instance.replay(
      method: _methodController.text.trim().isEmpty
          ? 'GET'
          : _methodController.text.trim().toUpperCase(),
      url: url,
      headers: _parseHeaders(_headersController.text),
      body: _bodyController.text,
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = _result == null
        ? scheme.onSurfaceVariant
        : (_result!.error.isNotEmpty || _result!.statusCode >= 400)
            ? scheme.error
            : Colors.green.shade600;
    if (widget.request.kind == 'ws') {
      return _wsSendView(scheme);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            children: [
              Text(
                '修改参数后重发',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 92,
                    child: TextField(
                      controller: _methodController,
                      style: const TextStyle(fontSize: 12),
                      decoration: const InputDecoration(
                        labelText: '方法',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      style: const TextStyle(fontSize: 12),
                      decoration: const InputDecoration(
                        labelText: 'URL',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _headersController,
                maxLines: 5,
                minLines: 3,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                ),
                decoration: const InputDecoration(
                  labelText: '请求头（每行一个 key: value）',
                  isDense: true,
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _bodyController,
                maxLines: 8,
                minLines: 4,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                ),
                decoration: const InputDecoration(
                  labelText: '请求体',
                  isDense: true,
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _send,
                      icon: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded, size: 16),
                      label: Text(_busy ? '发送中…' : '发送'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ),
              if (_result != null) ...[
                const SizedBox(height: 8),
                Text(
                  'HTTP ${_result!.statusCode} · ${_result!.ms} ms'
                  '${_result!.error.isEmpty ? '' : ' · ${_result!.error}'}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: statusColor,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_result != null)
          SizedBox(
            height: 260,
            child: _BodyTab(
              title: '重发响应',
              body: _result!.body,
              copyLabel: '复制响应体',
            ),
          ),
      ],
    );
  }
}

/// 浏览器开发者面板：Cookie / localStorage / 可执行 JS 的控制台。
class _DevToolsPanel extends StatefulWidget {
  const _DevToolsPanel({required this.engine});

  final BrowserEngine engine;

  @override
  State<_DevToolsPanel> createState() => _DevToolsPanelState();
}

class _DevToolsPanelState extends State<_DevToolsPanel> {
  int _subTab = 0;

  @override
  Widget build(BuildContext context) {
    return GlassBackdrop(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _chip(0, 'Cookie', Icons.cookie_outlined),
                  const SizedBox(width: 6),
                  _chip(1, 'LocalStorage', Icons.storage_outlined),
                  const SizedBox(width: 6),
                  _chip(2, 'SessionStorage', Icons.data_usage_outlined),
                  const SizedBox(width: 6),
                  _chip(3, '控制台', Icons.terminal_outlined),
                  const SizedBox(width: 6),
                  _chip(4, 'UA', Icons.badge_outlined),
                  const SizedBox(width: 6),
                  _chip(5, '代理', Icons.vpn_lock_outlined),
                ],
              ),
            ),
          ),
          Expanded(
            child: switch (_subTab) {
              0 => _CookiePanel(engine: widget.engine),
              1 => _StoragePanel(
                key: const ValueKey('local-storage-panel'),
                engine: widget.engine,
                session: false,
              ),
              2 => _StoragePanel(
                key: const ValueKey('session-storage-panel'),
                engine: widget.engine,
                session: true,
              ),
              3 => _ConsolePanel(engine: widget.engine),
              4 => _UaPanel(engine: widget.engine),
              _ => _ProxyPanel(engine: widget.engine),
            },
          ),
        ],
      ),
    );
  }

  Widget _chip(int index, String label, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _subTab == index;
    return ChoiceChip(
      avatar: Icon(icon, size: 15),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      selected: selected,
      onSelected: (_) => setState(() => _subTab = index),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      selectedColor: scheme.primaryContainer,
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      side: BorderSide.none,
    );
  }
}

class _CookiePanel extends StatefulWidget {
  const _CookiePanel({required this.engine});

  final BrowserEngine engine;

  @override
  State<_CookiePanel> createState() => _CookiePanelState();
}

class _CookiePanelState extends State<_CookiePanel> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.engine.cookieRows();
  }

  void _reload() {
    setState(() => _future = widget.engine.cookieRows());
  }

  String get _url => widget.engine.currentUrl.value;

  Future<void> _edit([Map<String, dynamic>? row]) async {
    final nameController =
        TextEditingController(text: row?['name']?.toString() ?? '');
    final valueController =
        TextEditingController(text: row?['value']?.toString() ?? '');
    final pathController =
        TextEditingController(text: row?['path']?.toString() ?? '/');
    final domainController = TextEditingController(
      text: (row?['domain'] ?? row?['host'])?.toString() ?? _hostOf(_url),
    );
    var secure = row?['secure'] == true;
    var httpOnly = row?['httpOnly'] == true;

    final ok = await showBrowserDialog<bool>(
      context: context,
      builder: (dialogContext, pop) => AlertDialog(
        title: Text(row == null ? '添加 Cookie' : '编辑 Cookie'),
        content: StatefulBuilder(
          builder: (dialogContext, setDialogState) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  controller: valueController,
                  decoration: const InputDecoration(labelText: 'Value'),
                ),
                TextField(
                  controller: pathController,
                  decoration: const InputDecoration(labelText: 'Path'),
                ),
                TextField(
                  controller: domainController,
                  decoration: const InputDecoration(labelText: 'Domain'),
                ),
                CheckboxListTile(
                  value: secure,
                  onChanged: (v) => setDialogState(() => secure = v ?? false),
                  title: const Text('Secure'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  value: httpOnly,
                  onChanged: (v) => setDialogState(() => httpOnly = v ?? false),
                  title: const Text('HttpOnly'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final name = nameController.text.trim();
    if (name.isEmpty) return;
    final value = valueController.text;
    final path = pathController.text.trim().isEmpty ? '/' : pathController.text.trim();
    final domain = domainController.text.trim();
    var cookie = '$name=$value; Path=$path';
    if (domain.isNotEmpty) cookie += '; Domain=$domain';
    if (secure) cookie += '; Secure';
    if (httpOnly) cookie += '; HttpOnly';
    await widget.engine.putCookie(
      _url.isEmpty ? 'http://$domain/' : _url,
      cookie,
    );
    _reload();
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final name = row['name']?.toString() ?? '';
    final path = row['path']?.toString() ?? '/';
    final domain = (row['domain'] ?? row['host'])?.toString() ?? _hostOf(_url);
    if (name.isEmpty) return;
    await widget.engine.putCookie(
      _url.isEmpty ? 'http://$domain/' : _url,
      '$name=; Max-Age=0; Path=$path; Domain=$domain',
    );
    _reload();
  }

  static String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _url.isEmpty ? '打开页面后管理当前站点 Cookie' : _url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add_rounded, size: 15),
                label: const Text('添加', style: TextStyle(fontSize: 11.5)),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _reload,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, size: 16),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snap.data ?? const [];
              if (rows.isEmpty) {
                return Center(
                  child: Text(
                    '这个站点还没有 Cookie',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 24),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  final name = row['name']?.toString() ?? '';
                  final value = row['value']?.toString() ?? '';
                  final flags = <String>[
                    if (row['httpOnly'] == true) 'HttpOnly',
                    if (row['secure'] == true) 'Secure',
                    if ((row['path']?.toString() ?? '').isNotEmpty)
                      row['path'].toString(),
                  ];
                  return GlassPanel(
                    radius: 10,
                    blur: 12,
                    margin: const EdgeInsets.only(bottom: 5),
                    padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.primary,
                                  fontFamily: kMonoFamily,
                                  fontFamilyFallback: kMonoFallback,
                                ),
                              ),
                              const SizedBox(height: 2),
                              SelectableText(
                                value,
                                style: const TextStyle(
                                  fontSize: 11,
                                  height: 1.25,
                                  fontFamily: kMonoFamily,
                                  fontFamilyFallback: kMonoFallback,
                                ),
                              ),
                              if (flags.isNotEmpty)
                                Text(
                                  flags.join(' · '),
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '编辑',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          iconSize: 15,
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _edit(row),
                        ),
                        IconButton(
                          tooltip: '删除',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          iconSize: 15,
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(row),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _StoragePanel extends StatefulWidget {
  const _StoragePanel({
    super.key,
    required this.engine,
    this.session = false,
  });

  final BrowserEngine engine;
  final bool session;

  @override
  State<_StoragePanel> createState() => _StoragePanelState();
}

class _StoragePanelState extends State<_StoragePanel> {
  late Future<List<Map<String, String>>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.session
        ? widget.engine.sessionStorageRows()
        : widget.engine.localStorageRows();
  }

  void _reload() {
    setState(() {
      _future = widget.session
          ? widget.engine.sessionStorageRows()
          : widget.engine.localStorageRows();
    });
  }

  Future<void> _edit([Map<String, String>? row]) async {
    final keyController =
        TextEditingController(text: row?['key'] ?? '');
    final valueController =
        TextEditingController(text: row?['value'] ?? '');
    final ok = await showBrowserDialog<bool>(
      context: context,
      builder: (dialogContext, pop) => AlertDialog(
        title: Text(row == null ? '添加 localStorage' : '编辑 localStorage'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: keyController,
              decoration: const InputDecoration(labelText: 'Key'),
            ),
            TextField(
              controller: valueController,
              decoration: const InputDecoration(labelText: 'Value'),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final key = keyController.text.trim();
    if (key.isEmpty) return;
    if (widget.session) {
      await widget.engine.sessionStorageSet(key, valueController.text);
    } else {
      await widget.engine.localStorageSet(key, valueController.text);
    }
    _reload();
  }

  Future<void> _delete(Map<String, String> row) async {
    if (widget.session) {
      await widget.engine.sessionStorageRemove(row['key'] ?? '');
    } else {
      await widget.engine.localStorageRemove(row['key'] ?? '');
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.session
                      ? '当前页面 origin 的 sessionStorage'
                      : '当前页面 origin 的 localStorage',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add_rounded, size: 15),
                label: const Text('添加', style: TextStyle(fontSize: 11.5)),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _reload,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, size: 16),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, String>>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snap.data ?? const [];
              if (rows.isEmpty) {
                return Center(
                  child: Text(
                    widget.session
                        ? '这个站点还没有 sessionStorage'
                        : '这个站点还没有 localStorage',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 24),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  return GlassPanel(
                    radius: 10,
                    blur: 12,
                    margin: const EdgeInsets.only(bottom: 5),
                    padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                row['key'] ?? '',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.primary,
                                  fontFamily: kMonoFamily,
                                  fontFamilyFallback: kMonoFallback,
                                ),
                              ),
                              const SizedBox(height: 2),
                              SelectableText(
                                row['value'] ?? '',
                                style: const TextStyle(
                                  fontSize: 11,
                                  height: 1.25,
                                  fontFamily: kMonoFamily,
                                  fontFamilyFallback: kMonoFallback,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '编辑',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          iconSize: 15,
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _edit(row),
                        ),
                        IconButton(
                          tooltip: '删除',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          iconSize: 15,
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(row),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _UaPanel extends StatefulWidget {
  const _UaPanel({required this.engine});

  final BrowserEngine engine;

  @override
  State<_UaPanel> createState() => _UaPanelState();
}

class _UaPanelState extends State<_UaPanel> {
  final TextEditingController _controller = TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _select(String ua) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.engine.setUserAgent(ua);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('已切换到该 UA（刷新页面后完全生效）'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 280,
      ),
    );
  }

  Future<void> _add() async {
    final ua = _controller.text.trim();
    if (ua.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    await widget.engine.addUserAgent(ua, note: _noteController.text);
    _controller.clear();
    _noteController.clear();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('已添加到 UA 列表'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 220,
      ),
    );
  }

  Future<void> _delete(String ua) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.engine.removeUserAgent(ua);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('已从 UA 列表删除'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 220,
      ),
    );
  }

  Future<void> _editNote(String ua, String current) async {
    final controller = TextEditingController(text: current);
    final saved = await showBrowserDialog<bool>(
      context: context,
      builder: (dialogContext, pop) => AlertDialog(
        title: const Text('编辑 UA 备注'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 2,
          decoration: const InputDecoration(hintText: '例如：桌面版、微信内置、旧手机型号'),
        ),
        actions: [
          TextButton(
            onPressed: () => pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final note = controller.text.trim();
    controller.dispose();
    if (saved != true) return;
    await widget.engine.setUserAgentNote(ua, note);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontFamily: kMonoFamily,
                        fontFamilyFallback: kMonoFallback,
                      ),
                      decoration: InputDecoration(
                        hintText: '粘贴新的 UA 字符串',
                        hintStyle: const TextStyle(fontSize: 10.5),
                        isDense: true,
                        filled: true,
                        fillColor:
                            scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: _add,
                    child: const Text('添加'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _noteController,
                style: const TextStyle(fontSize: 10.5),
                decoration: InputDecoration(
                  hintText: '备注（可选）：比如 桌面版 / 微信UA / 旧手机',
                  hintStyle: const TextStyle(fontSize: 10.5),
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<String>(
            valueListenable: widget.engine.userAgentNotifier,
            builder: (context, current, _) =>
                ValueListenableBuilder<List<String>>(
              valueListenable: widget.engine.userAgentListNotifier,
              builder: (context, list, _) =>
                  ValueListenableBuilder<Map<String, String>>(
                valueListenable: widget.engine.userAgentNotesNotifier,
                builder: (context, notes, _) {
                  if (list.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 24),
                    itemCount: list.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(
                            left: 2,
                            right: 2,
                            bottom: 6,
                          ),
                          child: Text(
                            '当前 UA：',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        );
                      }
                      final ua = list[index - 1];
                      final selected = ua == current;
                      final note = notes[ua] ?? '';
                      return GlassPanel(
                        radius: 10,
                        blur: 12,
                        margin: const EdgeInsets.only(bottom: 5),
                        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => _select(ua),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Row(
                                    children: [
                                      Icon(
                                        selected
                                            ? Icons.radio_button_checked_rounded
                                            : Icons.radio_button_off_rounded,
                                        size: 16,
                                        color: selected
                                            ? scheme.primary
                                            : scheme.outline,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            SelectableText(
                                              ua,
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                fontFamily: kMonoFamily,
                                                fontFamilyFallback: kMonoFallback,
                                                color: selected
                                                    ? scheme.primary
                                                    : scheme.onSurface,
                                                fontWeight: selected
                                                    ? FontWeight.w600
                                                    : FontWeight.normal,
                                              ),
                                            ),
                                            if (note.isNotEmpty)
                                              Padding(
                                                padding: const EdgeInsets.only(top: 2),
                                                child: InkWell(
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                  onTap: () =>
                                                      _editNote(ua, note),
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                            vertical: 2),
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          Icons.edit_note_rounded,
                                                          size: 11,
                                                          color: scheme
                                                              .onSurfaceVariant,
                                                        ),
                                                        const SizedBox(
                                                            width: 3),
                                                        Flexible(
                                                          child: Text(
                                                            '📌 $note',
                                                            style: TextStyle(
                                                              fontSize: 10,
                                                              color: scheme
                                                                  .onSurfaceVariant,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              )
                                            else
                                              Padding(
                                                padding:
                                                    const EdgeInsets.only(
                                                        top: 2),
                                                child: InkWell(
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                  onTap: () => _editNote(ua, ''),
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                            vertical: 2),
                                                    child: Text(
                                                      '＋ 备注',
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Tooltip(
                              message: '编辑备注',
                              child: SizedBox(
                                width: 36,
                                height: 36,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () => _editNote(ua, note),
                                  child: Icon(
                                    Icons.edit_note_rounded,
                                    size: 16,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '删除',
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              iconSize: 15,
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(ua),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ConsolePanel extends StatefulWidget {
  const _ConsolePanel({required this.engine});

  final BrowserEngine engine;

  @override
  State<_ConsolePanel> createState() => _ConsolePanelState();
}

class _ConsolePanelState extends State<_ConsolePanel> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final code = _controller.text.trim();
    if (code.isEmpty) return;
    widget.engine.addConsoleHistory('cmd', code);
    _controller.clear();
    setState(() => _busy = true);
    try {
      final result = await widget.engine.eval(code);
      if (mounted) {
        widget.engine.addConsoleHistory('out', result);
      }
    } catch (e) {
      if (mounted) {
        widget.engine.addConsoleHistory('err', e.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  maxLines: 3,
                  minLines: 1,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                  ),
                  decoration: InputDecoration(
                    hintText: '在页面里执行 JS，可写多行（日志和控制台已合并）',
                    hintStyle: const TextStyle(fontSize: 11.5),
                    isDense: true,
                    filled: true,
                    fillColor:
                        scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _run(),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: _busy ? null : _run,
                child: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('运行'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<List<Map<String, String>>>(
            valueListenable: widget.engine.consoleHistory,
            builder: (context, history, _) =>
                ValueListenableBuilder<List<ConsoleLine>>(
              valueListenable: widget.engine.console,
              builder: (context, logs, _) {
                if (history.isEmpty && logs.isEmpty) {
                  return Center(
                    child: Text(
                      '页面日志和执行 JS 都会显示在这里',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 24),
                  itemCount: history.length + logs.length,
                  itemBuilder: (context, index) {
                    if (index < history.length) {
                      return _historyEntry(history[index], scheme);
                    }
                    final line = logs[index - history.length];
                    final color = switch (line.level) {
                      'error' => scheme.error,
                      'warn' => Colors.orange.shade700,
                      _ => scheme.onSurfaceVariant,
                    };
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: SelectableText(
                        '[${line.level}] ${line.text}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                          color: color,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _historyEntry(Map<String, String> e, ColorScheme scheme) {
    final kind = e['kind'] ?? 'out';
    final text = e['text'] ?? '';
    if (kind == 'cmd') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: SelectableText.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '> ',
                style: TextStyle(color: scheme.primary),
              ),
              _codeSpan(text, scheme),
            ],
          ),
          style: const TextStyle(
            fontSize: 11.5,
            fontFamily: kMonoFamily,
            fontFamilyFallback: kMonoFallback,
          ),
        ),
      );
    }
    final color = kind == 'err' ? scheme.error : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: SelectableText.rich(
        _codeSpan(text, scheme),
        style: TextStyle(
          fontSize: 11.5,
          fontFamily: kMonoFamily,
          fontFamilyFallback: kMonoFallback,
          color: color,
        ),
      ),
    );
  }

  TextSpan _codeSpan(String text, ColorScheme scheme) {
    final spans = <TextSpan>[];
    final keywords = {
      'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue',
      'debugger', 'default', 'delete', 'do', 'else', 'export', 'extends',
      'false', 'finally', 'for', 'function', 'if', 'import', 'in', 'instanceof',
      'let', 'new', 'null', 'return', 'static', 'super', 'switch', 'this',
      'throw', 'true', 'try', 'typeof', 'undefined', 'var', 'void', 'while',
      'with', 'yield',
    };
    var i = 0;
    while (i < text.length) {
      final ch = text[i];
      final rest = text.substring(i);
      // 字符串
      if (ch == '"' || ch == "'" || ch == '`') {
        final start = i;
        i++;
        while (i < text.length) {
          if (text[i] == '\\' && i + 1 < text.length) {
            i += 2;
            continue;
          }
          if (text[i] == ch) {
            i++;
            break;
          }
          i++;
        }
        spans.add(
          TextSpan(
            text: text.substring(start, i),
            style: TextStyle(color: Colors.green.shade600),
          ),
        );
        continue;
      }
      // 行注释
      if (ch == '/' && i + 1 < text.length && text[i + 1] == '/') {
        final start = i;
        while (i < text.length && text[i] != '\n') i++;
        spans.add(
          TextSpan(
            text: text.substring(start, i),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        );
        continue;
      }
      // 数字
      final numMatch =
          RegExp(r'^-?\d+(\.\d+)?([eE][+-]?\d+)?').firstMatch(rest);
      if (numMatch != null) {
        spans.add(
          TextSpan(
            text: numMatch.group(0)!,
            style: TextStyle(color: Colors.orange.shade700),
          ),
        );
        i += numMatch.group(0)!.length;
        continue;
      }
      // 标识符 / 关键字
      final wordMatch = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*').firstMatch(rest);
      if (wordMatch != null) {
        final word = wordMatch.group(0)!;
        spans.add(
          TextSpan(
            text: word,
            style: TextStyle(
              color: keywords.contains(word)
                  ? Colors.blue.shade400
                  : scheme.onSurface,
              fontWeight:
                  keywords.contains(word) ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        );
        i += word.length;
        continue;
      }
      // 标点
      if ('{}()[];,.?:+-*/=%<>!&|'.contains(ch)) {
        spans.add(
          TextSpan(
            text: ch,
            style: TextStyle(color: scheme.outline),
          ),
        );
        i++;
        continue;
      }
      spans.add(TextSpan(text: ch));
      i++;
    }
    return TextSpan(children: spans);
  }
}


class _ProxyPanel extends StatefulWidget {
  const _ProxyPanel({required this.engine});

  final BrowserEngine engine;

  @override
  State<_ProxyPanel> createState() => _ProxyPanelState();
}

class _ProxyPanelState extends State<_ProxyPanel> {
  Future<void> _edit([BrowserProxy? proxy]) async {
    final saved = await showBrowserDialog<BrowserProxy>(
      context: context,
      builder: (dialogContext, pop) => _ProxyEditDialog(
        initial: proxy,
        onSave: pop,
        onCancel: () => pop(null),
      ),
    );
    if (saved == null) return;
    if (proxy == null) {
      await widget.engine.addProxy(saved);
    } else {
      await widget.engine.updateProxy(saved);
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(proxy == null ? '已添加代理并生效' : '已保存代理'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 220,
      ),
    );
  }

  Future<void> _activate(BrowserProxy proxy) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.engine.setActiveProxy(proxy.id);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('已启用该代理，刷新页面后完全生效'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 280,
      ),
    );
  }

  Future<void> _delete(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.engine.removeProxy(id);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('已删除代理'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 180,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: widget.engine.activeProxyIdNotifier,
                  builder: (context, activeId, _) {
                    final active = widget.engine.activeProxy;
                    return Text(
                      active == null
                          ? '当前：直连（不走代理）'
                          : '当前：${active.label}',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: active == null
                            ? scheme.onSurfaceVariant
                            : scheme.primary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add, size: 15),
                label: const Text('添加代理'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<List<BrowserProxy>>(
            valueListenable: widget.engine.proxiesNotifier,
            builder: (context, list, _) {
              if (list.isEmpty) {
                return Center(
                  child: Text(
                    '还没有代理配置\n点右上角“添加代理”',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 24),
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final proxy = list[index];
                  final active = proxy.id ==
                      widget.engine.activeProxyIdNotifier.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Material(
                      color: active
                          ? scheme.primaryContainer.withValues(alpha: 0.35)
                          : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _activate(proxy),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                active
                                    ? Icons.check_circle_rounded
                                    : Icons.public,
                                size: 16,
                                color: active
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      proxy.name,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${proxy.scheme}://${proxy.host}:${proxy.port}',
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontFamily: kMonoFamily,
                                        fontFamilyFallback: kMonoFallback,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: '编辑',
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                iconSize: 15,
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _edit(proxy),
                              ),
                              IconButton(
                                tooltip: '删除',
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                iconSize: 15,
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _delete(proxy.id),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ProxyEditDialog extends StatefulWidget {
  const _ProxyEditDialog({
    required this.initial,
    required this.onSave,
    required this.onCancel,
  });

  final BrowserProxy? initial;
  final ValueChanged<BrowserProxy?> onSave;
  final VoidCallback onCancel;

  @override
  State<_ProxyEditDialog> createState() => _ProxyEditDialogState();
}

class _ProxyEditDialogState extends State<_ProxyEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _bypass;
  late String _scheme;

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    _name = TextEditingController(text: p?.name ?? '');
    _host = TextEditingController(text: p?.host ?? '');
    _port = TextEditingController(text: p?.port.toString() ?? '8080');
    _username = TextEditingController(text: p?.username ?? '');
    _password = TextEditingController(text: p?.password ?? '');
    _bypass = TextEditingController(text: p?.bypass ?? '');
    _scheme = p?.scheme ?? 'http';
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _bypass.dispose();
    super.dispose();
  }

  void _submit() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 0;
    if (host.isEmpty || port <= 0 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请填写有效的主机和端口（1-65535）'),
          duration: Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    widget.onSave(
      BrowserProxy(
        id: widget.initial?.id,
        name: _name.text.trim().isEmpty ? '$host:$port' : _name.text.trim(),
        scheme: _scheme,
        host: host,
        port: port,
        username: _username.text.trim(),
        password: _password.text,
        bypass: _bypass.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final input = InputDecoration(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    );
    return AlertDialog(
      title: Text(widget.initial == null ? '添加代理' : '编辑代理'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: input.copyWith(hintText: '名称（可选，默认 host:port）'),
            ),
            const SizedBox(height: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '协议',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'http',
                      label: Text('HTTP'),
                      icon: Icon(Icons.public, size: 14),
                    ),
                    ButtonSegment(
                      value: 'https',
                      label: Text('HTTPS'),
                      icon: Icon(Icons.lock_outline, size: 14),
                    ),
                    ButtonSegment(
                      value: 'socks5',
                      label: Text('SOCKS5'),
                      icon: Icon(Icons.vpn_lock_outlined, size: 14),
                    ),
                  ],
                  selected: {_scheme},
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    textStyle: WidgetStatePropertyAll(
                      const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  onSelectionChanged: (selection) =>
                      setState(() => _scheme = selection.first),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _host,
              decoration: input.copyWith(hintText: '主机，如 127.0.0.1'),
              style: const TextStyle(fontFamily: kMonoFamily),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: input.copyWith(hintText: '端口，如 8080'),
              style: const TextStyle(fontFamily: kMonoFamily),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _username,
              decoration: input.copyWith(hintText: '用户名（可选）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: input.copyWith(hintText: '密码（可选）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _bypass,
              maxLines: 2,
              decoration: input.copyWith(
                hintText: '绕过代理（逗号分隔，可留空）',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: widget.onCancel,
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}


class _BookmarksPanel extends StatefulWidget {
  const _BookmarksPanel({required this.engine, required this.onOpenUrl});

  final BrowserEngine engine;
  final void Function(String url) onOpenUrl;

  @override
  State<_BookmarksPanel> createState() => _BookmarksPanelState();
}

class _BookmarksPanelState extends State<_BookmarksPanel> {
  Future<void> _addCurrent() async {
    final url = widget.engine.currentUrl.value.trim();
    if (url.isEmpty) return;
    await widget.engine.addBookmark(
      url,
      title: widget.engine.title.value,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('已收藏：${widget.engine.title.value.isEmpty ? url : widget.engine.title.value}'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _remove(String id) async {
    await widget.engine.removeBookmark(id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<List<BrowserBookmark>>(
                  valueListenable: widget.engine.bookmarks,
                  builder: (context, list, _) => Text(
                    '收藏夹（${list.length}）',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _addCurrent,
                icon: const Icon(Icons.star_outline_rounded, size: 15),
                label: const Text('收藏当前页'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<List<BrowserBookmark>>(
            valueListenable: widget.engine.bookmarks,
            builder: (context, list, _) {
              if (list.isEmpty) {
                return Center(
                  child: Text(
                    '还没有收藏\n在当前页面点“收藏当前页”即可添加',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 24),
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final b = list[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Material(
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: 0.3,
                      ),
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => widget.onOpenUrl(b.url),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.star_outline_rounded,
                                size: 16,
                                color: Colors.orange.shade700,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      b.title,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      b.url,
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontFamily: kMonoFamily,
                                        fontFamilyFallback: kMonoFallback,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: '删除收藏',
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                iconSize: 15,
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _remove(b.id),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}


class _HistoryPanel extends StatefulWidget {
  const _HistoryPanel({required this.engine, required this.onOpenUrl});

  final BrowserEngine engine;
  final void Function(String url) onOpenUrl;

  @override
  State<_HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<_HistoryPanel> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _clearAll() async {
    final ok = await showBrowserDialog<bool>(
      context: context,
      builder: (dialogContext, pop) => AlertDialog(
        title: const Text('清空全部历史？'),
        content: const Text('删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.engine.clearHistory();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('历史已清空'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 180,
      ),
    );
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('链接已复制'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 160,
      ),
    );
  }

  String _groupLabel(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    if (day == today) return '今天';
    if (day == today.subtract(const Duration(days: 1))) return '昨天';
    if (now.difference(day).inDays < 7) return '本周';
    return '更早';
  }

  List<({String label, List<BrowserHistoryEntry> items})> _group(
    List<BrowserHistoryEntry> input,
  ) {
    final order = ['今天', '昨天', '本周', '更早'];
    final buckets = <String, List<BrowserHistoryEntry>>{
      for (final label in order) label: [],
    };
    for (final h in input) {
      buckets[_groupLabel(h.visitedAt)]!.add(h);
    }
    return [
      for (final label in order)
        if (buckets[label]!.isNotEmpty)
          (label: label, items: buckets[label]!),
    ];
  }

  String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  String _timeOf(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final two = (int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (day == today) return hm;
    if (day == today.subtract(const Duration(days: 1))) return '昨天 $hm';
    return '${two(t.month)}-${two(t.day)} $hm';
  }


  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<List<BrowserHistoryEntry>>(
                  valueListenable: widget.engine.history,
                  builder: (context, list, _) {
                    final filtered = _query.trim().isEmpty
                        ? list.length
                        : list
                            .where((h) =>
                                h.title.toLowerCase().contains(_query.trim().toLowerCase()) ||
                                h.url.toLowerCase().contains(_query.trim().toLowerCase()) ||
                                _hostOf(h.url).toLowerCase().contains(_query.trim().toLowerCase()))
                            .length;
                    return Text(
                      '历史 · $filtered${_query.trim().isEmpty ? ' / ${list.length}' : ''}',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _clearAll,
                icon: const Icon(Icons.delete_sweep_outlined, size: 15),
                label: const Text('清空'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: scheme.error,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            style: const TextStyle(fontSize: 11),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              hintText: '搜索历史（标题 / 网址 / 域名）',
              hintStyle: const TextStyle(fontSize: 10.5),
              prefixIcon: const Icon(Icons.search, size: 15),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除',
                      iconSize: 15,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 30,
                        minHeight: 30,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<List<BrowserHistoryEntry>>(
            valueListenable: widget.engine.history,
            builder: (context, list, _) {
              final q = _query.trim().toLowerCase();
              final filtered = q.isEmpty
                  ? list
                  : list
                      .where((h) =>
                          h.title.toLowerCase().contains(q) ||
                          h.url.toLowerCase().contains(q) ||
                          _hostOf(h.url).toLowerCase().contains(q))
                      .toList();
              if (filtered.isEmpty) {
                return Center(
                  child: Text(
                    q.isEmpty ? '暂时没有浏览历史' : '没有匹配「$_query」的历史',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              final groups = _group(filtered);
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 24),
                itemCount: groups.length + filtered.length,
                itemBuilder: (context, index) {
                  var cursor = 0;
                  for (final g in groups) {
                    if (index == cursor) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(2, 10, 2, 4),
                        child: Text(
                          g.label,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: scheme.primary,
                          ),
                        ),
                      );
                    }
                    cursor += 1;
                    if (index < cursor + g.items.length) {
                      final h = g.items[index - cursor];
                      return _HistoryTile(
                        entry: h,
                        host: _hostOf(h.url),
                        time: _timeOf(h.visitedAt),
                        onOpen: () => widget.onOpenUrl(h.url),
                        onCopy: () => _copy(h.url),
                        onDelete: () => widget.engine.removeHistoryAt(
                          list.indexOf(h),
                        ),
                      );
                    }
                    cursor += g.items.length;
                  }
                  return const SizedBox.shrink();
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.entry,
    required this.host,
    required this.time,
    required this.onOpen,
    required this.onCopy,
    required this.onDelete,
  });

  final BrowserHistoryEntry entry;
  final String host;
  final String time;
  final VoidCallback onOpen;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = host.isEmpty
        ? '#'
        : host.substring(0, 1).toUpperCase();
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 2, 6),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: scheme.primaryContainer.withValues(
                    alpha: 0.6,
                  ),
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title.isEmpty ? host : entry.title,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              host.isEmpty ? entry.url : host,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                color: scheme.primary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (host.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.arrow_forward_ios_rounded,
                              size: 7,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                _shortPath(entry.url),
                                style: TextStyle(
                                  fontSize: 9,
                                  fontFamily: kMonoFamily,
                                  fontFamilyFallback: kMonoFallback,
                                  color: scheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 9,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  tooltip: '复制链接',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.copy_outlined),
                  onPressed: onCopy,
                ),
                IconButton(
                  tooltip: '删除此条',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close),
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _shortPath(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path.isEmpty ? '/' : uri.path;
      if (path.length <= 24) return path;
      return '${path.substring(0, 12)}…${path.substring(path.length - 8)}';
    } catch (_) {
      return '';
    }
  }
}

class _ProfilePanel extends StatefulWidget {
  const _ProfilePanel({required this.engine});

  final BrowserEngine engine;

  @override
  State<_ProfilePanel> createState() => _ProfilePanelState();
}

class _ProfilePanelState extends State<_ProfilePanel> {
  Future<void> _newProfile() async {
    _copyChoice = false;
    final name = await showBrowserDialog<String>(
      context: context,
      builder: (ctx, pop) {
        final controller = TextEditingController();
        var copyCurrent = false;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('新建浏览器快照', style: TextStyle(fontSize: 14)),
            content: SizedBox(
              width: 240,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: '快照名称',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Checkbox(
                        value: copyCurrent,
                        onChanged: (v) => setDialogState(
                          () => copyCurrent = v ?? false,
                        ),
                      ),
                      const Expanded(
                        child: Text(
                          '复制当前浏览器的指纹/登录态/收藏/历史',
                          style: TextStyle(fontSize: 10.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => pop(null),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  _copyChoice = copyCurrent;
                  pop(controller.text);
                },
                child: const Text('新建'),
              ),
            ],
          ),
        );
      },
    );
    if (name == null || !mounted) return;
    await widget.engine.createProfile(
      name: name.trim().isEmpty ? null : name.trim(),
      cloneCurrent: _copyChoice ?? false,
    );
  }

  bool? _copyChoice;

  Future<void> _switch(BrowserProfile p) async {
    final r = await widget.engine.switchProfile(p.id);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          r['error'] != null ? '切换失败：${r['error']}' : '已切换到「${p.name}」',
        ),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 200,
      ),
    );
  }

  Future<void> _rename(BrowserProfile p) async {
    final name = await showBrowserDialog<String>(
      context: context,
      builder: (ctx, pop) {
        final controller = TextEditingController(text: p.name);
        return AlertDialog(
          title: const Text('重命名快照', style: TextStyle(fontSize: 14)),
          content: SizedBox(
            width: 240,
            child: TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(labelText: '名称', isDense: true),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => pop(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (name == null || !mounted) return;
    await widget.engine.renameProfile(p.id, name);
  }

  Future<void> _delete(BrowserProfile p) async {
    if (p.isMain) return;
    final ok = await showBrowserDialog<bool>(
      context: context,
      builder: (ctx, pop) => AlertDialog(
        title: const Text('删除快照？', style: TextStyle(fontSize: 14)),
        content: Text(
          '「${p.name}」的指纹、登录态、收藏、历史都会删除，无法恢复。',
          style: const TextStyle(fontSize: 11),
        ),
        actions: [
          TextButton(onPressed: () => pop(false), child: const Text('取消')),
          FilledButton(
            onPressed: () => pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.engine.removeProfile(p.id);
  }

  Future<void> _edit(BrowserProfile p) async {
    await showBrowserDialog<void>(
      context: context,
      builder: (ctx, pop) => _ProfileDetailView(
        engine: widget.engine,
        profileId: p.id,
        onClose: pop,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
          child: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: widget.engine.activeProfileIdNotifier,
                  builder: (context, activeId, _) {
                    final name = widget.engine.currentProfile?.name ?? '主浏览器';
                    return Text(
                      '快照 · 当前：$name',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
              ),
              TextButton.icon(
                onPressed: _newProfile,
                icon: const Icon(Icons.add, size: 15),
                label: const Text('新建'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: scheme.primary,
                ),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            '不是多个浏览器，是同一个浏览器的多份数据镜像；切换时整份替换指纹/登录态/收藏/历史。',
            style: TextStyle(fontSize: 9.5),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ValueListenableBuilder<List<BrowserProfile>>(
            valueListenable: widget.engine.profilesNotifier,
            builder: (context, list, _) {
              if (list.isEmpty) {
                return Center(
                  child: Text(
                    '还没有快照\n点右上角「新建」创建一个',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 24),
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final p = list[index];
                  return ValueListenableBuilder<String>(
                    valueListenable: widget.engine.activeProfileIdNotifier,
                    builder: (context, activeId, _) => _ProfileTile(
                      profile: p,
                      active: p.id == activeId,
                      onSwitch: () => _switch(p),
                      onEdit: () => _edit(p),
                      onRename: () => _rename(p),
                      onDelete: () => _delete(p),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.active,
    required this.onSwitch,
    required this.onEdit,
    required this.onRename,
    required this.onDelete,
  });

  final BrowserProfile profile;
  final bool active;
  final VoidCallback onSwitch;
  final VoidCallback onEdit;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ua = profile.ua ?? '默认指纹';
    final url = (profile.currentUrl?.isNotEmpty ?? false)
        ? profile.currentUrl!
        : '未打开页面';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: active
            ? scheme.primaryContainer.withValues(alpha: 0.35)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: active ? scheme.primary : Colors.transparent,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: active
                    ? scheme.primary
                    : scheme.surfaceContainerHighest,
                child: Icon(
                  profile.isMain
                      ? Icons.home_outlined
                      : Icons.account_tree_outlined,
                  size: 16,
                  color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            profile.name,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (profile.isMain) ...[
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '主',
                              style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.w700,
                                color: scheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ],
                        if (active) ...[
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '当前',
                              style: TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.w700,
                                color: scheme.onPrimary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '指纹 ${ua.length > 30 ? '${ua.substring(0, 30)}…' : ua}',
                      style: TextStyle(
                        fontSize: 8.5,
                        color: scheme.onSurfaceVariant,
                        fontFamily: kMonoFamily,
                        fontFamilyFallback: kMonoFallback,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '数据可视化编辑',
                visualDensity: VisualDensity.compact,
                iconSize: 15,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: const Icon(Icons.data_object_rounded),
                onPressed: onEdit,
              ),
              IconButton(
                tooltip: '重命名',
                visualDensity: VisualDensity.compact,
                iconSize: 15,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.edit_outlined),
                onPressed: onRename,
              ),
              if (!profile.isMain)
                IconButton(
                  tooltip: '删除',
                  visualDensity: VisualDensity.compact,
                  iconSize: 15,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(Icons.delete_outline, color: scheme.error),
                  onPressed: onDelete,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.link_rounded,
                  size: 12,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    url,
                    style: TextStyle(
                      fontSize: 9.5,
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  icon: Icons.star_border_rounded,
                  label: '收藏',
                  value: '${profile.bookmarks.length}',
                  color: scheme.primary,
                  progress: (profile.bookmarks.length / 100).clamp(0.0, 1.0),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MiniStat(
                  icon: Icons.history_outlined,
                  label: '历史',
                  value: '${profile.history.length}',
                  color: scheme.tertiary,
                  progress: (profile.history.length / 500).clamp(0.0, 1.0),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MiniStat(
                  icon: Icons.cookie_outlined,
                  label: '登录态',
                  value: '${profile.cookies.length}',
                  color: scheme.error,
                  progress: (profile.cookies.length / 300).clamp(0.0, 1.0),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MiniStat(
                  icon: Icons.storage_outlined,
                  label: '本地',
                  value: '${profile.localStorage.length}',
                  color: scheme.secondary,
                  progress: (profile.localStorage.length / 20)
                      .clamp(0.0, 1.0),
                ),
              ),
            ],
          ),
          if (!active) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: onSwitch,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 10),
                ),
                icon: const Icon(Icons.swap_horiz_rounded, size: 14),
                label: const Text('切换到此快照'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.progress = 0,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 8,
              color: color.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: color.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileDetailView extends StatefulWidget {
  const _ProfileDetailView({
    required this.engine,
    required this.profileId,
    required this.onClose,
  });

  final BrowserEngine engine;
  final String profileId;
  final VoidCallback onClose;

  @override
  State<_ProfileDetailView> createState() => _ProfileDetailViewState();
}

class _ProfileDetailViewState extends State<_ProfileDetailView> {
  late TextEditingController _nameCtrl;
  late TextEditingController _uaCtrl;
  late TextEditingController _urlCtrl;
  late String _proxyId;
  late List<BrowserBookmark> _bookmarks;
  late List<BrowserHistoryEntry> _history;
  List<Map<String, dynamic>> _cookies = [];
  Map<String, int> _cookieDomains = {};
  Map<String, Map<String, String>> _localStorage = {};

  BrowserProfile? _profile() {
    for (final p in widget.engine.profilesNotifier.value) {
      if (p.id == widget.profileId) return p;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final p = _profile();
    _nameCtrl = TextEditingController(text: p?.name ?? '');
    _uaCtrl = TextEditingController(text: p?.ua ?? '');
    _urlCtrl = TextEditingController(text: p?.currentUrl ?? '');
    _proxyId = p?.activeProxyId ?? '';
    _bookmarks = List.of(p?.bookmarks ?? const []);
    _history = List.of(p?.history ?? const []);
    _cookies = List.of(p?.cookies ?? const []);
    _localStorage = {
      for (final e in (p?.localStorage ?? const {}).entries)
        e.key: Map.of(e.value),
    };
    _cookieDomains = _summarizeCookies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshLiveData();
    });
  }

  Future<void> _refreshLiveData() async {
    final p = _profile();
    if (p == null) return;
    final isActive = p.id == widget.engine.activeProfileIdNotifier.value;
    if (!isActive) return;
    final cookies = await WebBridge.dumpCookies();
    final origin = widget.engine.currentOrigin;
    Map<String, String> local = const {};
    if (origin != null && widget.engine.isReady) {
      local = await widget.engine.snapshotLocalStorage();
    }
    if (!mounted) return;
    setState(() {
      _cookies = cookies;
      _cookieDomains = _summarizeCookies();
      if (origin != null) {
        if (local.isEmpty) {
          _localStorage.remove(origin);
        } else {
          _localStorage[origin] = local;
        }
      }
    });
  }

  Widget _buildHealthBar(ColorScheme scheme) {
    final score = ((_bookmarks.length / 100).clamp(0.0, 1.0) +
            (_history.length / 500).clamp(0.0, 1.0) +
            (_cookies.length / 300).clamp(0.0, 1.0) +
            (_localStorage.length / 20).clamp(0.0, 1.0)) /
        4;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insert_chart_outlined_rounded,
                  size: 13, color: scheme.primary),
              const SizedBox(width: 5),
              Text(
                '数据完整度',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Text(
                '${(score * 100).round()}%',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: score,
              minHeight: 5,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(scheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _uaCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  Map<String, int> _summarizeCookies() {
    final map = <String, int>{};
    for (final c in _cookies) {
      final host = c['host']?.toString() ?? '';
      if (host.isEmpty) continue;
      map[host] = (map[host] ?? 0) + 1;
    }
    return map;
  }

  Future<void> _save() async {
    final ok = await widget.engine.updateProfile(
      widget.profileId,
      name: _nameCtrl.text,
      ua: _uaCtrl.text,
      activeProxyId: _proxyId,
      currentUrl: _urlCtrl.text,
      bookmarks: _bookmarks,
      history: _history,
      localStorage: _localStorage,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? '快照数据已保存' : '保存失败'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 180,
      ),
    );
  }

  Future<void> _switchHere() async {
    await widget.engine.switchProfile(widget.profileId);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('已切换到「${_nameCtrl.text}」'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 200,
      ),
    );
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = _profile();
    if (p == null) return const SizedBox.shrink();
    final isActive = p.id == widget.engine.activeProfileIdNotifier.value;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360, maxHeight: 540),
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Icon(
                    p.isMain ? Icons.home_outlined : Icons.account_tree_outlined,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '快照数据 · ${p.name}${isActive ? '（当前）' : ''}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  _fieldLabel('名称', Icons.label_outline_rounded),
                  TextField(
                    controller: _nameCtrl,
                    style: const TextStyle(fontSize: 11),
                    decoration: _fieldDecoration('快照名称'),
                  ),
                  const SizedBox(height: 10),
                  _fieldLabel('指纹 / UA', Icons.fingerprint_rounded),
                  TextField(
                    controller: _uaCtrl,
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                    ),
                    maxLines: 2,
                    minLines: 1,
                    decoration: _fieldDecoration(
                      '留空使用默认手机指纹',
                    ),
                  ),
                  const SizedBox(height: 10),
                  _fieldLabel('当前网址', Icons.link_rounded),
                  TextField(
                    controller: _urlCtrl,
                    style: const TextStyle(fontSize: 10.5),
                    decoration: _fieldDecoration('切换后自动打开这个页面'),
                  ),
                  const SizedBox(height: 10),
                  _fieldLabel('代理', Icons.vpn_lock_outlined),
                  ValueListenableBuilder<List<BrowserProxy>>(
                    valueListenable: widget.engine.proxiesNotifier,
                    builder: (context, proxies, _) => Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        ChoiceChip(
                          label: const Text('直连', style: TextStyle(fontSize: 10)),
                          selected: _proxyId.isEmpty,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setState(() => _proxyId = ''),
                        ),
                        for (final proxy in proxies)
                          ChoiceChip(
                            label: Text(
                              proxy.name.length > 12
                                  ? '${proxy.name.substring(0, 12)}…'
                                  : proxy.name,
                              style: const TextStyle(fontSize: 10),
                            ),
                            selected: _proxyId == proxy.id,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) =>
                                setState(() => _proxyId = proxy.id),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildHealthBar(scheme),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _DataCard(
                          icon: Icons.star_border_rounded,
                          label: '收藏',
                          value: '${_bookmarks.length}',
                          color: scheme.primary,
                          progress: (_bookmarks.length / 100)
                              .clamp(0.0, 1.0),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _DataCard(
                          icon: Icons.history_outlined,
                          label: '历史',
                          value: '${_history.length}',
                          color: scheme.tertiary,
                          progress: (_history.length / 500)
                              .clamp(0.0, 1.0),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _DataCard(
                          icon: Icons.cookie_outlined,
                          label: 'Cookie',
                          value: '${_cookieDomains.length} 域',
                          color: scheme.error,
                          progress: (_cookies.length / 300)
                              .clamp(0.0, 1.0),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _DataCard(
                          icon: Icons.storage_outlined,
                          label: '本地',
                          value: '${_localStorage.length} 域',
                          color: scheme.secondary,
                          progress: (_localStorage.length / 20)
                              .clamp(0.0, 1.0),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _fieldLabel('收藏列表', Icons.star_rounded),
                  if (_bookmarks.isEmpty)
                    const Text(
                      '暂无收藏',
                      style: TextStyle(
                        fontSize: 10,
                        color: Color(0x88000000),
                      ),
                    )
                  else ...[
                    for (final b in List.of(_bookmarks))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.star_rounded, size: 15),
                        title: Text(
                          b.title,
                          style: const TextStyle(fontSize: 10.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          b.url,
                          style: const TextStyle(fontSize: 9),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 14,
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _bookmarks.removeWhere((x) => x.id == b.id);
                          }),
                        ),
                      ),
                  ],
                  const SizedBox(height: 6),
                  _fieldLabel('历史列表', Icons.history_rounded),
                  if (_history.isEmpty)
                    const Text(
                      '暂无历史',
                      style: TextStyle(
                        fontSize: 10,
                        color: Color(0x88000000),
                      ),
                    )
                  else ...[
                    for (final h in List.of(_history))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.public_rounded, size: 15),
                        title: Text(
                          h.title,
                          style: const TextStyle(fontSize: 10.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${h.visitedAt.toLocal()} · ${h.url}',
                          style: const TextStyle(fontSize: 9),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 14,
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _history.removeWhere((x) => identical(x, h));
                          }),
                        ),
                      ),
                  ],
                  const SizedBox(height: 6),
                  _fieldLabel('Cookie 域分布', Icons.cookie_outlined),
                  if (_cookieDomains.isEmpty)
                    const Text(
                      '暂无 Cookie 登录态',
                      style: TextStyle(
                        fontSize: 10,
                        color: Color(0x88000000),
                      ),
                    )
                  else ...[
                    for (final e in _cookieDomains.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value)))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.key,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontFamily: kMonoFamily,
                                  fontFamilyFallback: kMonoFallback,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${e.value} 条',
                                style: const TextStyle(fontSize: 9),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 6),
                  _fieldLabel('本地数据快照', Icons.storage_outlined),
                  if (_localStorage.isEmpty)
                    const Text(
                      '暂无 localStorage 快照\n（当前页如果已登录，会自动抓取并保存）',
                      style: TextStyle(
                        fontSize: 10,
                        color: Color(0x88000000),
                      ),
                    )
                  else ...[
                    for (final e in _localStorage.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest
                                .withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.public_rounded,
                                    size: 12,
                                    color: scheme.primary,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      e.key,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: scheme.primary.withValues(
                                        alpha: 0.15,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '${e.value.length} 键',
                                      style: const TextStyle(fontSize: 8.5),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              for (final kv in e.value.entries.take(5))
                                Text(
                                  '${kv.key} = ${kv.value.length > 60 ? '${kv.value.substring(0, 60)}…' : kv.value}',
                                  style: const TextStyle(fontSize: 9),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              if (e.value.length > 5)
                                Text(
                                  '… 还有 ${e.value.length - 5} 个键',
                                  style: const TextStyle(fontSize: 9),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  TextButton(
                    onPressed: widget.onClose,
                    child: const Text('关闭'),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined, size: 16),
                    label: const Text('保存修改'),
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.primary,
                    ),
                  ),
                  if (!isActive) ...[
                    const SizedBox(width: 6),
                    FilledButton.icon(
                      onPressed: _switchHere,
                      icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                      label: const Text('切换到此快照'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldLabel(String text, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 13, color: scheme.primary),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration(String hint) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 9.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    );
  }
}

class _DataCard extends StatelessWidget {
  const _DataCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.progress = 0,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 8,
              color: color.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: color.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}
