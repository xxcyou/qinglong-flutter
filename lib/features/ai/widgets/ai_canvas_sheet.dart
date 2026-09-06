import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/theme/glass.dart';
import '../models/agent_task_plan.dart';
import '../models/canvas_result_bus.dart';

/// AI 生成的 HTML 互动卡片弹窗。
///
/// 为什么用 WebView 而不是自己渲染：模型最会写的就是 HTML+CSS+JS，
/// 一个恐龙跳跳游戏几十行就出来了。自定义 DSL 只会把它逼回文字。
///
/// 尺寸策略：页面加载完后问它自己 `document.body.scrollHeight` 有多高，
/// 按内容定弹窗高度（夹在屏幕的 32%–88% 之间），而不是一律铺满整屏——
/// 一个 200 像素高的表单撑成全屏很丑。用户想看大就点最大化。
///
/// 安全边界（重要）：
/// - `loadHtmlString` 走 about:blank，页面读不到 APP 的任何数据；
/// - 只注入一个单向通道 `window.aiSubmit(value)`，页面只能"往外说一句话"；
/// - 拦掉所有导航：页面里点外链不会跳走，也不会偷偷加载远端内容。
/// 画布视图的外部句柄：宿主（弹窗/悬浮窗）用它触发重新加载。
class AiCanvasViewController {
  VoidCallback? _reload;

  void reload() => _reload?.call();
}

/// 画布本体（WebView + 回传通道），不带任何外壳。
///
/// 抽出来是因为它有两个宿主：AI 页里的底部弹窗、悬浮窗模式下的浮动窗口。
/// 两者外壳不同（一个铺满底部、一个可拖动），但里面这套 WebView、
/// aiSubmit 通道、自报高度的逻辑必须完全一致，否则悬浮窗里的画布
/// 就成了另一套半残的实现。
class AiCanvasView extends StatefulWidget {
  const AiCanvasView({
    super.key,
    required this.canvas,
    this.controller,
    this.onHeight,
    this.onSubmit,
    this.onRequestClose,
  });

  final AiCanvas canvas;
  final AiCanvasViewController? controller;

  /// 页面自己调用 `aiClose()` 请求关窗（游戏结束自动收起这类）。
  final VoidCallback? onRequestClose;

  /// 页面自报的内容高度（逻辑像素），宿主拿它决定窗口多高。
  final ValueChanged<double>? onHeight;

  /// 用户提交了结果。宿主决定要不要关自己。
  final VoidCallback? onSubmit;

  @override
  State<AiCanvasView> createState() => _AiCanvasViewState();
}

