import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/glass.dart';

import '../../../core/utils/formatter.dart';
import '../models/agent_event.dart';
import '../models/agent_task_plan.dart';
import 'tool_detail_sheet.dart';
import '../../../shared/mono_text.dart';

/// Agent 运行过程卡片：默认折叠，展开后是一条时间线。
///
/// 时间线上的每一行**不再就地展开**大段文本——那是这张卡以前又高又丑的根源。
/// 现在点一行直接开 [ToolDetailSheet]（参数/返回分栏、可搜、可复制、不截断），
/// 时间线本身永远保持一行一步的紧凑排版。
class AgentProcessCard extends StatefulWidget {
  const AgentProcessCard({
    super.key,
    required this.events,
    this.running = false,
    this.turns = 0,
    this.totalTokens = 0,
    this.initiallyExpanded = false,
    this.onOpenCanvas,
    this.liveSubagentReasoning = const {},
    this.liveSubagentContent = const {},
    this.liveSubagentTool = const {},
    this.liveSubagentReasoningChars = const {},
    this.liveSubagentContentChars = const {},
    this.modeLabels = const [],
  });

  final void Function(AiCanvas canvas)? onOpenCanvas;

  final List<AgentEvent> events;
  final bool running;
  final int turns;
  final int totalTokens;
  final bool initiallyExpanded;

  /// 子代理实时流：group → 思考/正文尾部、工具名、真实字数。
  final Map<String, String> liveSubagentReasoning;
  final Map<String, String> liveSubagentContent;
  final Map<String, String> liveSubagentTool;
  final Map<String, int> liveSubagentReasoningChars;
  final Map<String, int> liveSubagentContentChars;

  /// 这一轮挂载的模式标签名，放在标题“执行过程”旁边，横向滚动防溢出。
  final List<String> modeLabels;

  @override
  State<AgentProcessCard> createState() => _AgentProcessCardState();
}

class _AgentProcessCardState extends State<AgentProcessCard> {
  late bool _expanded = widget.initiallyExpanded;

  /// 时间线上真正要画的事件。
  ///
  /// toolStart 只在"还没拿到返回"时有价值：拿到 toolEnd 之后两行讲的是同一件事，
  /// 而 toolStart 那行点进去只有参数、没有返回（就是"返回是空的"那个观感）。
  /// 所以这里把已经有结果的 toolStart 折掉——留下的每一行都同时有参数和返回。
  List<AgentEvent> get _rows {
    final events = widget.events;
    final settled = <String>{};
    for (final e in events) {
      if (e.kind == AgentEventKind.toolEnd) {
        settled.add('${e.turn}|${e.toolName ?? ''}');
      }
    }
    final visible = [
      for (final e in events)
        if (!(e.kind == AgentEventKind.toolStart &&
            settled.contains('${e.turn}|${e.toolName ?? ''}')))
          e,
    ];
    // condition_exec 现在会发很多小步骤；全摊开全是 condition_exec 太费眼。
    // 把连续的小步骤折叠成一行"条件执行 · N 步"，展开/详情里保留完整树形轨迹。
    final grouped = <AgentEvent>[];
    for (var i = 0; i < visible.length;) {
      final e = visible[i];
      if (e.kind == AgentEventKind.workflowStep &&
          e.toolName == 'condition_exec') {
        final trace = StringBuffer();
        final stepCards = <Map<String, dynamic>>[];
        var ok = true;
        final start = i;
        while (i < visible.length &&
            visible[i].kind == AgentEventKind.workflowStep &&
            visible[i].toolName == 'condition_exec') {
          ok = ok && visible[i].ok;
          final stepEvent = visible[i];
          trace.writeln(_TimelineRowState._workflowLine(stepEvent));
          stepCards.add({
            'message': stepEvent.message,
            'result': stepEvent.result,
            'args': stepEvent.args,
            'durationMs': stepEvent.durationMs,
            'depth': _TimelineRowState._workflowDepth(stepEvent),
            'ok': stepEvent.ok,
          });
          i++;
        }
        grouped.add(
          AgentEvent(
            kind: AgentEventKind.workflowStep,
            message: '条件执行 · ${i - start} 步',
            toolName: 'condition_exec',
            args: {
              'count': i - start,
              'collapsed': true,
              'steps': stepCards,
            },
            result: trace.toString().trim(),
            fullResult: trace.toString().trim(),
            ok: ok,
            group: e.group,
          ),
        );
      } else {
        grouped.add(e);
        i++;
      }
    }
    return grouped;
  }

