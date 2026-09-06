import 'package:flutter/material.dart';

import '../../../core/theme/glass.dart';
import '../agent/agent_loop.dart';

/// AI 主动提问卡片：候选答案点一下即答，也可以自由输入。
///
/// 这是 ask_user 的界面落点。之前模型只能在正文里问一句然后自己收工，
/// 用户回答了也接不上；现在答案会作为新一轮输入送回，任务从挂起处继续。
class AiQuestionCard extends StatefulWidget {
  const AiQuestionCard({
    super.key,
    required this.question,
    required this.onAnswer,
  });

  final AgentQuestion question;

  /// 把答案当成新一轮用户输入发出去。
  final ValueChanged<String> onAnswer;

  @override
  State<AiQuestionCard> createState() => _AiQuestionCardState();
}

class _AiQuestionCardState extends State<AiQuestionCard> {
  final _controller = TextEditingController();
  bool _sent = false;

  /// 自定义回答输入区是否展开。
  ///
  /// 有候选项时默认收起（点按钮最快），但必须能展开——AI 给的选项经常都不合意，
  /// 这时得能自己写，而不是被它的三个选项框死。
  bool _custom = false;

  @override
  void didUpdateWidget(AiQuestionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了一个问题就必须解锁。
    //
    // 宿主给不给 key 都不该出这个 bug：Flutter 复用 State 时只换 widget，
    // `_sent` 会带着上一个问题的"已回答"状态过来，于是新问题的按钮全是灰的
    // ——用户看到的现象就是"第三次提问没反应/没出现"。
    if (oldWidget.question.id != widget.question.id) {
      _controller.clear();
      _sent = false;
      _custom = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _answer(String text) {
    final value = text.trim();
    if (value.isEmpty || _sent) return;
    // 防连点：同一个问题只答一次，否则会并发起两轮 Agent。
    setState(() => _sent = true);
    widget.onAnswer(value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = widget.question;
    return GlassPanel(
      radius: 20,
      blur: Glass.blurStrong,
      shadowY: 6,
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                'AI 需要你确认一件事',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            q.question,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
          ),
          // 答完之后必须留下痕迹。按钮全灰、其他什么都不变的话，
          // 用户分不清"已经发出去了"还是"点了没反应"。
          if (_sent)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '答案已送回，AI 正在接着做…',
                    style: TextStyle(fontSize: 12, color: scheme.primary),
                  ),
                ],
              ),
            ),
          if (q.context.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                q.context,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          if (q.options.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in q.options)
                  FilledButton.tonal(
                    onPressed: _sent ? null : () => _answer(option),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                    child: Text(option),
                  ),
              ],
            ),
          ],
          // 没有候选项时直接展开输入区；有候选项时给一个"自定义回答"入口。
          if (q.options.isEmpty || _custom) ...[
            const SizedBox(height: 8),
            GlassPanel(
              radius: 14,
              blur: 12,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_sent,
                      autofocus: _custom,
                      minLines: 1,
                      maxLines: 4,
                      style: const TextStyle(fontSize: 14),
                      decoration: const InputDecoration(
                        isDense: true,
                        filled: false,
                        hintText: '写下你的答案，可以补充任何要求…',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                      onSubmitted: _answer,
                    ),
                  ),
                  IconButton(
                    tooltip: '回答',
                    visualDensity: VisualDensity.compact,
                    onPressed: _sent ? null : () => _answer(_controller.text),
                    icon: const Icon(Icons.send, size: 19),
                  ),
                ],
              ),
            ),
          ] else
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _sent ? null : () => setState(() => _custom = true),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('都不合适，自己写', style: TextStyle(fontSize: 12.5)),
              ),
            ),
        ],
      ),
    );
  }
}