class _AiCanvasViewState extends State<AiCanvasView> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _submitted = false;

  /// 这个画布在窗口总线上的名字。空 = 不参与窗口互通。
  String get _busName =>
      widget.canvas.window.isNotEmpty ? widget.canvas.window : widget.canvas.id;

  @override
  void initState() {
    super.initState();
    widget.controller?._reload = _reload;
    // 挂上窗口总线：别的画布窗口可以给这个窗口发消息。
    CanvasBus.register(_busName, _deliver);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      // 页面 → APP 的唯一通道。两个消息：submit（提交结果）、size（自报高度）。
      ..addJavaScriptChannel('AiBridge', onMessageReceived: _onBridgeMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => _loading = false);
            _measure();
          },
          // 内容里的链接一律不放行：这是个展示容器，不是浏览器。
          onNavigationRequest: (request) => request.url.startsWith('about:')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
        ),
      )
      ..loadHtmlString(_wrap(widget.canvas.html));
  }

  @override
  void dispose() {
    if (widget.controller?._reload == _reload) {
      widget.controller?._reload = null;
    }
    CanvasBus.unregister(_busName);
    super.dispose();
  }

  /// 别的窗口发来的消息 → 丢进页面的 window.onAiMessage。
  void _deliver(String from, String payload) {
    if (!mounted) return;
    final js = 'window.__aiDeliver&&window.__aiDeliver('
        '${jsonEncode(from)},${jsonEncode(payload)})';
    // 页面还没加载完就先攒着没意义（画布是即时界面），失败就丢掉。
    _controller.runJavaScript(js).catchError((_) {});
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _loading = true);
    _controller.loadHtmlString(_wrap(widget.canvas.html));
  }

  void _onBridgeMessage(JavaScriptMessage message) {
    Map<String, dynamic>? payload;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is Map<String, dynamic>) payload = decoded;
    } catch (_) {
      // 不是我们的协议，忽略。
    }
    if (payload == null) return;
    switch (payload['type']) {
      case 'size':
        final height = (payload['height'] as num?)?.toDouble();
        if (height != null && height > 0) widget.onHeight?.call(height);
      case 'submit':
        _submit(payload['value']?.toString() ?? '');
      case 'post':
        // 窗口之间互发消息：由 Dart 侧转发到目标窗口。
        CanvasBus.post(
          _busName,
          payload['to']?.toString() ?? '',
          payload['value']?.toString() ?? '',
        );
      case 'close':
        widget.onRequestClose?.call();
    }
  }

  void _submit(String value) {
    if (_submitted) return;
    _submitted = true;
    CanvasResultBus.submit(widget.canvas.id, value);
    HapticFeedback.mediumImpact();
    widget.onSubmit?.call();
  }

  Future<void> _measure() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        'Math.max(document.body.scrollHeight,'
        'document.documentElement.scrollHeight)',
      );
      final height = double.tryParse(raw.toString().replaceAll('"', ''));
      if (height != null && height > 0) widget.onHeight?.call(height);
    } catch (_) {
      // 量不到就用默认高度，不是错误。
    }
  }

  /// 补上 viewport、深色底和回传通道。
  ///
  /// 模型经常忘了写 meta，结果页面在手机上巨小；每次都靠提示词纠正不如
  /// 这里兜住。注入的脚本放在 <head> 最前面，保证页面脚本能用上 aiSubmit。
  String _wrap(String html) {
    final injected = '''
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<style>html,body{margin:0;padding:0;background:#0f1115;color:#e8eaed;font-family:-apple-system,"Noto Sans SC",sans-serif;-webkit-tap-highlight-color:transparent;}</style>
<script>
window.aiWindow=${jsonEncode(_busName)};
window.aiSubmit=function(v){try{AiBridge.postMessage(JSON.stringify({type:'submit',value:(typeof v==='string')?v:JSON.stringify(v)}));}catch(e){}};
window.aiReportSize=function(){try{var h=Math.max(document.body.scrollHeight,document.documentElement.scrollHeight);AiBridge.postMessage(JSON.stringify({type:'size',height:h}));}catch(e){}};
window.aiSend=function(to,v){try{AiBridge.postMessage(JSON.stringify({type:'post',to:to||'*',value:(typeof v==='string')?v:JSON.stringify(v)}));}catch(e){}};
window.aiClose=function(){try{AiBridge.postMessage(JSON.stringify({type:'close'}));}catch(e){}};
window.__aiDeliver=function(from,msg){try{if(typeof window.onAiMessage==='function'){window.onAiMessage(msg,from);}else{window.dispatchEvent(new MessageEvent('ai-message',{data:{from:from,message:msg}}));}}catch(e){}};
window.addEventListener('load',function(){window.aiReportSize();setTimeout(window.aiReportSize,300);});
</script>
''';
    if (html.contains('<head>')) {
      return html.replaceFirst('<head>', '<head>$injected');
    }
    if (html.contains('<html>')) {
      return html.replaceFirst('<html>', '<html><head>$injected</head>');
    }
    return '<!DOCTYPE html><html><head>$injected</head>'
        '<body>$html</body></html>';
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        WebViewWidget(controller: _controller),
        if (_loading) const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}

/// 画布的标题栏。弹窗和悬浮窗共用，只是按钮组略有差异。
class AiCanvasHeader extends StatelessWidget {
  const AiCanvasHeader({
    super.key,
    required this.canvas,
    required this.awaiting,
    required this.onReload,
    required this.onClose,
    this.onToggleMax,
    this.maximized = false,
  });

