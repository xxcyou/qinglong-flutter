import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/glass.dart';

import '../../../core/utils/formatter.dart';
import '../models/agent_event.dart';
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
  });

  final List<AgentEvent> events;
  final bool running;
  final int turns;
  final int totalTokens;
  final bool initiallyExpanded;

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
    return [
      for (final e in events)
        if (!(e.kind == AgentEventKind.toolStart &&
            settled.contains('${e.turn}|${e.toolName ?? ''}')))
          e,
    ];
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
                        Text(
                          widget.running ? '正在执行' : '执行过程',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < events.length; i++)
                    _TimelineRow(
                      event: events[i],
                      isLast: i == events.length - 1,
                    ),
                ],
              ),
            ),
        ],
      ),
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
  const _TimelineRow({required this.event, required this.isLast});

  final AgentEvent event;
  final bool isLast;

  @override
  State<_TimelineRow> createState() => _TimelineRowState();
}

class _TimelineRowState extends State<_TimelineRow> {
  /// 这一行是否就地展开成全文。
  ///
  /// 思考/正文经常有好几百字，两行预览根本看不出它在说什么，而每次都要
  /// 弹详情页太重。点一下就地铺开、再点收起，是最省事的看法。
  bool _expanded = false;

  AgentEvent get event => widget.event;

  bool get isLast => widget.isLast;

  /// 每一行都点得进去。
  ///
  /// 以前只有"带参数或带返回"的行可点，思考/清单/收尾这些行没有点击反馈，
  /// 用户以为它们坏了。详情页现在对任何事件都有东西可显示（至少是说明），
  /// 所以不再拦。
  bool get _hasDetail => true;

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
                                  event.toolName!.isNotEmpty)
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
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    // 展开时用等宽字体 + 自动换行，参数/返回看起来是排版好的
                    // JSON；同时可选中复制。收起时还是两行预览，时间线紧凑。
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
                  if (event.imageDataUri != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 160),
                          child: Image.memory(
                            base64Decode(
                              event.imageDataUri!.split(',').last,
                            ),
                            fit: BoxFit.contain,
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
                ],
              ),
            ),
          ),
        ),
      ],
    );
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
      case AgentEventKind.done:
        return _Visual(Icons.flag_rounded, scheme.primary, '收尾');
      case AgentEventKind.error:
        return _Visual(Icons.error_outline, scheme.error, '错误');
    }
  }
}

class _Visual {
  const _Visual(this.icon, this.color, this.label);

  final IconData icon;
  final Color color;
  final String label;
}
