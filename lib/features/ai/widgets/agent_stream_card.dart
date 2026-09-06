import 'package:flutter/material.dart';

import '../../../core/theme/glass.dart';

/// 正在发生的那一轮：思考冒多少显示多少。
///
/// 和 [AgentProcessCard] 的分工——过程卡画的是"已经发生的步骤"（一步一行、
/// 可点开看详情），这张卡画的是"此刻正在流出来的字"。两张卡同时在场时，
/// 上面是已完成的时间线，下面是正在动的这一段，读起来就是一条时间轴。
///
/// 这张卡故意不解析 Markdown：流式文本每 80ms 变一次，且随时处于
/// "``` 只开了一半""**加粗没闭合"的中间态，用 Markdown 渲染会不停闪、
/// 还会把半截语法当正文吐出来。正文最终会由消息气泡以 Markdown 正式渲染。
class AgentStreamCard extends StatefulWidget {
  const AgentStreamCard({
    super.key,
    required this.reasoning,
    required this.content,
    required this.tool,
    this.reasoningChars,
    this.contentChars,
    this.dense = false,
  });

  /// 正在流的思考（reasoning_content）。
  final String reasoning;

  /// 正在流的正文。
  final String content;

  /// 这一轮刚报出来的工具名（参数还没收完）。
  final String tool;

  /// 真实字数。[reasoning] / [content] 只是尾部片段（上游只留最后 6000 字），
  /// 拿它们的 length 显示会永远停在 6001，看着像模型卡住了。
  final int? reasoningChars;
  final int? contentChars;

  /// 悬浮窗里用的紧凑排版。
  final bool dense;

  /// 清掉"用户拉过的窗口高度"。
  ///
  /// 那份记忆是静态的（跨轮次保留，见 [_StreamTextState._userHeights]），
  /// 测试之间会互相串味，所以给测试一个复位入口。
  @visibleForTesting
  static void resetStreamHeights() => _StreamTextState._userHeights.clear();

  @override
  State<AgentStreamCard> createState() => _AgentStreamCardState();
}

class _AgentStreamCardState extends State<AgentStreamCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reasoning = widget.reasoning;
    final content = widget.content;
    final accent = content.isNotEmpty ? scheme.primary : scheme.tertiary;
    final dense = widget.dense;
    // 思考区比正文区矮一点：正文是结论，值得多给几行。
    final thinkHeight = dense ? 96.0 : 132.0;
    final talkHeight = dense ? 84.0 : 116.0;

    return InfoCardShell(
      accent: accent,
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: EdgeInsets.fromLTRB(dense ? 10 : 12, 9, 8, 9),
              child: Row(
                children: [
                  InfoCardBadge(
                    color: accent,
                    child: SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _title(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
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
          if (_expanded && reasoning.isNotEmpty)
            _StreamText(
              text: reasoning,
              maxHeight: thinkHeight,
              color: scheme.onSurfaceVariant,
              fontSize: dense ? 11 : 11.5,
              dense: dense,
              slot: 'think',
            ),
          if (_expanded && content.isNotEmpty)
            _StreamText(
              text: content,
              maxHeight: talkHeight,
              color: scheme.onSurface,
              fontSize: dense ? 11.5 : 12.5,
              dense: dense,
              slot: 'talk',
              // 思考在上、正文在下时给一条分隔：不然两段字糊成一团，
              // 分不清哪句是"想"的、哪句是"说"的。
              divided: reasoning.isNotEmpty,
            ),
          SizedBox(height: _expanded ? 8 : 2),
        ],
      ),
    );
  }

  String _title() {
    if (widget.tool.isNotEmpty) return '准备调用 ${widget.tool}';
    if (widget.content.isNotEmpty) return '正在回答';
    if (widget.reasoning.isNotEmpty) return '正在思考';
    return '正在连接模型…';
  }

  String _subtitle() {
    final parts = <String>[];
    if (widget.reasoning.isNotEmpty) {
      parts.add('思考 ${widget.reasoningChars ?? widget.reasoning.length} 字');
    }
    if (widget.content.isNotEmpty) {
      parts.add('正文 ${widget.contentChars ?? widget.content.length} 字');
    }
    if (parts.isEmpty) return '已发出请求，等它开口';
    return '${parts.join(' · ')}｜点这里收起，底边小把手可拉高';
  }
}

/// 一段还在长的文字（思考 / 正文）。
///
/// 三件事是用户点名要的：
/// 1. **能拉长拉短**——底下那条小把手竖着拖就是改高度，想多看几行就拉长；
/// 2. **往上翻就停住**——手指把内容往上拉，自动跟随立刻断开，位置钉住不动，
///    方便回看前面的思考；
/// 3. **拖回底部自动继续跟**——回到最后一行附近，跟随自动恢复。
///
/// 早先的实现是 `reverse: true` + 无 controller："永远贴着最新一行"确实白送，
/// 但代价是**没法停**：正文从底部长出来，滚动原点也在底部，用户往上翻到一半，
/// 新字一来读的那几行就往上飘，跟被人推着走一样。所以这里改成正向滚动 +
/// 自己管跟随标记：跟随时每次收到新字才跳到底，不跟随时一动不动。
class _StreamText extends StatefulWidget {
  const _StreamText({
    required this.text,
    required this.maxHeight,
    required this.color,
    required this.fontSize,
    required this.dense,
    required this.slot,
    this.divided = false,
  });