  final AiCanvas canvas;
  final bool awaiting;
  final VoidCallback onReload;
  final VoidCallback onClose;
  final VoidCallback? onToggleMax;
  final bool maximized;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
      child: Row(
        children: [
          Icon(
            awaiting ? Icons.touch_app_outlined : Icons.widgets_outlined,
            size: 18,
            color: awaiting ? Colors.orange.shade600 : scheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  canvas.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (awaiting && canvas.resultHint.isNotEmpty)
                  Text(
                    canvas.resultHint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Colors.orange.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                else if (canvas.description.isNotEmpty)
                  Text(
                    canvas.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (onToggleMax != null)
            IconButton(
              tooltip: maximized ? '恢复默认大小' : '最大化',
              onPressed: onToggleMax,
              icon: Icon(
                maximized ? Icons.close_fullscreen : Icons.open_in_full,
                size: 19,
              ),
            ),
          IconButton(
            tooltip: '重新加载',
            onPressed: onReload,
            icon: const Icon(Icons.refresh, size: 20),
          ),
          IconButton(
            tooltip: awaiting ? '放弃这次交互（AI 会收到"用户没提交"）' : '关闭（信息卡片还在，随时能再打开）',
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
    );
  }
}

class AiCanvasSheet extends StatefulWidget {
  const AiCanvasSheet({super.key, required this.canvas});

  final AiCanvas canvas;

  /// 弹出画布。用 rootNavigator 是为了在悬浮窗里也能正常盖住整屏。
  static Future<void> show(BuildContext context, AiCanvas canvas) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      // 等结果的卡片不许点外面误关：关掉就等于放弃这次交互。
      isDismissible: !canvas.expectResult,
      // 竖向拖动由卡片自己接管（慢拖 = 调大小，快甩 = 关闭）。
      // 交给系统的 enableDrag 只会"一拖就关"，用户想调大小根本调不了。
      enableDrag: false,
      builder: (context) => AiCanvasSheet(canvas: canvas),
    );
  }

  @override
  State<AiCanvasSheet> createState() => _AiCanvasSheetState();
}

class _AiCanvasSheetState extends State<AiCanvasSheet> {
  final _view = AiCanvasViewController();
  bool _maximized = false;
  bool _submitted = false;

  /// 页面自报的内容高度（逻辑像素）。null = 还没量到。
  double? _contentHeight;

  /// 用户自己拖出来的高度占比（0~1）。null = 还没拖过，按内容自适应。
  ///
  /// 一旦用户拖过，就再也不跟着内容自动变了——内容一变高度就跳，
  /// 手感上像"弹窗自己不听话"。
  double? _userFactor;

  /// 正在拖动：拖动期间关掉高度动画，否则跟手会有一帧延迟。
  bool _dragging = false;

  /// 拖到这个比例以下松手就关掉。太小的窗口除了挡视线没别的用。
  static const _closeFactor = 0.16;

  /// "像滑视频一样下滑关闭"的速度门槛（逻辑像素/秒）。
  static const _flingVelocity = 780.0;

  /// 用户能拖到的上下限。
  static const _minFactor = 0.14;
  static const _maxFactor = 1.0;

  /// 按内容算弹窗高度：小内容不撑满，大内容不超过 88% 屏高。
  double _sheetHeight(BoxConstraints constraints) {
    final available = constraints.maxHeight;
    if (_maximized) return available;
    final factor = _userFactor;
    // 用户拖过就完全听用户的。
    if (factor != null) {
      return (available * factor).clamp(available * _minFactor, available);
    }
    final content = _contentHeight;
    // 量不到高度时给一个偏舒适的默认值：小游戏基本都在这个量级。
    if (content == null) return available * 0.62;
    // 内容高度 + 头部条 + 一点呼吸空间。
    final wanted = content + 132;
    return wanted.clamp(available * 0.32, available * 0.88);
  }

  void _dragUpdate(DragUpdateDetails d, BoxConstraints constraints) {
    final available = constraints.maxHeight;
    if (available <= 0) return;
    final current = _sheetHeight(constraints);
    // 往下拖 = 变矮，所以减 delta。
    final next = (current - d.delta.dy) / available;
    setState(() {
      _dragging = true;
      _maximized = false;
      _userFactor = next.clamp(_minFactor, _maxFactor);
    });
  }

  void _dragEnd(DragEndDetails d, BoxConstraints constraints) {
    final velocity = d.velocity.pixelsPerSecond.dy;
    setState(() => _dragging = false);
    // 大力下滑：像划走短视频一样直接关掉。
    if (velocity > _flingVelocity) {
      Navigator.of(context).maybePop();
      return;
    }
    // 拖得太小也当关闭意图。
    if ((_userFactor ?? 1) <= _closeFactor) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final awaiting = widget.canvas.expectResult && !_submitted;
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Padding(
            padding: EdgeInsets.only(
              left: _maximized ? 0 : 8,
              right: _maximized ? 0 : 8,
              bottom: _maximized ? 0 : 8,
              top: _maximized ? media.padding.top : 0,
            ),
            child: AnimatedContainer(
              duration: Duration(milliseconds: _dragging ? 0 : 220),
              curve: Curves.easeOutCubic,
              height: _sheetHeight(constraints),
              child: GlassPanel(
                radius: _maximized ? 0 : 24,
                blur: Glass.blurStrong,
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    // 抓手 + 标题栏都能拖：慢拖调大小，快甩下滑关闭。
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (d) => _dragUpdate(d, constraints),
                      onVerticalDragEnd: (d) => _dragEnd(d, constraints),
                      child: Column(
                        children: [
                          _GrabBar(dragging: _dragging),
                          AiCanvasHeader(
                            canvas: widget.canvas,
                            awaiting: awaiting,
                            maximized: _maximized,
                            onToggleMax: () => setState(() {
                              _maximized = !_maximized;
                              // 最大化/还原是显式动作，清掉手动高度，
                              // 否则"还原"会还原到上次拖的那个奇怪高度。
                              _userFactor = null;
                            }),
                            onReload: _view.reload,
                            onClose: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(_maximized ? 0 : 24),
                        ),
                        child: AiCanvasView(
                          canvas: widget.canvas,
                          controller: _view,
                          onHeight: (h) {
                            if (!mounted) return;
                            // 用户已经手动定过高度就别再抢方向盘。
                            if (_userFactor != null) return;
                            setState(() => _contentHeight = h);
                          },
                          onSubmit: () {
                            if (!mounted) return;
                            setState(() => _submitted = true);
                            Navigator.of(context).maybePop();
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 弹窗顶部的抓手条。拖动时高亮，告诉用户"这里可以拖"。
class _GrabBar extends StatelessWidget {
  const _GrabBar({required this.dragging});

  final bool dragging;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 7, bottom: 1),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: dragging ? 54 : 38,
        height: 4,
        decoration: BoxDecoration(
          color:
              scheme.onSurfaceVariant.withValues(alpha: dragging ? 0.7 : 0.35),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 聊天流里的画布入口卡片。
///
/// 弹窗关掉不等于内容没了：这张卡片一直留在对话里，点一下就重新打开。
class AiCanvasCard extends StatelessWidget {
  const AiCanvasCard({super.key, required this.canvas, this.margin});

  final AiCanvas canvas;

  /// 外边距。默认 top:8 是"卡在气泡上方"的排版；卡在气泡下方时要由调用方
  /// 改成 bottom，否则它会贴上下一条消息（气泡本身没有 top margin）。
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final awaiting = CanvasResultBus.isAwaited(canvas.id);
    final accent = awaiting ? Colors.orange.shade700 : scheme.primary;
    return InfoCardShell(
      accent: accent,
      margin: margin ?? const EdgeInsets.only(top: 8),
      child: InkWell(
        onTap: () => AiCanvasSheet.show(context, canvas),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
          child: Row(
            children: [
              InfoCardBadge(
                color: accent,
                child: Icon(
                  awaiting
                      ? Icons.touch_app_rounded
                      : Icons.auto_awesome_mosaic_rounded,
                  size: 15,
                  color: accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            canvas.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                        if (awaiting)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '待操作',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: accent,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      awaiting
                          ? (canvas.resultHint.isEmpty
                              ? 'AI 在等你操作，点开继续'
                              : 'AI 在等你：${canvas.resultHint}')
                          : (canvas.description.isEmpty
                              ? '点开查看互动内容'
                              : canvas.description),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        color: awaiting ? accent : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.open_in_full_rounded,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 任务清单卡片：AI 拆出来的步骤 + 实时勾选状态。
class TaskPlanCard extends StatelessWidget {
  const TaskPlanCard({super.key, required this.plan, this.margin});

  final AgentTaskPlan plan;
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    if (plan.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final done = plan.doneCount;
    final total = plan.items.length;
    final accent = done == total ? Colors.green.shade600 : scheme.primary;
    return InfoCardShell(
      accent: accent,
      margin: margin ?? const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                InfoCardBadge(
                  color: accent,
                  child: Icon(
                    done == total
                        ? Icons.task_alt_rounded
                        : Icons.checklist_rounded,
                    size: 15,
                    color: accent,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    plan.goal.isEmpty ? '任务清单' : plan.goal,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '$done/$total',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : done / total,
                minHeight: 4,
                backgroundColor: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < plan.items.length; i++)
              _StepRow(index: i + 1, item: plan.items[i]),
          ],
        ),
      ),
    );
  }
}

/// 输入框上方的清单条：跑长任务时一眼看到"现在到第几步"。
///
/// 聊天列表里那张完整清单会被新消息推到上面看不见，所以这里再来一条常驻的
/// 精简版——只显示进度和当前那一步，点一下展开全部。
class TaskPlanStrip extends StatefulWidget {
  const TaskPlanStrip({super.key, required this.plan, this.running = false});

  final AgentTaskPlan plan;
  final bool running;

  @override
  State<TaskPlanStrip> createState() => _TaskPlanStripState();
}

class _TaskPlanStripState extends State<TaskPlanStrip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    if (plan.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final done = plan.doneCount;
    final total = plan.items.length;
    final current = plan.current;
    return GlassPanel(
      radius: 16,
      blur: 18,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: widget.running && current != null
                    ? CircularProgressIndicator(
                        strokeWidth: 2,
                        value: total == 0 ? null : done / total,
                      )
                    : Icon(
                        done == total
                            ? Icons.task_alt
                            : Icons.checklist_rounded,
                        size: 16,
                        color: scheme.primary,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  current == null
                      ? '清单已走完（$done/$total）'
                      : '第 ${plan.items.indexOf(current) + 1}/$total 步：'
                          '${current.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                _expanded ? Icons.expand_more : Icons.expand_less,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
          if (_expanded) ...[
            const SizedBox(height: 6),
            for (var i = 0; i < plan.items.length; i++)
              _StepRow(index: i + 1, item: plan.items[i]),
          ],
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.index, required this.item});

  final int index;
  final AgentSubtask item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (item.status) {
      SubtaskStatus.done => (Icons.check_circle, Colors.green.shade500),
      SubtaskStatus.failed => (Icons.error, scheme.error),
      SubtaskStatus.running => (Icons.autorenew, scheme.primary),
      SubtaskStatus.skipped => (Icons.remove_circle_outline, scheme.outline),
      SubtaskStatus.pending => (
          Icons.radio_button_unchecked,
          scheme.onSurfaceVariant,
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$index. ${item.title}',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    decoration: item.status == SubtaskStatus.skipped
                        ? TextDecoration.lineThrough
                        : null,
                    color: item.status == SubtaskStatus.pending
                        ? scheme.onSurfaceVariant
                        : scheme.onSurface,
                    fontWeight: item.status == SubtaskStatus.running
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
                if (item.note.isNotEmpty)
                  Text(
                    item.note,
                    style: TextStyle(
                      fontSize: 11,
                      color: item.status == SubtaskStatus.failed
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
