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
import 'intercept_js.dart';
import 'models/browser_models.dart';
import 'models/intercept_script.dart';
import '../../shared/mono_text.dart';

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
    WidgetsBinding.instance.removeObserver(this);
    _detachBus();
    _urlController.dispose();
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
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
        title: const Text('外部跳转确认'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('网页想跳到外部链接：'),
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
                '确认是你要的操作再允许。',
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
            child: const Text('允许跳转'),
          ),
        ],
      ),
    );
    return allow ?? false;
  }

  @override
  Widget build(BuildContext context) {
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
                  child: ClipRRect(
                    borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(radius),
                    ),
                    child: WebViewWidget(controller: web),
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
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
            itemCount: list.length,
            itemBuilder: (context, index) => _RequestTile(
              request: list[index],
              onMakeHook: () => _newScriptFrom(list[index]),
            ),
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
                            '脚本里写 onRequest(req) / onResponse(res)，\n'
                            '想改什么改什么：改地址、改头、改请求体、改返回体，'
                            '或直接 block / mock。\n\n'
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
                child: ColoredBox(
                  // Monokai 的底色。代码域必须有自己的深底，
                  // 玻璃背景透出来的花纹会让高亮完全看不清。
                  color: const Color(0xFF23241F),
                  child: CodeEditorField(
                    key: _codeEditorKey,
                    controller: _codeController,
                    path: 'hook.js',
                    initialFontSize: 12,
                    padding: const EdgeInsets.all(8),
                  ),
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

  Widget _consoleList() {
    final scheme = Theme.of(context).colorScheme;
    return GlassBackdrop(
      child: ValueListenableBuilder<List<ConsoleLine>>(
        valueListenable: _engine.console,
        builder: (context, list, _) {
          if (list.isEmpty) {
            return Center(
              child: Text(
                '页面还没有输出日志',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
            itemCount: list.length,
            itemBuilder: (context, index) {
              final line = list[index];
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

class _RequestTile extends StatefulWidget {
  const _RequestTile({required this.request, this.onMakeHook});

  final CapturedRequest request;
  final VoidCallback? onMakeHook;

  @override
  State<_RequestTile> createState() => _RequestTileState();
}

class _RequestTileState extends State<_RequestTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = widget.request;
    final color = r.pending
        ? scheme.onSurfaceVariant
        : (r.status >= 400 || r.error.isNotEmpty)
            ? scheme.error
            : Colors.green.shade600;
    // 注意：不能用 GlassPanel 的 onTap。它把一个铺满整块的 InkWell 盖在内容
    // **上面**，展开后里面的「改这个包 / 复制返回」就永远点不到——手指落下先被
    // 那层 InkWell 吃掉，表现是"点按钮只把这条收起来了"。
    // 所以只让标题行负责展开收起。
    return GlassPanel(
      radius: 14,
      blur: 14,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Row(
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
          ),
          // 这个包被脚本动过：必须显眼，否则用户会以为服务器就是这么返回的。
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
          if (_open) ...[
            const SizedBox(height: 6),
            _kv('地址', r.url),
            if (r.contentType.isNotEmpty) _kv('类型', r.contentType),
            if (r.requestHeaders.isNotEmpty) _kv('请求头', r.requestHeaders),
            if (r.requestBody.isNotEmpty) _kv('请求体', r.requestBody),
            if (r.responseHeaders.isNotEmpty) _kv('响应头', r.responseHeaders),
            if (r.responseBody.isNotEmpty) _kv('响应体', r.responseBody),
            if (r.error.isNotEmpty) _kv('出错', r.error),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.onMakeHook != null)
                  TextButton.icon(
                    onPressed: widget.onMakeHook,
                    icon: const Icon(Icons.data_object_rounded, size: 14),
                    label: const Text(
                      '按这个包写脚本',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: r.responseBody));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('返回体已复制'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 14),
                  label: const Text('复制返回', style: TextStyle(fontSize: 11.5)),
                ),
              ],
            ),
          ] else if (r.responseBody.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
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
        ],
      ),
    );
  }

  Widget _kv(String key, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            key,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          SelectableText(
            value.length > 4000 ? '${value.substring(0, 4000)}…（已截断）' : value,
            style: const TextStyle(
              fontSize: 11,
              height: 1.3,
              fontFamily: kMonoFamily,
              fontFamilyFallback: kMonoFallback,
            ),
          ),
        ],
      ),
    );
  }
}