  final String text;

  /// 默认高度。用户拉过之后以他拉的为准（见 [_StreamTextState._userHeights]）。
  final double maxHeight;
  final Color color;
  final double fontSize;
  final bool dense;

  /// 记高度用的槽位：思考和正文各记一份，互不干扰。
  final String slot;
  final bool divided;

  @override
  State<_StreamText> createState() => _StreamTextState();
}

class _StreamTextState extends State<_StreamText> {
  /// 用户拉过的高度，**跨轮次记住**。
  ///
  /// 每一轮流式回复都是一张新的 [AgentStreamCard]（State 跟着重建），
  /// 存在实例里下一轮就丢了：用户刚把思考框拉高，下一轮又缩回去。
  /// 所以放静态表里，按槽位 + 紧凑与否分别记。
  static final Map<String, double> _userHeights = <String, double>{};

  final ScrollController _controller = ScrollController();

  /// true = 跟着最新的字走；false = 用户往上翻了，别抢他的滚动位置。
  bool _stick = true;

  late double _height = _userHeights[_key] ?? widget.maxHeight;

  String get _key => '${widget.slot}${widget.dense ? '-dense' : ''}';

  /// 高度上下限。紧凑模式在悬浮窗里，给太高会把输入框顶出屏幕。
  double get _minHeight => 56;
  double get _maxHeight => widget.dense ? 260 : 520;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    // 第一帧就可能已经超一屏（历史片段直接塞进来），先贴到底。
    _follow();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _StreamText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _follow();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    // 离底 24 像素以内都算"在看最新的"：松手后惯性停在 20 像素处
    // 不该被判成"用户要回看"，否则跟随会莫名断掉。
    final atBottom = p.maxScrollExtent - p.pixels <= 24;
    if (atBottom != _stick) setState(() => _stick = atBottom);
  }

  void _follow() {
    if (!_stick) return;
    // 新字得等这一帧排完版才知道有多长，所以跳转放到帧后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_stick || !_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      if ((_controller.position.pixels - max).abs() > 0.5) {
        _controller.jumpTo(max);
      }
    });
  }

  void _backToLatest() {
    if (!_controller.hasClients) return;
    setState(() => _stick = true);
    _controller.jumpTo(_controller.position.maxScrollExtent);
  }

  void _resize(double dy) {
    final next = (_height + dy).clamp(_minHeight, _maxHeight);
    if (next == _height) return;
    setState(() {
      _height = next;
      _userHeights[_key] = next;
    });
    // 拉长的时候如果本来在跟随，补一次跳转：不然新露出来的是上面的旧文字，
    // 最新那行反而被顶到看不见的地方。
    _follow();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pad = widget.dense ? 10.0 : 12.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 0, pad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.divided)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Divider(
                height: 1,
                thickness: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
          Stack(
            children: [
              SizedBox(
                height: _height,
                width: double.infinity,
                child: Scrollbar(
                  controller: _controller,
                  thumbVisibility: false,
                  child: SingleChildScrollView(
                    // key 是给测试用的：这块区域的高度和滚动位置就是
                    // "拉长拉短"和"往上翻停止跟随"两条行为的观测点。
                    key: ValueKey('stream-scroll-${widget.slot}'),
                    controller: _controller,
                    // 到底了还想往下拉时不要弹：这块区域嵌在聊天列表里，
                    // 回弹会被误当成"列表在动"。
                    physics: const ClampingScrollPhysics(),
                    child: Text(
                      widget.text,
                      style: TextStyle(
                        fontSize: widget.fontSize,
                        height: 1.42,
                        color: widget.color,
                      ),
                    ),
                  ),
                ),
              ),
              // 停止跟随时给个明确的回程入口，否则用户翻上去之后
              // 得自己一路划回底部才能恢复跟随。
              if (!_stick)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: _FollowChip(onTap: _backToLatest),
                ),
            ],
          ),
          _ResizeHandle(
            key: ValueKey('stream-handle-${widget.slot}'),
            onDrag: _resize,
            dense: widget.dense,
          ),
        ],
      ),
    );
  }
}

/// "已暂停跟随 · 回到最新"。
class _FollowChip extends StatelessWidget {
  const _FollowChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.86),
      shape: StadiumBorder(
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            children: [
              Icon(Icons.vertical_align_bottom_rounded,
                  size: 13, color: scheme.primary),
              const SizedBox(width: 4),
              Text(
                '回到最新',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 拉长拉短用的把手。
///
/// 竖直拖动手势放在这条窄条上，而不是整块文字上：文字区自己要能滚，
/// 两个竖向手势叠在一起会互相抢（内层赢，结果是文字划不动）。
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    super.key,
    required this.onDrag,
    required this.dense,
  });

  final ValueChanged<double> onDrag;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
      child: SizedBox(
        height: dense ? 14 : 16,
        width: double.infinity,
        child: Center(
          child: Container(
            width: 44,
            height: 3,
            decoration: BoxDecoration(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}
