import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/local_shell/proot_bridge.dart';
import '../../../core/theme/theme_config.dart';
import '../../../core/theme/theme_effects_controller.dart';
import '../../../core/theme/theme_store.dart';

/// 打开主题专属菜单悬浮窗。
///
/// 每个主题包用自己的 `html/menu.html` + `css/*.css` + `js/*.js` 定义菜单，
/// 通过 `window.DSHThemeMenu` 通道动态读取/保存 `config.json`，
/// 并实时调用 effect / styleComponent 与当前主题互动。
Future<void> showThemeMenuWindow(
  BuildContext context, {
  required ThemeConfig theme,
  required Future<Map<String, dynamic>> Function() readConfig,
  required Future<void> Function(Map<String, dynamic>) saveConfig,
}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _ThemeMenuWindow(
      themeId: theme.id,
      readConfig: readConfig,
      saveConfig: saveConfig,
      onClose: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _ThemeMenuWindow extends StatefulWidget {
  const _ThemeMenuWindow({
    required this.themeId,
    required this.readConfig,
    required this.saveConfig,
    required this.onClose,
  });

  final String themeId;
  final Future<Map<String, dynamic>> Function() readConfig;
  final Future<void> Function(Map<String, dynamic>) saveConfig;
  final VoidCallback onClose;

  @override
  State<_ThemeMenuWindow> createState() => _ThemeMenuWindowState();
}

class _ThemeMenuWindowState extends State<_ThemeMenuWindow> {
  double _left = 32;
  double _top = 96;
  double _width = 340;
  double _height = 480;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final w = _width > screen.width ? screen.width - 24 : _width;
    final h = _height > screen.height ? screen.height - 48 : _height;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onClose,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.25)),
          ),
        ),
        Positioned(
          left: _left.clamp(0.0, screen.width - w - 8),
          top: _top.clamp(0.0, screen.height - h - 8),
          width: w,
          height: h,
          child: Stack(
            children: [
              Material(
                elevation: 28,
                shadowColor: Colors.black54,
                borderRadius: BorderRadius.circular(22),
                clipBehavior: Clip.antiAlias,
                color: const Color(0xFF111319),
                child: Column(
                  children: [
                    _buildHeader(),
                    Expanded(
                      child: ThemeMenuView(
                        themeId: widget.themeId,
                        readConfig: widget.readConfig,
                        saveConfig: widget.saveConfig,
                        onClose: widget.onClose,
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onPanUpdate: _resize,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: const BoxDecoration(
                      color: Colors.black38,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(14),
                      ),
                    ),
                    child: const Icon(
                      Icons.open_in_full,
                      size: 14,
                      color: Colors.white54,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _resize(DragUpdateDetails details) {
    final screen = MediaQuery.of(context).size;
    setState(() {
      _width = (_width + details.delta.dx).clamp(240.0, screen.width - 16.0);
      _height = (_height + details.delta.dy).clamp(240.0, screen.height - 16.0);
    });
  }

  Widget _buildHeader() {
    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          _left += details.delta.dx;
          _top += details.delta.dy;
        });
      },
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
          color: Color(0xFF1A1D24),
          border: Border(bottom: BorderSide(color: Color(0xFF2A2F38))),
        ),
        child: Row(
          children: [
            const Icon(Icons.drag_indicator, size: 18, color: Colors.white38),
            const SizedBox(width: 4),
            const Expanded(
              child: Text(
                '主题配置菜单',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, size: 18, color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主题菜单 WebView 本体：加载主题包 `html/menu.html`，注入 DSHThemeMenu 桥。
class ThemeMenuView extends StatefulWidget {
  const ThemeMenuView({
    super.key,
    required this.themeId,
    required this.readConfig,
    required this.saveConfig,
    required this.onClose,
  });

  final String themeId;
  final Future<Map<String, dynamic>> Function() readConfig;
  final Future<void> Function(Map<String, dynamic>) saveConfig;
  final VoidCallback onClose;

  @override
  State<ThemeMenuView> createState() => _ThemeMenuViewState();
}

class _ThemeMenuViewState extends State<ThemeMenuView> {
  late final WebViewController _controller;
  final _bridge = ProotBridge();
  bool _loading = true;
  String? _error;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('ThemeMenuBridge',
          onMessageReceived: _onBridgeMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => _loading = false);
          },
        ),
      );
    _start();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final guestMenu =
          '${ThemeNotifier.packagesRoot}/${widget.themeId}/html/menu.html';
      final hostMenu = await _bridge.hostPath(path: guestMenu, scope: 'shell');
      final file = File(hostMenu);
      if (!file.existsSync()) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = '此主题没有菜单\n请添加 html/menu.html';
        });
        return;
      }
      final htmlDir = file.parent.path;
      var html = await file.readAsString();
      final prepared = _prepareMenuHtml(
        html,
        guestPackageRoot: '${ThemeNotifier.packagesRoot}/${widget.themeId}',
      );
      if (!mounted) return;
      await _controller.loadHtmlString(
        prepared,
        baseUrl: Uri.file('$htmlDir/').toString(),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '菜单加载失败：$e';
      });
    }
  }

  String _prepareMenuHtml(String html, {required String guestPackageRoot}) {
    const forceScroll = '''
<style>
html, body { height: auto !important; min-height: 100% !important; overflow-y: auto !important; -webkit-overflow-scrolling: touch !important; }
</style>
''';
    final bridge = '''
<script data-dsh-theme-menu-bridge>
(function () {
  if (window.DSHThemeMenu && window.DSHThemeMenu.__dsh) return;
  window.DSH_MENU_PACKAGE_ROOT = '$guestPackageRoot';
  window.__dshMenuCallbacks = window.__dshMenuCallbacks || {};
  function post(msg) {
    try { ThemeMenuBridge.postMessage(JSON.stringify(msg)); } catch (e) {}
  }
  window.DSHThemeMenu = {
    __dsh: true,
    getConfig: function (callback) {
      window.__dshMenuCallbacks.__last = callback;
      post({ cmd: 'getConfig' });
    },
    __configResult: function (json) {
      var cb = window.__dshMenuCallbacks.__last;
      if (typeof cb === 'function') cb(JSON.parse(json));
    },
    saveConfig: function (config) {
      post({ cmd: 'saveConfig', config: config || {} });
    },
    close: function () { post({ cmd: 'close' }); },
    effect: function (e) { post({ cmd: 'effect', effect: e }); },
    remove: function (id) { post({ cmd: 'remove', id: id }); },
    clear: function () { post({ cmd: 'clear' }); },
    styleComponent: function (options) {
      post({ cmd: 'styleComponent', options: options || {} });
    },
    queryComponents: function (opts) {
      opts = opts || {};
      window.__dshMenuCallbacks.__q = opts.callback || null;
      post({ cmd: 'queryComponents', page: opts.page, type: opts.type });
    },
    __componentResult: function (list) {
      var cb = window.__dshMenuCallbacks.__q;
      if (typeof cb === 'function') cb(list);
    }
  };
})();
</script>
''';
    html = forceScroll + html;
    final bodyStart = html.indexOf('<body');
    final bodyTagEnd = bodyStart >= 0 ? html.indexOf('>', bodyStart) : -1;
    final bodyEnd = html.lastIndexOf('</body>');
    if (bodyTagEnd >= 0) {
      return html.replaceRange(bodyTagEnd + 1, bodyTagEnd + 1, '\n$bridge\n');
    }
    if (bodyEnd >= 0) {
      return html.replaceFirst('</body>', '$bridge</body>');
    }
    return '$bridge$html';
  }

  Future<void> _onBridgeMessage(JavaScriptMessage message) async {
    final raw = message.message;
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    if (data == null) return;
    final cmd = data['cmd']?.toString() ?? '';
    switch (cmd) {
      case 'getConfig':
        final config = await widget.readConfig();
        if (!mounted) return;
        await _run(
          'window.DSHThemeMenu && window.DSHThemeMenu.__configResult('
          '${jsonEncode(jsonEncode(config))});',
        );
        break;
      case 'saveConfig':
        final config = data['config'];
        if (config is Map) {
          await widget.saveConfig(Map<String, dynamic>.from(config));
        }
        break;
      case 'close':
        if (!_closing) {
          _closing = true;
          widget.onClose();
        }
        break;
      case 'effect':
        final effect = ThemeEffectBridge.parseEffect(data['effect']);
        if (effect != null) ThemeEffectsController.instance.upsert(effect);
        break;
      case 'remove':
        final id = data['id']?.toString() ?? '';
        if (id.isNotEmpty) ThemeEffectsController.instance.remove(id);
        break;
      case 'clear':
        ThemeEffectsController.instance.clear();
        ThemeEffectsController.instance.clearComponentStyles();
        break;
      case 'styleComponent':
        _handleStyleComponent(data['options']);
        break;
      case 'queryComponents':
        final page = data['page']?.toString();
        final type = data['type']?.toString();
        final list = ThemeComponentRegistry.instance
            .query(page: page, type: type)
            .map((a) => a.toJson())
            .toList();
        if (!mounted) return;
        await _run(
          'window.DSHThemeMenu && window.DSHThemeMenu.__componentResult('
          '${jsonEncode(jsonEncode(list))});',
        );
        break;
    }
  }

  void _handleStyleComponent(Object? options) {
    if (options is! Map) return;
    final style = ThemeEffectBridge.parseComponentStyle(options);
    if (style == null) return;
    final page = options['page']?.toString();
    final type = options['type']?.toString();
    final rawIndex = options['index'];
    final pageFilter = page == null || page == '*' ? null : page;
    final typeFilter = type == null || type == '*' ? null : type;
    final anchors = ThemeComponentRegistry.instance
        .query(page: pageFilter, type: typeFilter);
    for (final a in anchors) {
      if (rawIndex != null && a.index != (rawIndex as num).toInt()) continue;
      ThemeEffectsController.instance.applyComponentStyle(
        page: a.page,
        type: a.type,
        index: a.index,
        style: style,
      );
    }
  }

  Future<void> _run(String js) async {
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ),
      );
    }
    return Stack(
      children: [
        const SizedBox.expand(),
        WebViewWidget(controller: _controller),
        if (_loading)
          const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }
}
