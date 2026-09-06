import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/glass.dart';
import '../models/agent_event.dart';
import '../../../shared/mono_text.dart';

/// 单个工具调用的详情页：完整参数 + 完整返回。
///
/// 为什么要单独一页：时间线里塞不下几万字符的返回，而排障时要看的往往正是
/// 那一整坨原文。这里给的是**未截断**的原始返回（喂给模型的那份为了省 token
/// 会砍中段），并且参数与返回分栏、能搜、能复制。
class ToolDetailSheet extends StatefulWidget {
  const ToolDetailSheet({super.key, required this.event});

  final AgentEvent event;

  /// 弹出详情。
  ///
  /// **不能用 showModalBottomSheet**：底部弹窗是一条 Navigator 路由，而悬浮窗
  /// 是画在 Navigator **之上**的独立 Overlay。在悬浮窗里点开一行，弹窗会整块
  /// 生在悬浮窗底下——用户看到的就是"点了没反应"。
  ///
  /// 改成往**最近的 Overlay** 插一层：在悬浮窗里就落在悬浮窗自己那层
  /// （盖得住、点得到），在普通页面里就落在路由 Overlay 上，行为和以前一样。
  static void show(BuildContext context, AgentEvent event) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      entry.remove();
    }

    entry = OverlayEntry(
      builder: (context) => _DetailLayer(event: event, onClose: close),
    );
    overlay.insert(entry);
  }

  @override
  State<ToolDetailSheet> createState() => _ToolDetailSheetState();
}

class _ToolDetailSheetState extends State<ToolDetailSheet> {
  /// 当前分栏。默认落在第一个**有内容**的分栏上：
  /// 工具调用看返回，思考看正文，光有参数就直接进参数。
  late String _tab = _tabs.first.id;
  final _search = TextEditingController();
  bool _wrap = true;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 这条事件到底有哪几栏可看。
  ///
  /// 之前固定「返回 / 参数」两栏，于是思考、提问、任务清单这些没有 args/result
  /// 的事件点进来两栏全空——看起来就是"点了没东西，敷衍我"。实际内容一直在
  /// [AgentEvent.message] 里（思考全文就存在那儿），只是没人显示它。
  List<_Pane> get _tabs {
    final e = widget.event;
    final panes = <_Pane>[];
    final result = e.displayResult.trim();
    final args = e.args;
    final message = e.message.trim();
    // 思考类事件：正文就是思考全文，放第一栏。
    final isThinking = e.kind == AgentEventKind.thinking;
    if (isThinking && message.isNotEmpty) {
      panes.add(_Pane('think', '思考全文', message));
    }
    if (result.isNotEmpty) {
      panes.add(_Pane('result', '返回', _prettyIfJson(result)));
    }
    if (args != null && args.isNotEmpty) {
      panes.add(_Pane('args', '参数', _encode(args)));
      // 参数里带大段代码/HTML 的（ui_canvas 就是），单独抽一栏原样看，
      // 免得被 JSON 转义成一行 \n 完全读不了。
      for (final key in const [
        'html',
        'code',
        'script',
        'content',
        'command'
      ]) {
        final v = args[key];
        if (v is String && v.trim().length > 40) {
          panes.add(_Pane('raw_$key', key, v));
        }
      }
    }
    if (!isThinking && message.isNotEmpty && message != result) {
      panes.add(_Pane('message', '说明', message));
    }
    if (panes.isEmpty) {
      panes.add(
        _Pane('empty', '详情', '这一步没有留下参数和返回。\n（$_kindLabel）'),
      );
    }
    return panes;
  }

  String get _kindLabel => switch (widget.event.kind) {
        AgentEventKind.thinking => '模型思考',
        AgentEventKind.toolStart => '开始调用工具',
        AgentEventKind.toolEnd => '工具返回',
        AgentEventKind.planPending => '等待确认写操作',
        AgentEventKind.question => '向用户提问',
        AgentEventKind.taskPlan => '任务清单更新',
        AgentEventKind.canvas => '互动卡片',
        AgentEventKind.answer => '正文',
        AgentEventKind.error => '出错',
        AgentEventKind.done => '收尾',
      };

  static String _encode(Map<String, dynamic> args) {
    try {
      return const JsonEncoder.withIndent('  ').convert(args);
    } catch (_) {
      return args.toString();
    }
  }