  @override
  void didUpdateWidget(covariant AgentProcessCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldHasImage = oldWidget.events.any(
      (e) => e.kind == AgentEventKind.toolImage && e.imageDataUri != null,
    );
    final newHasImage = widget.events.any(
      (e) => e.kind == AgentEventKind.toolImage && e.imageDataUri != null,
    );
    // 新图片事件到达时自动展开，保证立即看到图，而不是等工具链结束。
    if (newHasImage && !oldHasImage && !_expanded) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final events = _rows;
    final toolCount =
        events.where((e) => e.kind == AgentEventKind.toolEnd).length;
    final failed = events.any(
      (e) => e.kind == AgentEventKind.toolEnd && !e.ok,
    );
    final accent = widget.running
        ? scheme.primary
        : (failed ? scheme.error : Colors.green.shade600);

    return InfoCardShell(
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  InfoCardBadge(
                    color: accent,
                    child: widget.running
                        ? SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: accent,
                            ),
                          )
                        : Icon(
                            failed
                                ? Icons.warning_amber_rounded
                                : Icons.done_all_rounded,
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
                            Flexible(
                              child: Text(
                                widget.running ? '正在执行' : '执行过程',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                            if (widget.modeLabels.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Flexible(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  reverse: true,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (final label in widget.modeLabels)
                                        Container(
                                          margin: const EdgeInsets.only(
                                            left: 3,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: scheme.primary
                                                .withValues(alpha: 0.10),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            border: Border.all(
                                              color: scheme.primary
                                                  .withValues(alpha: 0.25),
                                            ),
                                          ),
                                          child: Text(
                                            '#$label',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: scheme.primary,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(toolCount),
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!_expanded && events.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text(
                _oneLine(events.last),
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.35,
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: _timeline(events),
            ),
        ],
      ),
    );
  }

  /// 时间线：普通事件直接一行；带 `group` 的连续事件（子代理）合成一个
  /// 默认折叠、可展开、折叠态带实时速览的容器。
  Widget _timeline(List<AgentEvent> events) {
    // 先把所有子代理事件按 group 聚齐。并行子代理可能交错出现，
    // 不能只按“连续同组”切，否则一个子代理会被拆成好几个框。
    final order = <String>[];
    final byGroup = <String, List<AgentEvent>>{};
    for (final e in events) {
      final group = e.group;
      if (group == null || group.isEmpty) continue;
      byGroup.putIfAbsent(group, () {
        order.add(group);
        return [];
      }).add(e);
    }
    final used = <String>{};
    final children = <Widget>[];
    for (var i = 0; i < events.length; i++) {
      final e = events[i];
      final group = e.group;
      if (group != null && group.isNotEmpty) {
        if (used.add(group)) {
          children.add(
            _SubagentGroup(
              events: byGroup[group]!,
              running: widget.running,
              onOpenCanvas: widget.onOpenCanvas,
              liveReasoning: widget.liveSubagentReasoning[group] ?? '',
              liveContent: widget.liveSubagentContent[group] ?? '',
              liveTool: widget.liveSubagentTool[group] ?? '',
              liveReasoningChars: widget.liveSubagentReasoningChars[group] ?? 0,
              liveContentChars: widget.liveSubagentContentChars[group] ?? 0,
            ),
          );
        }
      } else {
        children.add(
          _TimelineRow(
            event: e,
            isLast: i == events.length - 1,
            onOpenCanvas: widget.onOpenCanvas,
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  String _subtitle(int toolCount) {
    final parts = <String>[];
    if (widget.turns > 0) parts.add('${widget.turns} 轮');
    if (toolCount > 0) parts.add('$toolCount 次工具');
    // 写明是「计费」而不是含糊的 tokens：它是所有轮次相加的量，
    // 和输入框上的「上下文 %」不是一个数，之前两个数字对不上就是这个原因。
    if (widget.totalTokens > 0) parts.add('计费 ${_kilo(widget.totalTokens)}');
    if (parts.isEmpty) parts.add('${widget.events.length} 步');
    return parts.join(' · ');
  }

  static String _kilo(int value) => Formatter.tokens(value);

  String _oneLine(AgentEvent event) {
    final tool = event.toolName;
    final head = tool == null || tool.isEmpty
        ? event.message
        : '${event.message.split('：').first}：$tool';
    final result = event.result?.replaceAll('\n', ' ').trim() ?? '';
    if (result.isEmpty) return head;
    final short = result.length > 90 ? '${result.substring(0, 90)}…' : result;
    return '$head → $short';
  }
}

class _TimelineRow extends StatefulWidget {
  const _TimelineRow({
    required this.event,
    required this.isLast,
    this.onOpenCanvas,
  });

  final AgentEvent event;
  final bool isLast;

  /// 给 canvas 时间线行加“重新打开悬浮画布”入口。
  final void Function(AiCanvas canvas)? onOpenCanvas;

  @override
  State<_TimelineRow> createState() => _TimelineRowState();
}

class _TimelineRowState extends State<_TimelineRow> {
  /// 这一行是否就地展开成全文。
  ///
  /// 思考/正文经常有好几百字，两行预览根本看不出它在说什么，而每次都要
  /// 弹详情页太重。点一下就地铺开、再点收起，是最省事的看法。
  bool _expanded = false;

  /// 图片字节缓存：同一个 data URI 只在 State 里解一次码，
  /// 避免每次 live 事件刷新都重新解码/重建 Image，造成闪烁。
  Uint8List? _imageBytes;

  @override
  void initState() {
    super.initState();
    final uri = widget.event.imageDataUri;
    if (uri != null && uri.contains(',')) {
      try {
        _imageBytes = base64Decode(uri.split(',').last);
      } catch (_) {
        _imageBytes = null;
      }
    }
  }

  AgentEvent get event => widget.event;

  bool get isLast => widget.isLast;

  /// 每一行都点得进去。
  ///
  /// 以前只有"带参数或带返回"的行可点，思考/清单/收尾这些行没有点击反馈，
  /// 用户以为它们坏了。详情页现在对任何事件都有东西可显示（至少是说明），
  /// 所以不再拦。
  bool get _hasDetail => true;

  AiCanvas? _canvasFromEvent() {
    if (event.kind != AgentEventKind.canvas) return null;
    final args = event.args ?? const <String, dynamic>{};
    String valueOf(String key) => (args[key]?.toString() ?? '').trim();
    final html = args['html']?.toString() ?? '';
    final url = valueOf('url');
    final htmlPath = valueOf('html_path').isNotEmpty
        ? valueOf('html_path')
        : valueOf('path');
    if (html.isEmpty && url.isEmpty && htmlPath.isEmpty) return null;
    final rawRect = args['rect'];
    return AiCanvas(
      id: args['id']?.toString() ??
          'canvas${DateTime.now().microsecondsSinceEpoch}',
      title: valueOf('title').isEmpty ? '互动卡片' : valueOf('title'),
      description: valueOf('description'),
      html: html,
      url: url,
      htmlPath: htmlPath,
      baseDir: valueOf('base_dir'),
      expectResult: args['expect_result'] == true,
      resultHint: valueOf('result_hint'),
      createdAt: DateTime.now(),
      window: valueOf('window'),
      chromeless: args['chromeless'] == true,
      position: valueOf('position'),
      rect: rawRect is List && rawRect.length >= 4
          ? [
              for (final v in rawRect.take(4)) (v is num) ? v.toDouble() : 0.0,
            ]
          : null,
    );
  }

  List<Map<String, dynamic>>? get _workflowSteps {
    if (event.kind != AgentEventKind.workflowStep) return null;
    final steps = event.args?['steps'];
    if (steps is List && steps.isNotEmpty) {
      return steps.cast<Map<String, dynamic>>();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visual = _visualFor(event, scheme);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            const SizedBox(height: 9),
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: visual.color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(visual.icon, size: 11, color: visual.color),
            ),
            if (!isLast)
              Container(
                width: 1.5,
                height: 20,
                margin: const EdgeInsets.symmetric(vertical: 2),
                color: scheme.outlineVariant.withValues(alpha: 0.7),
              ),
          ],
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              left: _workflowDepth(event) * 14.0,
            ),
            child: InkWell(
              // 点一行 = 就地展开全文（思考/正文常有几百字，两行看不出内容）。
              // 想看参数/返回/原始 JSON 点右边那个 > 进详情页。
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _expanded = !_expanded);
              },
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: visual.label,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: visual.color,
                                  ),
                                ),
                                if (event.toolName != null &&
                                    event.toolName!.isNotEmpty &&
                                    event.kind != AgentEventKind.workflowStep)
                                  TextSpan(
                                    text: '  ${event.toolName}',
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      fontFamily: kMonoFamily,
                                      fontFamilyFallback: kMonoFallback,
                                    ),
                                  ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if ((event.durationMs ?? 0) > 0)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Text(
                              _ms(event.durationMs!),
                              style: TextStyle(
                                fontSize: 10,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (event.turn > 0)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Text(
                              '#${event.turn}',
                              style: TextStyle(
                                fontSize: 10,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (event.kind == AgentEventKind.canvas &&
                            widget.onOpenCanvas != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: InkWell(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                final canvas = _canvasFromEvent();
                                if (canvas != null) {
                                  widget.onOpenCanvas!(canvas);
                                }
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  Icons.open_in_full_rounded,
                                  size: 15,
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                          ),
                        // 展开/收起的方向提示：用户一眼知道点行会发生什么。
                        Icon(
                          _expanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                        if (_hasDetail)
                          // 详情页入口单独一个可点区域：参数、返回、原始 JSON
                          // 都在里面，还能搜。
                          InkWell(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              ToolDetailSheet.show(context, event);
                            },
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: 4,
                              ),
                              child: Icon(
                                Icons.chevron_right_rounded,
                                size: 16,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (_workflowSteps != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: _WorkflowFlowCard(steps: _workflowSteps!),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: _expanded
                            ? Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.22),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: SelectableText(
                                  _full(event),
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    height: 1.5,
                                    fontFamily: kMonoFamily,
                                    fontFamilyFallback: kMonoFallback,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                            : Text(
                                _preview(event),
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.35,
                                  color: scheme.onSurfaceVariant,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                      ),
                    if (_imageBytes != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: RepaintBoundary(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 160),
                              child: Image.memory(
                                _imageBytes!,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                errorBuilder: (_, __, ___) => Text(
                                  '图片预览加载失败',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.error,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static int _workflowDepth(AgentEvent event) {
    if (event.kind != AgentEventKind.workflowStep) return 0;
    final d = event.args?['_depth'];
    if (d is num) return d.toInt().clamp(0, 9);
    return 0;
  }

  static String _workflowLine(AgentEvent event) {
    final depth = _workflowDepth(event);
    final indent = List.filled(depth, '  ').join();
    final msg = event.message.startsWith('条件执行 · ')
        ? event.message.substring('条件执行 · '.length)
        : event.message;
    final result = event.result?.trim() ?? '';
    if (result.isEmpty || result == event.message) return '$indent- $msg';
    final summary = result.replaceAll(RegExp(r'\s+'), ' ').trim();
    final clipped =
        summary.length > 160 ? '${summary.substring(0, 160)}…' : summary;
    return '$indent- $msg：$clipped';
  }

  static String _ms(int ms) =>
      ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)}s' : '${ms}ms';

  /// 展开后要显示的全文：保留换行/缩进，显示时自动换行。
  ///
  /// 工具调用展开后直接给「输入参数 + 输出/返回」两段；思考取 message。
  String _full(AgentEvent event) {
    final source = switch (event.kind) {
      AgentEventKind.thinking || AgentEventKind.answer => event.message,
      _ => () {
          final parts = <String>[];
          final args = event.args;
          if (args != null && args.isNotEmpty) {
            parts.add('输入参数：\n${_prettyJson(args)}');
          }
          final result = event.displayResult.trim();
          if (result.isNotEmpty) {
            parts.add('输出/返回：\n${_prettyIfJson(result)}');
          }
          if (parts.isNotEmpty) return parts.join('\n\n');
          if (event.message.trim().isNotEmpty) return event.message.trim();
          return '（这一步没有更多内容）';
        }(),
    };
    final text = source.trim();
    return text.isEmpty ? '（这一步没有更多内容）' : text;
  }

  /// JSON 里字符串值常带 \n \t 转义，直接显示就是一排“\n”特别难看。
  /// 这里只做**展示用**的还原：把转义换行/制表还原成真实换行/缩进，
  /// 绝不改原始参数。`\r` 直接去掉，避免 Windows 换行产生多余空行。
  static String _unescapeForDisplay(String text) => text
      .replaceAll('\\n', '\n')
      .replaceAll('\\t', '\t')
      .replaceAll('\\r', '');

  static String _prettyJson(Map<String, dynamic> args) {
    try {
      return _unescapeForDisplay(
        const JsonEncoder.withIndent('  ').convert(args),
      );
    } catch (_) {
      return _unescapeForDisplay(args.toString());
    }
  }

  static String _prettyIfJson(String text) {
    final trimmed = text.trim();
    if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) return text;
    try {
      return _unescapeForDisplay(
        const JsonEncoder.withIndent('  ').convert(jsonDecode(trimmed)),
      );
    } catch (_) {
      return _unescapeForDisplay(text);
    }
  }

  String _preview(AgentEvent event) {
    final source = switch (event.kind) {
      AgentEventKind.thinking || AgentEventKind.answer => event.message,
      _ => event.result?.trim().isNotEmpty == true
          ? event.result!.trim()
          : event.message,
    };
    return source.replaceAll(RegExp(r'\s+'), ' ');
  }

  _Visual _visualFor(AgentEvent event, ColorScheme scheme) {
    switch (event.kind) {
      case AgentEventKind.thinking:
        return _Visual(Icons.psychology_outlined, scheme.tertiary, '思考');
      case AgentEventKind.toolStart:
        return _Visual(Icons.play_arrow_rounded, scheme.primary, '调用');
      case AgentEventKind.toolImage:
        return _Visual(Icons.image_outlined, scheme.primary, '图片');
      case AgentEventKind.toolEnd:
        return event.ok
            ? _Visual(Icons.check_rounded, Colors.green.shade600, '完成')
            : _Visual(Icons.close_rounded, scheme.error, '失败');
      case AgentEventKind.planPending:
        return _Visual(Icons.pan_tool_outlined, Colors.orange.shade700, '待确认');
      case AgentEventKind.question:
        return _Visual(Icons.help_outline, Colors.orange.shade700, '提问');
      case AgentEventKind.taskPlan:
        return _Visual(Icons.checklist_rounded, scheme.primary, '清单');
      case AgentEventKind.answer:
        return _Visual(
            Icons.chat_bubble_outline_rounded, scheme.onSurface, '正文');
      case AgentEventKind.canvas:
        return _Visual(Icons.widgets_outlined, scheme.tertiary, '卡片');
      case AgentEventKind.workflowStep:
        return _Visual(
          Icons.account_tree_outlined,
          Colors.lightBlue.shade600,
          '流程',
        );
      case AgentEventKind.done:
        return _Visual(Icons.flag_rounded, scheme.primary, '收尾');
      case AgentEventKind.error:
        return _Visual(Icons.error_outline, scheme.error, '错误');
    }
  }
}

/// 子代理容器：同一个 `group` 的事件默认折叠成一个框。
///
/// 折叠态只给一行实时速览（思考/工具/正文的最近事件），
/// 展开后显示该子代理完整的时间线。多个子代理各自独立展开/收起。
class _SubagentGroup extends StatefulWidget {
  const _SubagentGroup({
    required this.events,
    required this.running,
    this.onOpenCanvas,
    this.liveReasoning = '',
    this.liveContent = '',
    this.liveTool = '',
    this.liveReasoningChars = 0,
    this.liveContentChars = 0,
  });

  final List<AgentEvent> events;
  final bool running;
  final void Function(AiCanvas canvas)? onOpenCanvas;
  final String liveReasoning;
  final String liveContent;
  final String liveTool;
  final int liveReasoningChars;
  final int liveContentChars;

  @override
  State<_SubagentGroup> createState() => _SubagentGroupState();
}

class _SubagentGroupState extends State<_SubagentGroup> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _SubagentGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldHasImage = oldWidget.events.any(
      (e) => e.kind == AgentEventKind.toolImage && e.imageDataUri != null,
    );
    final newHasImage = widget.events.any(
      (e) => e.kind == AgentEventKind.toolImage && e.imageDataUri != null,
    );
    // 子代理第一次显示图片时自动展开，让图立刻出现在流程里，
    // 而不是等整轮跑完/用户手动展开才看到。
    if (newHasImage && !oldHasImage && !_expanded) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = widget.events.first.group ?? '子代理';
    final last = widget.events.last;
    final done =
        last.kind == AgentEventKind.done || last.kind == AgentEventKind.error;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.account_tree_outlined,
                  size: 16,
                  color: scheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (widget.running && !done)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    done
                        ? Icons.check_circle_outline_rounded
                        : Icons.more_horiz_rounded,
                    size: 16,
                    color:
                        done ? Colors.green.shade600 : scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
          if (!_expanded && widget.events.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                _status(last, label),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < widget.events.length; i++)
                    _TimelineRow(
                      event: widget.events[i],
                      isLast: i == widget.events.length - 1,
                      onOpenCanvas: widget.onOpenCanvas,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 折叠态的实时速览：优先显示正在流的思考/工具，没有实时流才回退事件时间线。
  /// 子代理还在想问题时，不展开也能看到它在想什么；一旦开调工具立刻切到工具名。
  String _status(AgentEvent e, String label) {
    final rawThinking =
        widget.liveReasoning.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 折叠卡只有一行，不能直接贴几千字尾部：那样显示的是尾部段的开头，
    // 最新冒出来的字全被 ellipsis 截掉了。这里只取最后 120 字，
    // 保证一行里看到的一定是最新的思考尾巴。
    final liveThinking = rawThinking.length <= 120
        ? rawThinking
        : '…${rawThinking.substring(rawThinking.length - 120)}';
    final liveTool = widget.liveTool.trim();
    if (liveTool.isNotEmpty) {
      final thinkTail = liveThinking.isNotEmpty ? ' · $liveThinking' : '';
      return '调用 $liveTool$thinkTail';
    }
    if (liveThinking.isNotEmpty) {
      final chars = widget.liveReasoningChars > 0
          ? '（${widget.liveReasoningChars} 字） '
          : '';
      return '思考 $chars$liveThinking';
    }
    // 没有实时流时直接用最后一条事件：工具调用/完成/错误都能立刻显示，
    // 不会被更早的“思考事件”盖住。
    final target = e;
    final prefix = switch (target.kind) {
      AgentEventKind.thinking => '思考',
      AgentEventKind.answer => '正文',
      AgentEventKind.toolStart => '调用',
      AgentEventKind.toolEnd => '完成',
      AgentEventKind.error => '错误',
      AgentEventKind.done => '收尾',
      _ => '',
    };
    var msg = target.message.replaceAll(RegExp(r'\s+'), ' ').trim();
    final tag = '[$label] ';
    if (msg.startsWith(tag)) msg = msg.substring(tag.length).trim();
    if (target.toolName != null && target.toolName!.isNotEmpty) {
      return '${prefix.isEmpty ? '' : '$prefix '}${target.toolName} · $msg';
    }
    return prefix.isEmpty ? msg : '$prefix $msg';
  }
}

class _WorkflowFlowCard extends StatelessWidget {
  const _WorkflowFlowCard({required this.steps});

  final List<Map<String, dynamic>> steps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++)
            TweenAnimationBuilder<double>(
              key: ValueKey(
                'wf_${i}_${steps[i]['message']}_${steps[i]['result']}',
              ),
              tween: Tween(begin: 0.0, end: 1.0),
              duration: Duration(milliseconds: 160 + i * 45),
              curve: Curves.easeOutCubic,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, (1 - t) * 8),
                  child: child,
                ),
              ),
              child: _WorkflowStepNode(
                index: i,
                step: steps[i],
                isLast: i == steps.length - 1,
              ),
            ),
        ],
      ),
    );
  }
}

class _WorkflowStepNode extends StatelessWidget {
  const _WorkflowStepNode({
    required this.index,
    required this.step,
    required this.isLast,
  });

  final int index;
  final Map<String, dynamic> step;
  final bool isLast;

  void _openDetail(BuildContext context) {
    HapticFeedback.selectionClick();
    final rawArgs = step['args'];
    final args = rawArgs is Map
        ? rawArgs.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final message =
        (step['message'] as String? ?? '').replaceFirst('条件执行 · ', '');
    final result = (step['result'] as String? ?? '').trim();
    ToolDetailSheet.show(
      context,
      AgentEvent(
        kind: AgentEventKind.workflowStep,
        message: message,
        toolName: 'condition_exec',
        args: args,
        result: result,
        fullResult: result,
        ok: step['ok'] != false,
        durationMs: (step['durationMs'] as num?)?.toInt(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final depth = (step['depth'] as num?)?.toInt() ?? 0;
    final text = (step['message'] as String? ?? '').replaceFirst('条件执行 · ', '');
    final result = (step['result'] as String? ?? '').trim();
    final meta = _metaFor(text);
    final branch = text.contains('→ then')
        ? 'THEN'
        : text.contains('→ else')
            ? 'ELSE'
            : null;
    final resultLine = result.isEmpty || result == text
        ? ''
        : result.replaceAll(RegExp(r'\s+'), ' ').trim();
    final clipped = resultLine.length > 120
        ? '${resultLine.substring(0, 120)}…'
        : resultLine;

    return Padding(
      padding: EdgeInsets.only(
        left: depth * 16.0,
        bottom: isLast ? 0 : 8,
      ),
      child: InkWell(
        onTap: () => _openDetail(context),
        borderRadius: BorderRadius.circular(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 22,
              height: 22,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                color: meta.color.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(meta.icon, size: 13, color: meta.color),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          text,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      if (branch != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  (branch == 'THEN' ? Colors.green : Colors.red)
                                      .shade600
                                      .withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              branch,
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: branch == 'THEN'
                                    ? Colors.green.shade700
                                    : Colors.red.shade700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (clipped.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        clipped,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.25,
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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

  static _WorkflowMeta _metaFor(String text) {
    if (text.contains('分支')) {
      return const _WorkflowMeta(
        Icons.account_tree_outlined,
        Colors.orange,
      );
    }
    if (text.contains('循环')) {
      return const _WorkflowMeta(Icons.repeat_rounded, Colors.purple);
    }
    if (text.contains('延迟')) {
      return const _WorkflowMeta(Icons.hourglass_top_rounded, Colors.amber);
    }
    if (text.contains('捕获错误')) {
      return const _WorkflowMeta(Icons.error_outline_rounded, Colors.red);
    }
    if (text.contains('赋值')) {
      return const _WorkflowMeta(Icons.edit_note_rounded, Colors.blue);
    }
    return const _WorkflowMeta(Icons.play_arrow_rounded, Colors.teal);
  }
}

class _WorkflowMeta {
  const _WorkflowMeta(this.icon, this.color);

  final IconData icon;
  final Color color;
}

class _Visual {
  const _Visual(this.icon, this.color, this.label);

  final IconData icon;
  final Color color;
  final String label;
}