  /// 返回是 JSON 时格式化一下——接口返回压成一行没法读。
  static String _prettyIfJson(String text) {
    final trimmed = text.trim();
    if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) return text;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(trimmed));
    } catch (_) {
      return text;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final event = widget.event;
    final panes = _tabs;
    final pane =
        panes.firstWhere((p) => p.id == _tab, orElse: () => panes.first);
    final body = pane.body;
    final keyword = _search.text.trim();
    final lines = keyword.isEmpty
        ? body.split('\n')
        : body
            .split('\n')
            .where((l) => l.toLowerCase().contains(keyword.toLowerCase()))
            .toList();

    return Padding(
      padding: EdgeInsets.only(top: media.padding.top + 24),
      child: GlassPanel(
        radius: 26,
        blur: Glass.blurStrong,
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: (event.ok ? Colors.green : scheme.error)
                          .withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      event.ok ? '成功' : '失败',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: event.ok ? Colors.green.shade700 : scheme.error,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      event.toolName?.isNotEmpty == true
                          ? event.toolName!
                          : _kindLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        fontFamily: kMonoFamily,
                        fontFamilyFallback: kMonoFallback,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => _DetailLayer.dismiss(context),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        _kindLabel,
                        if (event.turn > 0) '第 ${event.turn} 轮',
                        if (event.durationMs != null) '${event.durationMs}ms',
                        if (event.displayResult.isNotEmpty)
                          '返回 ${event.displayResult.length} 字符',
                        if (event.omittedChars > 0)
                          '模型只看到前后各一段（省了 ${event.omittedChars} 字符）',
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final p in panes) ...[
                            _chip(p.label, p.id),
                            const SizedBox(width: 6),
                          ],
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _wrap ? '不折行（横向滚动）' : '自动折行',
                    onPressed: () => setState(() => _wrap = !_wrap),
                    icon: Icon(
                      _wrap ? Icons.wrap_text : Icons.short_text,
                      size: 19,
                    ),
                  ),
                  IconButton(
                    tooltip: '复制当前内容',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: body));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: SizedBox(
                height: 36,
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontSize: 12.5),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    hintText: '过滤行（只显示含关键字的行）',
                    prefixIcon: Icon(
                      Icons.search,
                      size: 17,
                      color: scheme.onSurfaceVariant,
                    ),
                    suffixIcon: keyword.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _search.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.clear, size: 16),
                          ),
                  ),
                ),
              ),
            ),
            Divider(
                height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
            Expanded(
              child: keyword.isNotEmpty && lines.isEmpty
                  ? Center(
                      child: Text(
                        '没有含 "$keyword" 的行',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 28),
                      child: _wrap
                          ? SelectableText(
                              lines.join('\n'),
                              style: const TextStyle(
                                fontSize: 11.5,
                                height: 1.4,
                                fontFamily: kMonoFamily,
                                fontFamilyFallback: kMonoFallback,
                              ),
                            )
                          : SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SelectableText(
                                lines.join('\n'),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  height: 1.4,
                                  fontFamily: kMonoFamily,
                                  fontFamilyFallback: kMonoFallback,
                                ),
                              ),
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, String id) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _tab == id;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => setState(() => _tab = id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.16)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.4)
                : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 详情页的一个分栏：标签 + 正文。
class _Pane {
  const _Pane(this.id, this.label, this.body);

  final String id;
  final String label;
  final String body;
}

/// 详情层：一层半透明遮罩 + 面板。直接插在 Overlay 上，不占 Navigator 路由。
///
/// 这样它在悬浮窗里也能盖在最上面；点遮罩、点右上角 × 都能关掉。
class _DetailLayer extends StatefulWidget {
  const _DetailLayer({required this.event, required this.onClose});

  final AgentEvent event;
  final VoidCallback onClose;

  /// 子树里任何位置都能请求关闭这一层。
  static void dismiss(BuildContext context) {
    // 在回调里调用，所以只能用 get（dependOn 只允许在 build 中用）。
    final scope =
        context.getInheritedWidgetOfExactType<_DetailLayerScope>()?.onClose;
    if (scope != null) {
      scope();
      return;
    }
    // 兜底：万一有人在路由里直接用了 ToolDetailSheet。
    Navigator.of(context).maybePop();
  }

  @override
  State<_DetailLayer> createState() => _DetailLayerState();
}

class _DetailLayerState extends State<_DetailLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    // 先播完退场再摘掉 entry，否则详情会"啪"地消失。
    if (mounted) await _controller.reverse();
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    return _DetailLayerScope(
      onClose: _close,
      // 返回键先关这一层，别把底下的页面一起退掉。
      //
      // 只在**能拿到 Router 的地方**挂：悬浮窗的 Overlay 在 Router 之外，
      // BackButtonListener 在那里会直接抛"context does not include a Router"。
      child: _MaybeBackListener(
        onBack: _close,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final t = Curves.easeOutCubic.transform(_controller.value);
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _close,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.42 * t),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: FractionalTranslation(
                    translation: Offset(0, 1 - t),
                    // 面板自己不该吃掉遮罩的点击，所以只在面板范围内拦。
                    child: GestureDetector(
                      behavior: HitTestBehavior.deferToChild,
                      onTap: () {},
                      // Overlay 里没有 Material 祖先：里面的 InkWell / 波纹
                      // 会直接抛 "No Material widget found"（悬浮窗里点开
                      // 详情就是一屏红字）。补一层透明的 Material。
                      child: Material(
                        type: MaterialType.transparency,
                        child: ToolDetailSheet(event: widget.event),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DetailLayerScope extends InheritedWidget {
  const _DetailLayerScope({required this.onClose, required super.child});

  final VoidCallback onClose;

  @override
  bool updateShouldNotify(_DetailLayerScope oldWidget) =>
      oldWidget.onClose != onClose;
}

/// 有 Router 才挂返回键监听，没有就原样透传。
///
/// 悬浮窗那一层的 Overlay 挂在 Router 之外，直接用 [BackButtonListener]
/// 会在 build 阶段抛异常，整个详情层变成一屏红字。
class _MaybeBackListener extends StatelessWidget {
  const _MaybeBackListener({required this.onBack, required this.child});

  final Future<void> Function() onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Router.maybeOf(context) == null) return child;
    return BackButtonListener(
      onBackButtonPressed: () async {
        await onBack();
        return true;
      },
      child: child,
    );
  }
}
