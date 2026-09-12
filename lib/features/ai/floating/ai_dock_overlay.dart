import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/llm_registry_provider.dart';
import '../../../core/theme/glass.dart';
import '../../../router.dart';
import '../../../shared/editor_bus.dart';
import '../../../shared/float_stack.dart';
import '../../../shared/local_file_picker.dart';
import '../../home/home_navigation_provider.dart';
import '../models/agent_event.dart';
import '../models/ai_message.dart';
import '../models/approval_mode.dart';
import '../widgets/ai_composer.dart';
import '../widgets/ai_control_sheets.dart';
import '../widgets/agent_stream_card.dart';
import '../widgets/ai_session_list.dart';
import '../models/agent_task_plan.dart';
import '../models/canvas_window.dart';
import '../models/quick_ask.dart';
import '../widgets/ai_canvas_sheet.dart';
import '../widgets/ai_question_card.dart';
import '../widgets/queue_strip.dart';
import '../../browser/browser_engine.dart';
import '../agent/agent_loop.dart';
import '../providers/chat_provider.dart';
import '../widgets/agent_process_card.dart';
import '../widgets/markdown_message.dart';
import '../widgets/pending_image_bar.dart';
import '../../../shared/image_preview_overlay.dart';
import 'ai_dock_provider.dart';

/// 悬浮 AI 的宿主。
///
/// 悬浮层挂在 `MaterialApp.builder` 里（这样 push 出去的页面也盖得住），
/// 但那个位置在路由 Navigator 之外，没有 [Overlay] 祖先——Tooltip、
/// 文本选择手柄、下拉菜单都要求 Overlay，缺了就直接渲染成红色报错块。
/// 所以这里自带一个 Overlay，并补上 Directionality 与 Material 语境。
class AiDockHost extends StatelessWidget {
  const AiDockHost({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            opaque: false,
            maintainState: true,
            builder: (_) => const AiDockOverlay(),
          ),
        ],
      ),
    );
  }
}

/// 全局悬浮 AI：一个可拖动的液体玻璃气泡，展开即完整对话面板。
///
/// 与 AI 页共用同一个 [chatProvider]，所以工具能力、确认策略、会话历史
/// 完全一致——在悬浮窗里也能装依赖、读日志、改环境变量。
class AiDockOverlay extends ConsumerStatefulWidget {
  const AiDockOverlay({super.key});

  @override
  ConsumerState<AiDockOverlay> createState() => _AiDockOverlayState();
}

class _AiDockOverlayState extends ConsumerState<AiDockOverlay> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// 是否跟着最新内容走。用户往上翻看历史时自动停，回到底部自动恢复。
  bool _pinned = true;

  @override
  void initState() {
    super.initState();
    _input.text = ref.read(aiDockProvider).draft;
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = pos.maxScrollExtent - pos.pixels <= 120;
    if (atBottom != _pinned) _pinned = atBottom;
  }

  /// 有新内容就跟到底。窗口本来就小，不自动跟的话回复一长就全在视野外。
  void _followTail() {
    if (!_pinned) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if ((max - _scroll.position.pixels).abs() < 1) return;
      _scroll.jumpTo(max);
    });
  }

  void _send() {
    final dock = ref.read(aiDockProvider);
    final notifier = ref.read(aiDockProvider.notifier);
    final prompt = notifier.composePrompt(_input.text);
    if (prompt.trim().isEmpty) return;
    _input.clear();
    notifier.setDraft('');
    notifier.consumeChips();
    _pinned = true;
    ref.read(chatProvider.notifier).send(prompt);
    if (!dock.expanded) notifier.open();
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 消息、流式正文、工具时间线、提问、待确认——任一变化都跟到底。
    ref.listen<ChatState>(chatProvider, (previous, next) {
      if (previous == null) return;
      final changed = previous.messages.length != next.messages.length ||
          previous.liveAgentEvents.length != next.liveAgentEvents.length ||
          previous.messages.lastOrNull?.content.length !=
              next.messages.lastOrNull?.content.length ||
          previous.pendingPlan.length != next.pendingPlan.length ||
          // 尾部片段封顶后长度不再变，得比真实字数才知道还在长。
          previous.liveReasoningChars != next.liveReasoningChars ||
          previous.liveContentChars != next.liveContentChars;
      if (changed) _followTail();
    });
    final dock = ref.watch(aiDockProvider);
    // 气泡不在这一层：它由 [AiBubbleHost] 画在所有悬浮窗之上（永远点得到）。
    // 这一层只有展开后的聊天窗/提问窗/画布窗，它们要和浏览器窗抢层级。
    if (!dock.visible || !dock.expanded) return const SizedBox.shrink();
    // 只有窗口自己接触摸，其余区域必须放行给下面的页面。
    return Material(
      type: MaterialType.transparency,
      // 碰到聊天窗/气泡就把 AI 这一层抬到最上面（deferToChild：
      // 空白区域不算触摸，照旧穿透）。这样浏览器和聊天窗谁在上面由用户说了算。
      child: Listener(
        onPointerDown: (_) => FloatStack.instance.raise(FloatStack.ai),
        child: Stack(
          clipBehavior: Clip.none,
          children: _layers(context, dock),
        ),
      ),
    );
  }

  /// 悬浮层的所有窗口。顺序即层级：聊天窗在下，提问/画布窗在上。
  List<Widget> _layers(BuildContext context, AiDockState dock) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final safeTop = media.padding.top;
    final safeBottom = media.padding.bottom;
    final field = Size(
      size.width - 56,
      size.height - safeTop - safeBottom - 12,
    );
    final chat = ref.watch(chatProvider);
    final question = chat.pendingQuestion;
    final chatRect = dock.expanded
        ? _chatGeometry(context).rect
        : Rect.fromLTWH(0, size.height, 0, 0);
    return [
      _build(context, dock),
      // 提问与画布只在悬浮模式下浮出来：在 AI 页操作时还是原来的样子
      // （页内卡片 / 底部弹窗），不然同一件事会出现两份界面。
      if (dock.expanded && question != null)
        // 避让聊天窗：聊天窗偏下就贴顶，偏上就贴底。
        // 两个窗口叠在一起时用户根本分不清哪个是要答的。
        Positioned(
          key: ValueKey('qw${question.id}'),
          left: 14,
          top: chatRect.center.dy > size.height / 2 ? safeTop + 16 : null,
          bottom: chatRect.center.dy > size.height / 2
              ? null
              : safeBottom + 16 + media.viewInsets.bottom,
          width: size.width - 28,
          child: _QuestionWindow(
            question: question,
            onAnswer: (answer) {
              _pinned = true;
              ref.read(chatProvider.notifier).send(answer);
            },
          ),
        ),
      // 画布窗口：不限个数，顺序即层级（点哪个哪个抬到最上）。
      if (dock.expanded)
        for (final win in dock.canvasWindows)
          _canvasWindow(context, win, field, size, safeTop, safeBottom),
    ];
  }

  Widget _canvasWindow(
    BuildContext context,
    CanvasWindow win,
    Size field,
    Size size,
    double safeTop,
    double safeBottom,
  ) {
    final notifier = ref.read(aiDockProvider.notifier);
    final w = (win.w * field.width)
        .clamp(CanvasWindow.minW * field.width, field.width);
    final h = (win.h * field.height)
        .clamp(CanvasWindow.minH * field.height, field.height);
    final left = (28 + win.x * field.width).clamp(8.0, size.width - w - 8);
    final top = (safeTop + 6 + win.y * field.height)
        .clamp(safeTop + 4, size.height - safeBottom - h - 4);
    return Positioned(
      // key 用窗口名：多窗口增删时不会把某个 WebView 的 State 串到另一个窗口上
      // （串了的表现就是"两个窗口显示同一个页面"）。
      key: ValueKey('canvas:${win.name}'),
      left: left,
      top: top,
      width: w,
      height: h,
      child: Listener(
        onPointerDown: (_) => notifier.raiseCanvas(win.name),
        child: _CanvasWindow(
          canvas: win.canvas,
          chromeless: win.chromeless,
          field: field,
          onMove: (dx, dy) => notifier.moveCanvasBy(win.name, dx, dy),
          onResize: ({
            double dLeft = 0,
            double dTop = 0,
            double dRight = 0,
            double dBottom = 0,
          }) =>
              notifier.resizeCanvas(
            win.name,
            dLeft: dLeft,
            dTop: dTop,
            dRight: dRight,
            dBottom: dBottom,
          ),
          onCommit: notifier.commitLayout,
          onClose: () => notifier.closeCanvas(win.name),
        ),
      ),
    );
  }

  /// 聊天窗与它所在的可用区域。提问窗要靠它避让，所以必须算在一处，
  /// 两边各算一遍迟早会不一致。
  ({Rect rect, Size field}) _chatGeometry(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final safeTop = media.padding.top;
    final safeBottom = media.padding.bottom;
    final dock = ref.read(aiDockProvider);
    // 左右留 28 逻辑像素：系统返回手势占据屏幕两侧约 24dp，
    // 窗口边缘落进去的话，用户想拉边框会被识别成"返回"，边框就捏不动。
    final safeArea = EdgeInsets.only(
      left: 28,
      right: 28,
      top: safeTop + 6,
      bottom: safeBottom + 6,
    );
    final field = Size(
      size.width - safeArea.horizontal,
      size.height - safeArea.vertical,
    );
    final w = (dock.ww * field.width)
        .clamp(AiDockState.minW * field.width, field.width);
    final h = (dock.wh * field.height)
        .clamp(AiDockState.minH * field.height, field.height);
    var left = safeArea.left + dock.wx * field.width;
    var top = safeArea.top + dock.wy * field.height;
    // 键盘弹起时整窗上移，保证输入框可见（不缩小窗口，避免布局跳动）。
    final keyboard = media.viewInsets.bottom;
    if (keyboard > 0) {
      final limit = size.height - keyboard - 8 - h;
      if (top > limit) top = limit;
      if (top < safeArea.top) top = safeArea.top;
    }
    left = left.clamp(safeArea.left, size.width - safeArea.right - w);
    top = top.clamp(safeArea.top, size.height - safeArea.bottom - h);
    return (rect: Rect.fromLTWH(left, top, w, h), field: field);
  }

  Widget _build(BuildContext context, AiDockState dock) {
    // 半屏浮动窗：可拖动、可按边缩放，下层页面依然能滚能点。
    final geo = _chatGeometry(context);
    return Positioned(
      left: geo.rect.left,
      top: geo.rect.top,
      width: geo.rect.width,
      height: geo.rect.height,
      child: _Window(
        input: _input,
        scroll: _scroll,
        onSend: _send,
        onToBottom: _toBottom,
        field: geo.field,
      ),
    );
  }
}

/// 悬浮球的宿主：**永远画在所有悬浮窗之上**。
///
/// 为什么单独一层：聊天窗和浏览器窗会互相抢层级，浏览器一最大化就把整块屏幕
/// 盖住。如果气泡跟着聊天窗一起沉到浏览器下面，用户就再没有任何入口把 AI 叫
/// 回来（点哪儿都是网页，点一次网页浏览器还会再置前一次）——只能去收浏览器。
/// 气泡是唯一的"任务栏"，必须最高层。
class AiBubbleHost extends StatelessWidget {
  const AiBubbleHost({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            opaque: false,
            maintainState: true,
            builder: (_) => const AiBubbleLayer(),
          ),
        ],
      ),
    );
  }
}

/// 悬浮球本体（拖动、吸边、长按快问、未读角标、快问结果窗都在这里）。
class AiBubbleLayer extends ConsumerStatefulWidget {
  const AiBubbleLayer({super.key});

  @override
  ConsumerState<AiBubbleLayer> createState() => _AiBubbleLayerState();
}

class _AiBubbleLayerState extends ConsumerState<AiBubbleLayer> {
  /// 本次触摸在气泡上累计移动的距离：用来区分"拖动"与"长按"。
  double _bubbleMoved = 0;

  /// 快问输入框。
  final _quick = TextEditingController();
  final _quickFocus = FocusNode();

  /// 当前这轮快问的唯一标识，用来把流式正文归到同一个悬浮窗。
  String _liveQuickRunId = '';

  /// 当前这轮快问已经弹出的正文窗 id。
  String _liveQuickWindowId = '';

  /// 当前这轮快问的问题回显（正文窗顶部显示用）。
  String _liveQuickQuestion = '';

  /// 正文窗刷新节流：Markdown 不能跟着每个 token 全量重渲。
  DateTime? _lastLiveWindowUpdate;

  @override
  void initState() {
    super.initState();
    _quick.text = ref.read(aiDockProvider).quickDraft;
  }

  @override
  void dispose() {
    _quick.dispose();
    _quickFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dock = ref.watch(aiDockProvider);
    // 快问模式和完整的悬浮聊天窗共用一个 ChatNotifier，问题状态也要在这里读，
    // 否则模型一问问题就只能靠"展开完整悬浮窗"才能看到。
    final chatState = ref.watch(chatProvider);
    // 正文一开始吐出来就弹悬浮窗：边跑边更新，不用等收尾。
    ref.listen<ChatState>(chatProvider, (previous, next) {
      if (previous == null) return;
      _syncQuickLive(previous, next);
    });
    // 球藏了但结果窗还开着：结果窗要留下。它是用户主动问出来的东西，
    // 顺手关个球就把答案一起弄没了才叫难受。
    if (!dock.visible && dock.quickResults.isEmpty) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: FloatStack.instance,
      builder: (context, _) {
        // 展开且在最上面时不画气泡（窗口本身就是入口，再画一个多余）。
        // 但"展开却被浏览器压住"时必须画出来——那是唤回聊天窗的唯一入口。
        final hideBall = !dock.visible ||
            (dock.expanded && FloatStack.instance.isTop(FloatStack.ai));
        return Material(
          type: MaterialType.transparency,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (!hideBall) ..._build(context, dock),
              // 结果窗画在球下面（球永远点得到），但在别的悬浮窗之上。
              ..._quickResultWindows(context, dock),
              // 快问模式下，模型抛出的问题直接浮在屏幕上方回答，不展开完整窗。
              if (dock.quickOpen && chatState.pendingQuestion != null)
                _quickQuestionWindow(
                  context,
                  dock,
                  chatState.pendingQuestion!,
                ),
              // 快问模式下的 ui_c 画布窗：多个一起浮，不切去完整悬浮窗。
              if (dock.quickOpen) ..._quickCanvasWindows(context, dock),
            ],
          ),
        );
      },
    );
  }

  /// 快问结果窗：无边、可拖、可关、可按边缩放。
  List<Widget> _quickResultWindows(BuildContext context, AiDockState dock) {
    if (dock.quickResults.isEmpty) return const [];
    final media = MediaQuery.of(context);
    final size = media.size;
    final safeTop = media.padding.top;
    final safeBottom = media.padding.bottom;
    final field = Size(
      size.width - 24,
      size.height - safeTop - safeBottom - 12,
    );
    final notifier = ref.read(aiDockProvider.notifier);
    return [
      for (final win in dock.quickResults)
        () {
          final w = (win.w * field.width)
              .clamp(QuickResultWindow.minW * field.width, field.width);
          final h = (win.h * field.height)
              .clamp(QuickResultWindow.minH * field.height, field.height);
          final left =
              (12 + win.x * field.width).clamp(6.0, size.width - w - 6);
          final top = (safeTop + 6 + win.y * field.height)
              .clamp(safeTop + 4, size.height - safeBottom - h - 4);
          return Positioned(
            key: ValueKey('quick:${win.id}'),
            left: left,
            top: top,
            width: w,
            height: h,
            child: Listener(
              onPointerDown: (_) {
                FloatStack.instance.raise(FloatStack.ai);
                notifier.raiseQuickResult(win.id);
              },
              child: _QuickResultCard(
                win: win,
                field: field,
                onMove: (dx, dy) => notifier.moveQuickResultBy(win.id, dx, dy),
                onResize: ({
                  double dLeft = 0,
                  double dTop = 0,
                  double dRight = 0,
                  double dBottom = 0,
                }) =>
                    notifier.resizeQuickResult(
                  win.id,
                  dLeft: dLeft,
                  dTop: dTop,
                  dRight: dRight,
                  dBottom: dBottom,
                ),
                onClose: () => notifier.closeQuickResult(win.id),
              ),
            ),
          );
        }(),
    ];
  }

  /// 快问模式下的画布浮动窗：跟完整悬浮窗一样支持多个 ui_c，
  /// 但不展开完整 AI 窗，也不走 AI 页里的画布卡片。
  List<Widget> _quickCanvasWindows(
    BuildContext context,
    AiDockState dock,
  ) {
    if (dock.canvasWindows.isEmpty) return const [];
    final media = MediaQuery.of(context);
    final size = media.size;
    final safeTop = media.padding.top;
    final safeBottom = media.padding.bottom;
    final field = Size(
      size.width - 56,
      size.height - safeTop - safeBottom - 12,
    );
    final notifier = ref.read(aiDockProvider.notifier);
    return [
      for (final win in dock.canvasWindows)
        () {
          final w = (win.w * field.width)
              .clamp(CanvasWindow.minW * field.width, field.width);
          final h = (win.h * field.height)
              .clamp(CanvasWindow.minH * field.height, field.height);
          final left =
              (28 + win.x * field.width).clamp(8.0, size.width - w - 8);
          final top = (safeTop + 6 + win.y * field.height).clamp(
            safeTop + 4,
            size.height - safeBottom - h - 4,
          );
          return Positioned(
            key: ValueKey('quickCanvas:${win.name}'),
            left: left,
            top: top,
            width: w,
            height: h,
            child: Listener(
              onPointerDown: (_) => notifier.raiseCanvas(win.name),
              child: _CanvasWindow(
                canvas: win.canvas,
                chromeless: win.chromeless,
                field: field,
                onMove: (dx, dy) => notifier.moveCanvasBy(win.name, dx, dy),
                onResize: ({
                  double dLeft = 0,
                  double dTop = 0,
                  double dRight = 0,
                  double dBottom = 0,
                }) =>
                    notifier.resizeCanvas(
                  win.name,
                  dLeft: dLeft,
                  dTop: dTop,
                  dRight: dRight,
                  dBottom: dBottom,
                ),
                onCommit: notifier.commitLayout,
                onClose: () => notifier.closeCanvas(win.name),
              ),
            ),
          );
        }(),
    ];
  }

  /// 监听流式正文：只要有正文就弹/更新当前这轮快问的正文悬浮窗。
  ///
  /// 一轮只弹一个窗（跨轮不限量），更新做 150ms 节流，避免 Markdown
  /// 跟着每个 token 全量重渲。
  void _syncQuickLive(ChatState previous, ChatState next) {
    final dock = ref.read(aiDockProvider);
    if (!dock.quickOpen || !dock.quickBusy) return;
    if (_liveQuickRunId.isEmpty) return;
    if (!next.isLoading) return;
    // 用全文，不是 tail 6000：正文窗要能从开头看到结尾。
    final content = next.liveContentFull.trim();
    if (content.isEmpty || content == previous.liveContentFull.trim()) return;

    final notifier = ref.read(aiDockProvider.notifier);
    final now = DateTime.now();
    if (_liveQuickWindowId.isEmpty) {
      _liveQuickWindowId = notifier.pushQuickResult(
        question: _liveQuickQuestion,
        answer: content,
      );
      _lastLiveWindowUpdate = now;
      return;
    }
    if (!notifier.hasQuickResult(_liveQuickWindowId)) {
      // 用户手动 X 掉了实时窗：尊重他的选择，不偷偷再弹一个回来。
      return;
    }
    if (_lastLiveWindowUpdate != null &&
        now.difference(_lastLiveWindowUpdate!) <
            const Duration(milliseconds: 150)) {
      return;
    }
    _lastLiveWindowUpdate = now;
    notifier.updateQuickResult(_liveQuickWindowId, answer: content);
  }

  /// 开一轮快问前重置实时窗状态。
  void _beginQuickRun(String question) {
    _liveQuickRunId = '${DateTime.now().microsecondsSinceEpoch}';
    _liveQuickWindowId = '';
    _liveQuickQuestion = question;
    _lastLiveWindowUpdate = null;
  }

  /// 一轮快问收尾后清掉实时窗状态。
  void _endQuickRun() {
    _liveQuickRunId = '';
    _liveQuickWindowId = '';
    _liveQuickQuestion = '';
    _lastLiveWindowUpdate = null;
  }

  /// 快问模式下的提问窗：模型抛问题时浮在屏幕上方回答，不展开完整悬浮窗。
  Widget _quickQuestionWindow(
    BuildContext context,
    AiDockState dock,
    AgentQuestion question,
  ) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final safeTop = media.padding.top;
    return Positioned(
      key: ValueKey('quickQuestion${question.id}'),
      left: 14,
      top: safeTop + 12,
      width: size.width - 28,
      child: Material(
        type: MaterialType.transparency,
        child: _QuestionWindow(
          question: question,
          onAnswer: _answerQuickQuestion,
        ),
      ),
    );
  }

  /// 回答快问里的问题：继续在当前快问上下文里跑，不切去完整悬浮窗。
  Future<void> _answerQuickQuestion(String answer) async {
    final trimmed = answer.trim();
    if (trimmed.isEmpty) return;
    final dockNotifier = ref.read(aiDockProvider.notifier);
    final chatNotifier = ref.read(chatProvider.notifier);
    if (ref.read(aiDockProvider).quickBusy) return;
    final container = ProviderScope.containerOf(context, listen: false);
    if (container.read(chatProvider).pendingQuestion == null) return;

    _quick.clear();
    dockNotifier
      ..setQuickDraft('')
      ..setQuickBusy(true);
    _beginQuickRun(trimmed);
    _quickFocus.unfocus();
    try {
      await chatNotifier.send(trimmed);
      await _settleQuickOutcome(
        question: trimmed,
        container: container,
        dockNotifier: dockNotifier,
        liveWindowId: _liveQuickWindowId.isEmpty ? null : _liveQuickWindowId,
      );
    } catch (e) {
      dockNotifier.pushQuickResult(
        question: trimmed,
        answer: '出错了：$e',
        failed: true,
      );
    } finally {
      dockNotifier.setQuickBusy(false);
      _endQuickRun();
    }
  }

  /// 快问一轮跑完后的统一收尾。
  ///
  /// 如果模型又抛了问题，不弹“结果窗”——提问窗会自己浮出来等回答。
  Future<void> _settleQuickOutcome({
    required String question,
    required ProviderContainer container,
    required AiDockNotifier dockNotifier,
    String? liveWindowId,
  }) async {
    final chat = container.read(chatProvider);
    if (chat.pendingQuestion != null) return;
    final session = chat.currentSession;
    final last = session?.messages.lastOrNull;
    var answer = '';
    var failed = false;
    if (last == null) {
      failed = true;
      answer = '没有拿到回复。';
    } else if (last.isUser) {
      failed = true;
      answer = last.sendError.isEmpty ? '这句没发出去。' : last.sendError;
    } else {
      answer = last.content.trim();
      if (answer.isEmpty) {
        final tools = last.toolCalls.map((t) => t.name).toSet().toList();
        answer =
            tools.isEmpty ? '这一轮没有文字回复。' : '这一轮只调了工具，没写结论：${tools.join('、')}';
      }
    }
    // 如果流式过程中已经弹过正文窗，就原位更新成最终结果；
    // 没弹过（太快/纯工具轮）才新弹。
    dockNotifier.upsertQuickResult(
      id: liveWindowId,
      question: question,
      answer: answer,
      failed: failed,
    );
  }

  List<Widget> _build(BuildContext context, AiDockState dock) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final safeTop = media.padding.top;
    final safeBottom = media.padding.bottom;

    const bubble = 56.0;
    final minY = safeTop + 8;
    final maxY = size.height - safeBottom - 110 - bubble;
    final left =
        (dock.dx * (size.width - bubble)).clamp(4.0, size.width - bubble - 4);
    var top =
        (minY + dock.dy * (maxY - minY)).clamp(minY, maxY < minY ? minY : maxY);
    // 快问条伸出来时键盘会顶上来：球在下半屏的话，输入条直接被键盘盖住，
    // 用户看不见自己打的字。这时把球（和它身上的输入条）抬到键盘上面。
    final keyboard = media.viewInsets.bottom;
    if (dock.quickOpen && keyboard > 0) {
      final limit = size.height - keyboard - 8 - bubble;
      if (top > limit) top = limit < minY ? minY : limit;
    }

    final chatState = ref.watch(chatProvider);
    final busy = chatState.isLoading;
    // 等确认、等回答都是"卡在你这儿了"，球上都得亮红点。
    // 只认 pendingPlan 的话，提问挂起时球看着和空闲一模一样。
    final pending =
        chatState.pendingPlan.isNotEmpty || chatState.pendingQuestion != null;

    // 展开状态、或者用户正待在 AI 页：那儿有完整的执行过程卡，
    // 再飘一行字纯属重复。快问条伸出来时也不飘——那行字改在输入框里显示。
    final onAiPage = ref.watch(homeTabIndexProvider) == 2;
    final status = (dock.expanded || onAiPage || dock.quickOpen)
        ? ''
        : _statusText(chatState);

    // 球贴右边 → 输入条往左长；贴左边 → 往右长。永远往空的那一侧伸。
    final onRight = left + bubble / 2 > size.width / 2;

    return [
      // 输入条先入栈：球画在它上面，两者视觉上是连在一起的一个整体。
      if (dock.quickOpen)
        _quickStrip(
          context: context,
          dock: dock,
          chat: chatState,
          size: size,
          left: left,
          top: top,
          onRight: onRight,
        ),
      Positioned(
        left: left,
        top: top,
        child: GestureDetector(
          onPanDown: (_) => _bubbleMoved = 0,
          onPanUpdate: (d) {
            // 同样走增量，避免一帧多事件时位移被吞。
            _bubbleMoved += d.delta.distance;
            final span = (maxY - minY) <= 0 ? 1.0 : (maxY - minY);
            final cur = ref.read(aiDockProvider);
            ref.read(aiDockProvider.notifier).moveTo(
                  cur.dx + d.delta.dx / (size.width - bubble),
                  cur.dy + d.delta.dy / span,
                );
          },
          onPanEnd: (_) {
            // 松手吸附到最近一侧，像系统悬浮球。
            final cur = ref.read(aiDockProvider);
            ref.read(aiDockProvider.notifier)
              ..moveTo(cur.dx < 0.5 ? 0 : 1, cur.dy)
              ..commitLayout();
          },
          // 快问条伸出来时，球就是发送键；否则照旧开聊天窗。
          // open() 里已经 raise 了 AI 这一层：被浏览器压住时点一下就回到最前。
          onTap: () {
            if (dock.quickOpen) {
              _sendQuick();
              return;
            }
            ref.read(aiDockProvider.notifier).open();
          },
          onLongPress: () {
            // 拖动途中的长按不算意图：慢速拖动会先触发长按计时器。
            if (_bubbleMoved > 8) return;
            // 长按 = 伸出/收回快问输入条。
            //
            // 以前长按是"隐藏悬浮球"，两个问题：①慢速拖动经常误触，球一下
            // 就没了；②隐藏这种一次性设置，放在最容易误触的手势上不合理。
            // 现在隐藏只在「设置 → 悬浮球」里改。
            final notifier = ref.read(aiDockProvider.notifier);
            final opening = !ref.read(aiDockProvider).quickOpen;
            notifier.toggleQuickAsk();
            if (opening) {
              _quick.text = ref.read(aiDockProvider).quickDraft;
              _quick.selection =
                  TextSelection.collapsed(offset: _quick.text.length);
              // 伸出来就该能直接打字，不用再点一下输入框。
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _quickFocus.requestFocus();
              });
            } else {
              _quickFocus.unfocus();
              notifier.setQuickDraft(_quick.text);
            }
          },
          child: _Bubble(
            busy: busy,
            pending: pending,
            chips: dock.chips.length,
            unread: dock.unread,
            sendMode: dock.quickOpen,
            quickBusy: dock.quickBusy,
          ),
        ),
      ),
      if (status.isNotEmpty)
        _statusLabel(
          context: context,
          size: size,
          left: left,
          top: top,
          text: status,
        ),
    ];
  }

  /// 从球身上伸出来的那条输入框。
  ///
  /// 三个约束都是用户提的：**贴着球**（球是它的发送键，所以必须挨着）、
  /// **往空的那一侧伸**、**跑起来之后在框里用灰字显示 AI 正在想什么/调什么工具**。
  /// 最后一条是这套交互的重点：不开任何窗，光看这一行就知道有没有在推进。
  Widget _quickStrip({
    required BuildContext context,
    required AiDockState dock,
    required ChatState chat,
    required Size size,
    required double left,
    required double top,
    required bool onRight,
  }) {
    const bubble = 56.0;
    const height = 44.0;
    const rowHeight = 38.0;
    final scheme = Theme.of(context).colorScheme;
    // 和球之间留 6：视觉上连着，又不至于圆角互相咬。
    final room = onRight ? left - 12 : size.width - (left + bubble) - 12;
    final width = room.clamp(0.0, 300.0);
    // 屏幕太窄（分屏、横屏边缘）就不伸了：挤成一条缝没法打字。
    if (width < 120) return const SizedBox.shrink();

    final expanded = dock.quickExpand;
    final running = dock.quickBusy;
    // 正在跑：框里用灰字显示思考尾巴 / 正在调的工具。这就是"进度条"。
    final live = running ? _statusText(chat) : '';
    final hint = running
        ? (live.isEmpty ? '正在处理…' : live)
        : (chat.isLoading ? 'AI 正忙，问了会排队' : '问一句，结果弹小窗');

    // 箭头只负责展开/收起上面的附件行，**不收起输入条**。
    // 输入条只有长按发送键才收。箭头平时永远指向悬浮球（球在左朝左、
    // 球在右朝右），点一下用旋转动画转向"向上"，同时展开附件行；再点转回去。
    Widget expandArrow({
      required bool onRight,
      required ColorScheme scheme,
      required bool expanded,
    }) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(aiDockProvider.notifier).toggleQuickExpand(),
        child: Padding(
          padding:
              EdgeInsets.only(left: onRight ? 6 : 0, right: onRight ? 0 : 6),
          child: AnimatedRotation(
            // 基础图标是朝右的箭头：
            //  球在右 → 收起 0（朝右）/ 展开 -0.25（朝上）
            //  球在左 → 收起 0.5（朝左）/ 展开 0.75（朝上）
            turns: expanded ? (onRight ? -0.25 : 0.75) : (onRight ? 0.0 : 0.5),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: Icon(
              Icons.keyboard_arrow_right,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    Widget attachButton({required bool onRight, required ColorScheme scheme}) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _pickQuickFile(context),
        child: Padding(
          padding:
              EdgeInsets.only(left: onRight ? 6 : 0, right: onRight ? 0 : 6),
          child: Icon(
            Icons.attach_file,
            size: 18,
            color: scheme.primary,
          ),
        ),
      );
    }

    Widget quickFileChip(QuickFileRef f) {
      return GlassPanel(
        radius: 15,
        blur: 10,
        shadowY: 2,
        sheen: false,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        margin: const EdgeInsets.only(right: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 13),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: scheme.onSurface),
              ),
            ),
            const SizedBox(width: 2),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  ref.read(aiDockProvider.notifier).removeQuickFile(f.path),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child:
                    Icon(Icons.close, size: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }

    Widget attachRow() {
      return GlassPanel(
        radius: 16,
        blur: 14,
        shadowY: 4,
        sheen: false,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        margin: const EdgeInsets.only(bottom: 4),
        child: SizedBox(
          height: rowHeight,
          child: Row(
            children: [
              if (!onRight) attachButton(onRight: onRight, scheme: scheme),
              Expanded(
                child: dock.quickFiles.isEmpty
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '点 + 号选文件，AI 自己读',
                          style: TextStyle(
                            fontSize: 11,
                            color:
                                scheme.onSurfaceVariant.withValues(alpha: 0.85),
                          ),
                        ),
                      )
                    : ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final f in dock.quickFiles) quickFileChip(f),
                        ],
                      ),
              ),
              if (onRight) attachButton(onRight: onRight, scheme: scheme),
            ],
          ),
        ),
      );
    }

    final inputPanel = GlassPanel(
      radius: 22,
      blur: 18,
      shadowY: 6,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          if (!onRight)
            expandArrow(onRight: onRight, scheme: scheme, expanded: expanded),
          Expanded(
            child: TextField(
              controller: _quick,
              focusNode: _quickFocus,
              // 跑的时候锁成只读而不是 disabled：disabled 会把整框调暗，
              // 灰字提示也跟着看不清了。
              readOnly: running,
              maxLines: 1,
              textInputAction: TextInputAction.send,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hint,
                hintMaxLines: 1,
                hintStyle: TextStyle(
                  fontSize: 12,
                  // 灰字：和真正输入的内容区分开，一眼能看出"这不是我打的"。
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                ),
              ),
              onChanged: (v) =>
                  ref.read(aiDockProvider.notifier).setQuickDraft(v),
              onSubmitted: (_) => _sendQuick(),
            ),
          ),
          if (onRight)
            expandArrow(onRight: onRight, scheme: scheme, expanded: expanded),
        ],
      ),
    );

    final panelTop = top + (bubble - height) / 2;
    // 展开后附件行是上面一阶玻璃，和输入框之间留 4px 气口。
    final extraTop = expanded ? rowHeight + 4 : 0;
    final stripTop = panelTop - extraTop;
    return Positioned(
      key: const ValueKey('quickStrip'),
      left: onRight ? left - width - 6 : left + bubble + 6,
      top: stripTop,
      width: width,
      height: height + extraTop,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (expanded) attachRow(),
          inputPanel,
        ],
      ),
    );
  }

  /// 挑一个本地文件挂到快问附件行。
  ///
  /// 只记路径/名字，不读正文：AI 自己会调 `read_file`/`cat` 去看。
  /// 选择器是路由弹窗，需要借根 Navigator 的 context（和聊天窗同一个坑）。
  Future<void> _pickQuickFile(BuildContext context) async {
    final navContext = appNavigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;
    final notifier = ref.read(aiDockProvider.notifier);
    final picked = await LocalFilePicker.pick(navContext);
    if (picked == null || !mounted) return;
    notifier.addQuickFile(path: picked.path, name: picked.name);
    final toastContext = appNavigatorKey.currentContext;
    if (toastContext == null || !toastContext.mounted) return;
    ScaffoldMessenger.of(toastContext).showSnackBar(
      SnackBar(
        content: Text('已附上 ${picked.name}（只发路径，AI 自己读）'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 把快问问题 + 附件路径拼成最终提问。
  ///
  /// 用户明确说了：不要塞文件全文，只发路径，AI 自己调工具去读。
  String _quickPrompt(String question, List<QuickFileRef> files) {
    if (files.isEmpty) return question;
    final q = question.trim();
    final paths = files.map((f) => f.path).join('\n');
    return [
      if (q.isNotEmpty) q,
      '以下附件只给路径，请逐个调用文件读取工具拿到内容后再回答：',
      paths,
    ].join('\n');
  }

  /// 快问发送：跑一轮，把答案弹成结果窗。
  Future<void> _sendQuick() async {
    final question = _quick.text.trim();
    final dockNotifier = ref.read(aiDockProvider.notifier);
    if (question.isEmpty) {
      _quickFocus.requestFocus();
      return;
    }
    if (ref.read(aiDockProvider).quickBusy) return;
    final dockState = ref.read(aiDockProvider);
    final files = dockState.quickFiles;
    final prompt = _quickPrompt(question, files);
    final chatNotifier = ref.read(chatProvider.notifier);
    // 这一轮要 await 好几分钟，中途这个 widget 完全可能被重建掉，
    // 之后再碰 ref 会抛"Cannot use ref after dispose"。所以先把容器取出来，
    // 后面一律用它读状态——容器是跟着 App 活的，不跟着 widget 走。
    final container = ProviderScope.containerOf(context, listen: false);
    // 已经有任务在跑：send() 会把这句丢进排队区、立刻返回，我们等不到结果。
    // 那就如实说一声，别装作发出去了然后永远不弹窗。
    if (container.read(chatProvider).isLoading) {
      chatNotifier.enqueue(prompt);
      _quick.clear();
      dockNotifier
        ..setQuickDraft('')
        ..clearQuickFiles();
      _toast('AI 正在忙，这句已排队（结果去聊天窗看）');
      return;
    }
    if (container.read(chatProvider).pendingQuestion != null) {
      // 快问模式下还有未答的问题：输入框里这句直接当回答发出去，
      // 不展开完整悬浮窗。提问窗已经浮在屏幕上方了。
    }

    _quick.clear();
    dockNotifier
      ..setQuickDraft('')
      ..clearQuickFiles()
      ..setQuickBusy(true);
    _beginQuickRun(question);
    _quickFocus.unfocus();
    try {
      await chatNotifier.send(prompt);
      await _settleQuickOutcome(
        question: question,
        container: container,
        dockNotifier: dockNotifier,
        liveWindowId: _liveQuickWindowId.isEmpty ? null : _liveQuickWindowId,
      );
    } catch (e) {
      dockNotifier.pushQuickResult(
        question: question,
        answer: '出错了：$e',
        failed: true,
      );
    } finally {
      dockNotifier.setQuickBusy(false);
      _endQuickRun();
    }
  }

  void _toast(String text) {
    final navContext = appNavigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;
    ScaffoldMessenger.of(navContext).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  /// 悬浮球旁边那行实时状态字。
  ///
  /// 收起状态下 AI 在干什么，用户完全看不见——只有一个转圈的球。这行字就是
  /// 那个缺口：思考就写"思考中"，调工具就写工具名，一行、不换行、不带底。
  ///
  /// 三个约束是用户提的：**穿透**（点它等于点它后面的东西）、**背景透明**、
  /// **位置跟着球走**（球在右边字就在左边，球在左边字就在右边，永远往空的
  /// 那一侧长）。展开状态和 AI 页都不显示——那两种场合有完整的过程卡。
  Widget _statusLabel({
    required BuildContext context,
    required Size size,
    required double left,
    required double top,
    required String text,
  }) {
    const bubble = 56.0;
    final scheme = Theme.of(context).colorScheme;
    // 球贴右边 → 字往左长；贴左边 → 字往右长。
    final onRight = left + bubble / 2 > size.width / 2;
    final room = onRight ? left - 8 : size.width - (left + bubble) - 8;
    final width = room.clamp(0.0, 220.0);
    if (width < 56) return const SizedBox.shrink();
    return Positioned(
      left: onRight ? left - width - 4 : left + bubble + 4,
      // 和球垂直居中：球 56 高，这行字 18 高。
      top: top + (bubble - 18) / 2,
      width: width,
      child: IgnorePointer(
        // 这里显示的是**思考原文的尾巴**，不是"思考中"三个字。
        //
        // 用户原话："我希望他显示不是正在思考，而是思考内容也在那个字里面，
        // 不用长就滚动思考，短的就可以，主要用于看有没有思考进度而已。"
        // 一行字里跑着模型正在想的最后几十个字，字在动就说明还在推进，
        // 卡住了一眼就能看出来——比一个恒定的"思考中"有用得多。
        child: _StatusTail(
          text: text,
          width: width,
          alignRight: onRight,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.5,
            fontWeight: FontWeight.w600,
            // 半透明：看得见但不抢戏，也不会挡住底下页面的内容。
            color: scheme.onSurface.withValues(alpha: 0.55),
            shadows: [
              // 深色/浅色背景上都要认得出来，所以垫一层极淡的描边阴影，
              // 而不是给它加背景块（用户明确要求背景透明）。
              Shadow(
                blurRadius: 6,
                color: scheme.surface.withValues(alpha: 0.9),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 现在在干什么，压成一小段话。
  ///
  /// 优先级：正在调的工具 > 思考 > 正在答 > 最近一步的类型。都没有就返回空串
  /// （空串 = 这一行不显示）。
  String _statusText(ChatState chat) {
    // 挂起等回答时 isLoading 是 false，但这恰恰是最需要提示的时刻：
    // 收起状态下提问窗不画出来，球也不转，用户完全不知道 AI 在等他说话——
    // 看着就是"问了一次就卡住了"。
    if (chat.pendingQuestion != null) return '等你回答';
    if (chat.pendingPlan.isNotEmpty) return '等你确认';
    if (!chat.isLoading) return '';
    if (chat.liveTool.isNotEmpty) return chat.liveTool;
    // 思考/正文都显示**正在流的原文尾巴**，让这行字自己动起来。
    if (chat.liveReasoning.isNotEmpty) return statusTail(chat.liveReasoning);
    if (chat.liveContent.isNotEmpty) return statusTail(chat.liveContent);
    final events = chat.liveAgentEvents;
    if (events.isNotEmpty) {
      return switch (events.last.kind) {
        AgentEventKind.thinking => '思考中',
        AgentEventKind.answer => '答复中',
        AgentEventKind.toolStart => events.last.toolName ?? '调用工具',
        AgentEventKind.toolEnd => '处理结果',
        AgentEventKind.taskPlan => '规划任务',
        AgentEventKind.canvas => '生成卡片',
        AgentEventKind.question => '等你回答',
        AgentEventKind.planPending => '等你确认',
        AgentEventKind.error => '出错了',
        AgentEventKind.done => '收尾',
      };
    }
    return '处理中';
  }
}

/// 取一段流式文字的尾巴，压成能塞进一行的样子。
///
/// 三件事：换行/连续空白压成一个空格（一行字里出现空行会看着像断了）、
/// 只留最后 [keep] 个字（整段 6000 字每 80ms 重排一次太贵，也没人看得完）、
/// 全是空白就返回空串（空串 = 这一行不显示）。
String statusTail(String raw, {int keep = 80}) {
  final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return '';
  return flat.length <= keep ? flat : flat.substring(flat.length - keep);
}

/// 单行、自动贴住末尾的滚动文字。
///
/// 为什么不用 `TextOverflow.ellipsis`：省略号只能砍尾巴，而这行字要看的恰恰是
/// **最新写出来的那几个字**。所以做成一个横向滚动视口，每次文字变了就跳到
/// 末尾——视觉上就是字从右往左滚，最新的字永远贴在贴近球的那一侧。
///
/// 文字比视口短时靠 minWidth + textAlign 决定贴哪边：球在右边字靠右、
/// 球在左边字靠左，始终往空的那一侧长。
class _StatusTail extends StatefulWidget {
  const _StatusTail({
    required this.text,
    required this.width,
    required this.alignRight,
    required this.style,
  });

  final String text;
  final double width;
  final bool alignRight;
  final TextStyle style;

  @override
  State<_StatusTail> createState() => _StatusTailState();
}

class _StatusTailState extends State<_StatusTail> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _pin();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _StatusTail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.width != widget.width) {
      _pin();
    }
  }

  /// 贴到末尾。新字要等排完版才知道有多宽，所以放帧后。
  void _pin() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      if ((_controller.position.pixels - max).abs() > 0.5) {
        _controller.jumpTo(max);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      // 整行套在 IgnorePointer 里，本来就不接受手指；显式关掉滚动物理，
      // 免得它去参与手势竞争。
      physics: const NeverScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: widget.width),
        child: Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          textAlign: widget.alignRight ? TextAlign.right : TextAlign.left,
          style: widget.style,
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.busy,
    required this.pending,
    required this.chips,
    required this.unread,
    this.sendMode = false,
    this.quickBusy = false,
  });

  final bool busy;
  final bool pending;
  final int chips;
  final int unread;

  /// 快问条伸出来了：球现在是发送键，图标要跟着换，
  /// 否则用户看着还是"打开 AI"的样子，不敢点。
  final bool sendMode;

  /// 快问那一轮正在跑：球上转圈，同时输入框里滚灰字。
  final bool quickBusy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final badge = pending
        ? '!'
        : chips > 0
            ? '$chips'
            : unread > 0
                ? '$unread'
                : null;
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GlassPanel(
            radius: 28,
            blur: 16,
            shadowY: 6,
            child: SizedBox(
              width: 56,
              height: 56,
              child: Center(
                child: busy || quickBusy
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: scheme.primary,
                        ),
                      )
                    : Icon(
                        sendMode
                            ? Icons.arrow_upward_rounded
                            : Icons.auto_awesome,
                        size: sendMode ? 26 : 24,
                        color: pending ? scheme.error : scheme.primary,
                      ),
              ),
            ),
          ),
          if (badge != null)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: pending ? scheme.error : scheme.primary,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: Glass.shadow(scheme, y: 2),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    color: pending ? scheme.onError : scheme.onPrimary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Window extends ConsumerStatefulWidget {
  const _Window({
    required this.input,
    required this.scroll,
    required this.onSend,
    required this.onToBottom,
    required this.field,
  });

  final TextEditingController input;
  final ScrollController scroll;
  final VoidCallback onSend;
  final VoidCallback onToBottom;

  /// 可用区域尺寸：把手指位移换算成占比增量时要用。
  final Size field;

  @override
  ConsumerState<_Window> createState() => _WindowState();
}

class _WindowState extends ConsumerState<_Window> {
  /// 边缘热区宽度：手指能舒服地捏到，又不至于挡住内容。
  static const _grip = 22.0;

  /// 上边缘热区**必须**比标题栏一半还矮。
  ///
  /// 热区画在标题栏之上，且 [HitTestBehavior.opaque]：只要它罩住了某个按钮的
  /// 中心点，那个按钮就彻底哑火——点下去只被当成一次零位移拖拽。标题栏现在只有
  /// [_Header.height]，按钮的可点区域又被 Material 撑到整条标题栏高，
  /// 22 的热区正好压住它们的中心。12 留出足够余量，也还够手指捏住上边框。
  /// 断言在 [build] 里：改 [_Header.height] 时立刻炸，而不是等到按钮又哑了。
  static const _gripTop = 12.0;

  /// 会话面板是否盖在对话上。放在 State 里而不是 dock provider 里：
  /// 它纯粹是这一扇窗当下的界面状态，悬浮窗一收起就该忘掉，
  /// 不该跟着窗口几何一起落盘。
  bool _sessions = false;

  @override
  Widget build(BuildContext context) {
    assert(
      _gripTop < _Header.height / 2,
      '上边缘热区盖住了标题栏按钮的中心点，那些按钮会点不动',
    );
    final input = widget.input;
    final scroll = widget.scroll;
    final onSend = widget.onSend;
    final field = widget.field;
    final scheme = Theme.of(context).colorScheme;
    final dock = ref.watch(aiDockProvider);
    final dockNotifier = ref.read(aiDockProvider.notifier);
    final chat = ref.watch(chatProvider);
    final chatNotifier = ref.read(chatProvider.notifier);
    // 全部历史，不做截断。
    //
    // 之前这里只留最近 8 条，往上翻就没了，和 AI 页对不上——用户以为
    // 会话丢了。悬浮窗矮不是"少给数据"的理由，ListView 本来就是懒构建的，
    // 屏幕外的消息不会真的建出来。
    final recent = chat.messages;

    return Stack(
      children: [
        Positioned.fill(
          child: GlassPanel(
            radius: 24,
            blur: Glass.blurStrong,
            shadowY: 14,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                // 标题栏兼拖动把手：按住它挪窗口。
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) => dockNotifier.moveWindowBy(
                    d.delta.dx / field.width,
                    d.delta.dy / field.height,
                  ),
                  onPanEnd: (_) => dockNotifier.commitLayout(),
                  child: _Header(
                    approval: chat.approvalMode,
                    busy: chat.isLoading,
                    sessionsOpen: _sessions,
                    onSessions: () => setState(() => _sessions = !_sessions),
                    onClose: dockNotifier.close,
                    onFull: () {
                      dockNotifier.close();
                      ref.read(homeTabIndexProvider.notifier).state = 2;
                    },
                    onApproval: () => _approvalMenu(context, ref),
                  ),
                ),
                // 挂着的代码编辑器：让用户看清"我说改代码，AI 会改哪一个"。
                if (!_sessions) const _EditorStrip(),
                Expanded(
                  // 会话管理就盖在对话区上：换会话不用切到 AI 页，
                  // 也不用把悬浮窗收起来——那两步就是用户嫌麻烦的地方。
                  child: _sessions
                      ? AiSessionList(
                          dense: true,
                          onLeave: () => setState(() => _sessions = false),
                          onClose: () => setState(() => _sessions = false),
                        )
                      : recent.isEmpty &&
                              chat.liveAgentEvents.isEmpty &&
                              !chat.isLoading
                          ? _Hints(
                              onPick: (t) {
                                input.text = t;
                                onSend();
                              },
                            )
                          : ListView(
                              controller: scroll,
                              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                              children: [
                                for (final (index, m) in recent.indexed) ...[
                                  // 过程卡在答案上面——和 AI 页一致：先看它怎么做的，
                                  // 再看结论。放答案下面会把结论顶走，读起来是倒的。
                                  if (m.agentEvents.isNotEmpty && !m.isUser)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: AgentProcessCard(
                                        events: m.agentEvents,
                                        running: false,
                                        turns: m.turns,
                                        totalTokens: m.totalTokens,
                                      ),
                                    ),
                                  _MiniBubble(
                                    isUser: m.isUser,
                                    text: m.content,
                                    outcome: m.outcome,
                                    images: m.images,
                                    // 悬浮窗以前没有重发/撤回：发错一句只能
                                    // 切到 AI 页去改，用户直接说"悬浮窗 AI
                                    // 不能重发"。这里补齐，交互上用"点两下
                                    // 确认"代替弹窗——弹窗在悬浮层里会生到
                                    // 窗口底下，根本看不见。
                                    onResend: m.isUser && !chat.isLoading
                                        ? () => ref
                                            .read(chatProvider.notifier)
                                            .resendAt(index)
                                        : null,
                                    onRollback: m.isUser && !chat.isLoading
                                        ? () {
                                            final text = ref
                                                .read(chatProvider.notifier)
                                                .rollbackTo(index);
                                            if (text.trim().isNotEmpty) {
                                              input.text = text;
                                              input.selection =
                                                  TextSelection.collapsed(
                                                offset: text.length,
                                              );
                                            }
                                          }
                                        : null,
                                  ),
                                  // 这条没发出去：气泡下面标红字，和 AI 页一致。
                                  if (m.failedToSend)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Text(
                                        '未发送成功：${m.sendError}',
                                        textAlign: TextAlign.right,
                                        style: TextStyle(
                                          fontSize: 11,
                                          height: 1.3,
                                          fontWeight: FontWeight.w600,
                                          color: scheme.error,
                                        ),
                                      ),
                                    ),
                                  if (m.failedToSend &&
                                      m.agentEvents.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: AgentProcessCard(
                                        events: m.agentEvents,
                                        running: false,
                                        turns: m.turns,
                                        totalTokens: m.totalTokens,
                                      ),
                                    ),
                                ],
                                if (chat.liveAgentEvents.isNotEmpty)
                                  AgentProcessCard(
                                    events: chat.liveAgentEvents,
                                    running: chat.isLoading,
                                    totalTokens: chat.lastTokens,
                                  ),
                                // 正在流的那一段：悬浮窗矮，用 dense 排版。
                                if (chat.isLoading)
                                  AgentStreamCard(
                                    reasoning: chat.liveReasoning,
                                    content: chat.liveContent,
                                    reasoningChars: chat.liveReasoningChars,
                                    contentChars: chat.liveContentChars,
                                    tool: chat.liveTool,
                                    dense: true,
                                  ),
                                // 提问不在这里显示：它已经浮成最上层的独立窗口。
                                // 两处都画会出现两张一样的卡片，答一次另一张还留着。
                                if (chat.pendingQuestion == null &&
                                    chat.pendingPlan.isNotEmpty)
                                  _MiniConfirm(
                                    count: chat.pendingPlan.length,
                                    irreversible: chat.pendingPlan
                                        .any((a) => !a.reversible),
                                    names: chat.pendingPlan
                                        .map((a) => a.type)
                                        .join('、'),
                                    onConfirm: chatNotifier.confirmPlan,
                                    onReject: chatNotifier.rejectPlan,
                                  ),
                                // 错误不在这里另画一遍：它已经作为红字挂在
                                // 那条"没发出去"的用户消息下面了。两处都画
                                // 会让用户以为出了两次错。
                              ],
                            ),
                ),
                if (!_sessions)
                  PendingImageBar(
                    images: chat.pendingImages,
                    onRemove: chatNotifier.removePendingImage,
                    margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  ),
                if (!_sessions && dock.chips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (var i = 0; i < dock.chips.length; i++)
                            InputChip(
                              visualDensity: VisualDensity.compact,
                              // 只读附件（页面自动带上来的日志）换个图标，
                              // 让用户一眼看出这是"我正在看的东西"而不是他手动加的。
                              avatar: Icon(
                                dock.chips[i].readOnly
                                    ? Icons.visibility_outlined
                                    : Icons.attachment,
                                size: 14,
                              ),
                              label: Text(
                                dock.chips[i].label,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              onDeleted: () => dockNotifier.removeChip(i),
                            ),
                        ],
                      ),
                    ),
                  ),
                // 悬浮窗的输入行只留「粘贴 + 输入框 + 发送」三件套。
                // 模型/策略/强度/上下文那一行在这么窄的窗口里纯属占地方，
                // 需要改就去 AI 页或设置页。
                if (!_sessions && chat.queue.isNotEmpty)
                  QueueStrip(
                    queue: chat.queue,
                    compact: true,
                    margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                    onReorder: chatNotifier.reorderQueue,
                    onRemove: chatNotifier.dequeue,
                    onInterruptSend: chatNotifier.interruptAndSend,
                  ),
                if (!_sessions)
                  AiComposer(
                    state: chat,
                    controller: input,
                    compact: true,
                    showControls: false,
                    margin: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                    onSend: onSend,
                    onStop: chatNotifier.stopAgent,
                    onChanged: dockNotifier.setDraft,
                    onAttach: () => _pickFile(context, ref),
                    onPaste: () async {
                      final ok = await dockNotifier.pushClipboard();
                      final navContext = appNavigatorKey.currentContext;
                      if (navContext == null || !navContext.mounted) return;
                      ScaffoldMessenger.of(navContext).showSnackBar(
                        SnackBar(
                          content: Text(ok ? '已附上剪贴板内容' : '剪贴板是空的'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                    // 下面这些在 showControls=false 时用不到，占位保持签名完整。
                    onModelTap: () => AiControlSheets.showModelPicker(
                      appNavigatorKey.currentContext ?? context,
                    ),
                    onStrengthTap: () => AiControlSheets.showStrength(
                      appNavigatorKey.currentContext ?? context,
                    ),
                    onContextTap: () => AiControlSheets.showContext(
                      appNavigatorKey.currentContext ?? context,
                      ref,
                    ),
                    onApprovalTap: () => _approvalMenu(context, ref),
                  ),
              ],
            ),
          ),
        ),
        // 四边 + 四角热区：按住边缘随手指改窗口大小。
        _Edge(
          alignment: Alignment.centerLeft,
          width: _grip,
          cursor: SystemMouseCursors.resizeLeftRight,
          onDrag: (d) => dockNotifier.resizeEdge(dLeft: d.dx / field.width),
          onEnd: dockNotifier.commitLayout,
        ),
        _Edge(
          alignment: Alignment.centerRight,
          width: _grip,
          cursor: SystemMouseCursors.resizeLeftRight,
          onDrag: (d) => dockNotifier.resizeEdge(dRight: d.dx / field.width),
          onEnd: dockNotifier.commitLayout,
        ),
        _Edge(
          alignment: Alignment.topCenter,
          height: _gripTop,
          cursor: SystemMouseCursors.resizeUpDown,
          onDrag: (d) => dockNotifier.resizeEdge(dTop: d.dy / field.height),
          onEnd: dockNotifier.commitLayout,
        ),
        _Edge(
          alignment: Alignment.bottomCenter,
          height: _grip,
          cursor: SystemMouseCursors.resizeUpDown,
          onDrag: (d) => dockNotifier.resizeEdge(dBottom: d.dy / field.height),
          onEnd: dockNotifier.commitLayout,
        ),
        // 上排两个角同样压到 [_gripTop] 高：标题栏的按钮就在这儿，
        // 角热区一旦罩住按钮中心，按钮就点不动了（见 _gripTop 注释）。
        _Edge(
          alignment: Alignment.topLeft,
          width: _grip,
          height: _gripTop,
          cursor: SystemMouseCursors.resizeUpLeft,
          onDrag: (d) => dockNotifier.resizeEdge(
            dLeft: d.dx / field.width,
            dTop: d.dy / field.height,
          ),
          onEnd: dockNotifier.commitLayout,
        ),
        _Edge(
          alignment: Alignment.topRight,
          width: _grip,
          height: _gripTop,
          cursor: SystemMouseCursors.resizeUpRight,
          onDrag: (d) => dockNotifier.resizeEdge(
            dRight: d.dx / field.width,
            dTop: d.dy / field.height,
          ),
          onEnd: dockNotifier.commitLayout,
        ),
        _Edge(
          alignment: Alignment.bottomLeft,
          width: _grip * 1.4,
          height: _grip * 1.4,
          cursor: SystemMouseCursors.resizeDownLeft,
          onDrag: (d) => dockNotifier.resizeEdge(
            dLeft: d.dx / field.width,
            dBottom: d.dy / field.height,
          ),
          onEnd: dockNotifier.commitLayout,
        ),
        _Edge(
          alignment: Alignment.bottomRight,
          width: _grip * 1.4,
          height: _grip * 1.4,
          cursor: SystemMouseCursors.resizeDownRight,
          onDrag: (d) => dockNotifier.resizeEdge(
            dRight: d.dx / field.width,
            dBottom: d.dy / field.height,
          ),
          onEnd: dockNotifier.commitLayout,
          indicator: true,
        ),
      ],
    );
  }

  /// 挑一个本地文件当附件。选择器是路由弹窗，必须借根 Navigator 的 context：
  /// 悬浮层在 Navigator 之上，用自己的 context 弹出来会被窗口自己盖住。
  Future<void> _pickFile(BuildContext context, WidgetRef ref) async {
    final navContext = appNavigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;
    final notifier = ref.read(aiDockProvider.notifier);
    // 选择器是路由弹窗，活在 Navigator 里，也就是**这一层的下面**——
    // 聊天窗会压在它上面，重叠区域的点击还会被聊天窗吃掉。
    // 所以挑文件期间先把窗口收起来，选完（或取消）再回来。
    notifier.close();
    final picked = await LocalFilePicker.pick(navContext);
    if (picked == null) {
      notifier.open();
      return;
    }
    if (picked.mime.toLowerCase().startsWith('image/')) {
      final registry = ref.read(llmRegistryProvider);
      if (registry.visionModel.trim().isEmpty ||
          registry.visionProviderId.isEmpty) {
        notifier.open();
        final toastContext = appNavigatorKey.currentContext;
        if (toastContext != null && toastContext.mounted) {
          ScaffoldMessenger.of(toastContext).showSnackBar(
            const SnackBar(
              content: Text('还没有设置图片识别模型，去「设置 → AI → 图片识别模型」里配置后才能发图片。'),
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }
      final image = await readPickedImage(picked);
      if (image == null) {
        notifier.open();
        final toastContext = appNavigatorKey.currentContext;
        if (toastContext != null && toastContext.mounted) {
          ScaffoldMessenger.of(toastContext).showSnackBar(
            SnackBar(content: Text('图片读取失败：${picked.path}')),
          );
        }
        return;
      }
      ref.read(chatProvider.notifier).addPendingImage(image);
      notifier.open();
      final toastContext = appNavigatorKey.currentContext;
      if (toastContext != null && toastContext.mounted) {
        ScaffoldMessenger.of(toastContext).showSnackBar(
          SnackBar(
            content: Text('已附上图片 ${picked.name}'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
      return;
    }
    // pushFile(open: true) 会把窗口重新展开，附件已经在输入框上方了。
    final label = notifier.pushFile(
      path: picked.path,
      name: picked.name,
      content: picked.content,
      language: picked.language,
      truncated: picked.truncated,
    );
    final toastContext = appNavigatorKey.currentContext;
    if (toastContext == null || !toastContext.mounted) return;
    ScaffoldMessenger.of(toastContext).showSnackBar(
      SnackBar(
        content: Text('已附上 $label'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _approvalMenu(BuildContext context, WidgetRef ref) {
    // 悬浮层在 Navigator 之上，弹窗要借根 Navigator 的 context。
    final navContext = appNavigatorKey.currentContext ?? context;
    showModalBottomSheet<void>(
      context: navContext,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final current = ref.watch(chatProvider).approvalMode;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in AiApprovalMode.values)
                  ListTile(
                    selected: current == mode,
                    leading: Icon(switch (mode) {
                      AiApprovalMode.strict => Icons.lock_outline,
                      AiApprovalMode.cautious => Icons.shield_outlined,
                      AiApprovalMode.full => Icons.rocket_launch_outlined,
                    }),
                    title: Text(mode.label),
                    subtitle: Text(
                      mode.description,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: current == mode ? const Icon(Icons.check) : null,
                    onTap: () {
                      ref.read(chatProvider.notifier).setApprovalMode(mode);
                      Navigator.pop(context);
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 标题栏图标按钮的触点：默认 40 宽，四个按钮加策略胶囊排下来会把标题挤没。
/// 收到 30 既够手指点，也给"AI 悬浮助手"留得下位置。
const _hdrBtn = BoxConstraints(minWidth: 30, minHeight: 30);

class _Header extends StatelessWidget {
  const _Header({
    required this.approval,
    required this.busy,
    required this.sessionsOpen,
    required this.onSessions,
    required this.onClose,
    required this.onFull,
    required this.onApproval,
  });

  final AiApprovalMode approval;
  final bool busy;
  final bool sessionsOpen;
  final VoidCallback onSessions;
  final VoidCallback onClose;
  final VoidCallback onFull;
  final VoidCallback onApproval;

  /// 标题栏高度写死：悬浮窗本来就矮，额头每多一档都是从对话区抢的。
  /// 写死还有一层保险——里面任何一个孩子将来变高都撑不开它，
  /// 不会再出现"多加一个按钮，额头悄悄长高一截"这种事。
  ///
  /// 改这个值要连带看一眼 [_WindowState._gripTop]：上边缘热区必须比它的一半还矮，
  /// 否则热区会盖掉标题栏所有按钮的中心点。
  static const height = 38.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: Padding(
        // 右边留 24：右边缘热区占了最外 22，按钮压进去就点不动了。
        padding: const EdgeInsets.fromLTRB(12, 0, 24, 0),
        child: Row(
          children: [
            Icon(
              Icons.auto_awesome,
              size: 16,
              color: busy ? scheme.tertiary : scheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                busy ? 'AI 正在执行…' : 'AI 悬浮助手',
                // 一行到底 + 省略号：窗口窄的时候标题会被右边一排按钮挤扁，
                // 默认换行策略会把它排成一列竖字，顺带把整条额头顶高。
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
            ),
            const SizedBox(width: 4),
            GlassPill(
              icon: switch (approval) {
                AiApprovalMode.strict => Icons.lock_outline,
                AiApprovalMode.cautious => Icons.shield_outlined,
                AiApprovalMode.full => Icons.rocket_launch_outlined,
              },
              label: approval.label,
              dense: true,
              color: approval == AiApprovalMode.full ? scheme.error : null,
              onTap: onApproval,
            ),
            const SizedBox(width: 2),
            // 会话管理：悬浮窗里直接换会话/新建/改名，不用再切一趟 AI 页。
            IconButton(
              tooltip: sessionsOpen ? '回到对话' : '会话管理',
              visualDensity: VisualDensity.compact,
              constraints: _hdrBtn,
              padding: EdgeInsets.zero,
              onPressed: onSessions,
              icon: Icon(
                sessionsOpen ? Icons.forum : Icons.forum_outlined,
                size: 17,
                color: sessionsOpen ? scheme.primary : null,
              ),
            ),
            // 悬浮模式下也能开浏览器：AI 说"需要你登录一下"时不必先切回 AI 页。
            ValueListenableBuilder<bool>(
              valueListenable: BrowserEngine.instance.visible,
              builder: (context, visible, _) => IconButton(
                tooltip: visible ? '收起浏览器' : '打开浏览器',
                visualDensity: VisualDensity.compact,
                constraints: _hdrBtn,
                padding: EdgeInsets.zero,
                onPressed: () => visible
                    ? BrowserEngine.instance.hide()
                    : BrowserEngine.instance.show(),
                icon: Icon(
                  visible ? Icons.public : Icons.public_outlined,
                  size: 17,
                  color: visible ? scheme.primary : null,
                ),
              ),
            ),
            IconButton(
              tooltip: '在 AI 页打开',
              visualDensity: VisualDensity.compact,
              constraints: _hdrBtn,
              padding: EdgeInsets.zero,
              onPressed: onFull,
              icon: const Icon(Icons.open_in_full, size: 17),
            ),
            IconButton(
              tooltip: '收起',
              visualDensity: VisualDensity.compact,
              constraints: _hdrBtn,
              padding: EdgeInsets.zero,
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 17),
            ),
          ],
        ),
      ),
    );
  }
}

/// 当前挂在编辑器总线上的编辑器条。
///
/// 「AI 悬浮窗包括 AI 本身需要识别需要操控哪套编辑器」——识别这件事对 AI 来说
/// 是提示词 + editor_list，对用户来说必须**看得见**：这条就是给用户看的，
/// 明确写着"现在改的是青龙脚本编辑器/浏览器抓包脚本/某个文件"，
/// 开了多个还能点着切。这样绝不会出现"我以为在改青龙，结果改了浏览器"。
class _EditorStrip extends StatefulWidget {
  const _EditorStrip();

  @override
  State<_EditorStrip> createState() => _EditorStripState();
}

class _EditorStripState extends State<_EditorStrip> {
  final _bus = EditorBus.instance;

  @override
  void initState() {
    super.initState();
    _bus.addListener(_onBus);
  }

  @override
  void dispose() {
    _bus.removeListener(_onBus);
    super.dispose();
  }

  void _onBus() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final handles = _bus.handles;
    if (handles.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final active = _bus.active;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            Icon(
              _bus.busy ? Icons.edit_note : Icons.code_rounded,
              size: 15,
              color: _bus.busy ? scheme.tertiary : scheme.primary,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: handles.length,
                separatorBuilder: (_, __) => const SizedBox(width: 5),
                itemBuilder: (context, index) {
                  final handle = handles[index];
                  final selected = handle.id == active?.id;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _bus.touch(handle.id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        color: selected
                            ? scheme.primary.withValues(alpha: 0.16)
                            : scheme.surfaceContainerHighest
                                .withValues(alpha: 0.35),
                        border: Border.all(
                          color: selected
                              ? scheme.primary
                              : scheme.outlineVariant.withValues(alpha: 0.6),
                          width: selected ? 1.1 : 0.7,
                        ),
                      ),
                      child: Text(
                        '${_kindShort(handle.kind)} ${handle.title}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? scheme.primary : scheme.onSurface,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _kindShort(EditorKind kind) => switch (kind) {
        EditorKind.qinglongScript => '青龙',
        EditorKind.browserHook => '抓包',
        EditorKind.shellFile => '文件',
        EditorKind.panelConfig => '配置',
      };
}

/// 悬浮窗边缘缩放热区。
///
/// 单独抽出来是因为八个方向逻辑相同，只是对齐方式与增量映射不同；
/// [indicator] 给右下角画一个小斜杠，提示"这里能拉"。
/// 悬浮模式下的提问窗。
///
/// 为什么要单独一个：AI 页里 ask_user 是聊天流末尾的一张卡片，用户往下翻
/// 就看到了；但在悬浮模式下用户正盯着别的页面（终端、脚本、面板），
/// 那张卡片藏在小窗口的滚动区里，等于没提问——用户只会觉得"AI 卡住了"。
/// 所以悬浮时把它抬到最上层、盖在聊天窗前面，答完自动消失。
class _QuestionWindow extends StatelessWidget {
  const _QuestionWindow({required this.question, required this.onAnswer});

  final AgentQuestion question;
  final ValueChanged<String> onAnswer;

  @override
  Widget build(BuildContext context) {
    // 复用 AI 页那张卡片：选项按钮、自由输入、防连点的逻辑全都一样，
    // 没有理由再写一遍（写第二遍就会有第二套 bug）。
    return AiQuestionCard(question: question, onAnswer: onAnswer);
  }
}

/// 悬浮模式下的互动画布窗：可拖动、可按边缩放的浮动窗口。
class _CanvasWindow extends StatefulWidget {
  const _CanvasWindow({
    required this.canvas,
    required this.field,
    required this.onMove,
    required this.onResize,
    required this.onCommit,
    required this.onClose,
    this.chromeless = false,
  });

  final AiCanvas canvas;

  /// 无边框：不画标题栏，内容贴到窗口四边，只在右上角留一个淡淡的关闭点
  /// 和一个同样淡的拖动把手（没有把手就只能靠边框缩放，窗口挪不动）。
  final bool chromeless;
  final Size field;
  final void Function(double dx, double dy) onMove;
  final void Function({
    double dLeft,
    double dTop,
    double dRight,
    double dBottom,
  }) onResize;
  final VoidCallback onCommit;
  final VoidCallback onClose;

  @override
  State<_CanvasWindow> createState() => _CanvasWindowState();
}

class _CanvasWindowState extends State<_CanvasWindow> {
  final _view = AiCanvasViewController();
  bool _submitted = false;

  static const _grip = 20.0;

  void _onSubmit() {
    if (!mounted) return;
    setState(() => _submitted = true);
    // 提交完自动收起：结果已经回到 AI 手里了，
    // 让用户再点一次关闭是多余动作。
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final awaiting = widget.canvas.expectResult && !_submitted;
    final radius = widget.chromeless ? 18.0 : 22.0;
    final view = AiCanvasView(
      canvas: widget.canvas,
      controller: _view,
      onSubmit: _onSubmit,
      onRequestClose: widget.onClose,
    );
    return Stack(
      children: [
        Positioned.fill(
          child: GlassPanel(
            radius: radius,
            blur: Glass.blurStrong,
            shadowY: 14,
            padding: EdgeInsets.zero,
            child: widget.chromeless
                // 无边框：内容铺满整个窗口，四个角跟着窗口圆角裁一下。
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: view,
                  )
                : Column(
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (d) => widget.onMove(
                          d.delta.dx / widget.field.width,
                          d.delta.dy / widget.field.height,
                        ),
                        onPanEnd: (_) => widget.onCommit(),
                        child: AiCanvasHeader(
                          canvas: widget.canvas,
                          awaiting: awaiting,
                          onReload: _view.reload,
                          onClose: widget.onClose,
                        ),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.vertical(
                            bottom: Radius.circular(radius),
                          ),
                          child: view,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        _Edge(
          alignment: Alignment.centerLeft,
          width: _grip,
          cursor: SystemMouseCursors.resizeLeftRight,
          onDrag: (d) => widget.onResize(dLeft: d.dx / widget.field.width),
          onEnd: widget.onCommit,
        ),
        _Edge(
          alignment: Alignment.centerRight,
          width: _grip,
          cursor: SystemMouseCursors.resizeLeftRight,
          onDrag: (d) => widget.onResize(dRight: d.dx / widget.field.width),
          onEnd: widget.onCommit,
        ),
        // 上边缘只在无边框时开放：有标题栏时它会盖住标题栏按钮的中心点，
        // 那些按钮就点不动了（和聊天窗同一个坑）。
        if (widget.chromeless)
          _Edge(
            alignment: Alignment.topCenter,
            height: _grip * 0.6,
            cursor: SystemMouseCursors.resizeUpDown,
            onDrag: (d) => widget.onResize(dTop: d.dy / widget.field.height),
            onEnd: widget.onCommit,
          ),
        _Edge(
          alignment: Alignment.bottomCenter,
          height: _grip,
          cursor: SystemMouseCursors.resizeUpDown,
          onDrag: (d) => widget.onResize(dBottom: d.dy / widget.field.height),
          onEnd: widget.onCommit,
        ),
        _Edge(
          alignment: Alignment.bottomRight,
          width: _grip * 1.4,
          height: _grip * 1.4,
          cursor: SystemMouseCursors.resizeDownRight,
          indicator: true,
          onDrag: (d) => widget.onResize(
            dRight: d.dx / widget.field.width,
            dBottom: d.dy / widget.field.height,
          ),
          onEnd: widget.onCommit,
        ),
        // 无边框窗口的浮动控制点：一个拖动把手 + 一个淡淡的 ×。
        // 做得很淡是刻意的——它压在内容上，抢眼就毁了"贴边全幅"的观感。
        //
        // **必须放在所有 _Edge 之后**：Stack 里后面的孩子先接触摸，
        // 右边缘和右上角的缩放热区（各 20 逻辑像素）正好压在这两个按钮上，
        // 放前面的话点 × 只会开始缩放窗口——按钮等于不存在。
        if (widget.chromeless)
          Positioned(
            right: 4,
            top: 4,
            child: Row(
              // Positioned 只给了 right/top，宽度是无界的：
              // 不收紧 mainAxisSize 会直接布局报错。
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) => widget.onMove(
                    d.delta.dx / widget.field.width,
                    d.delta.dy / widget.field.height,
                  ),
                  onPanEnd: (_) => widget.onCommit(),
                  child: const _GhostButton(icon: Icons.drag_indicator),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onClose,
                  child: const _GhostButton(icon: Icons.close_rounded),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 压在画布内容上的"幽灵按钮"：平时几乎看不见，按下去才亮一点。
class _GhostButton extends StatelessWidget {
  const _GhostButton({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.22),
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon,
        size: 15,
        color: Colors.white.withValues(alpha: 0.55),
      ),
    );
  }
}

class _Edge extends StatelessWidget {
  const _Edge({
    required this.alignment,
    required this.cursor,
    required this.onDrag,
    required this.onEnd,
    this.width,
    this.height,
    this.indicator = false,
  });

  final Alignment alignment;
  final MouseCursor cursor;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onEnd;
  final double? width;
  final double? height;
  final bool indicator;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: alignment,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => onDrag(d.delta),
          onPanEnd: (_) => onEnd(),
          child: SizedBox(
            // 未指定的一维要撑满，否则 SizedBox 在松约束下塌成 0，热区消失。
            width: width ?? double.infinity,
            height: height ?? double.infinity,
            child: indicator
                ? Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(
                      Icons.drag_handle,
                      size: 13,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _Hints extends StatelessWidget {
  const _Hints({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const items = [
      '看看最近失败的任务，读日志分析原因',
      '给面板装个 axios 依赖',
      '把某个环境变量改成新值',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '在任何页面按住内容 → 发给 AI，或直接问：',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in items)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(t, style: const TextStyle(fontSize: 11.5)),
                  onPressed: () => onPick(t),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniImage extends StatelessWidget {
  const _MiniImage({required this.image});

  final AiImageAttachment image;

  @override
  Widget build(BuildContext context) {
    final comma = image.dataUri.indexOf(',');
    final raw = comma >= 0 ? image.dataUri.substring(comma + 1) : image.dataUri;
    try {
      return Image.memory(
        base64Decode(raw),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
      );
    } catch (_) {
      return const Icon(Icons.broken_image_outlined);
    }
  }
}

class _MiniBubble extends StatefulWidget {
  const _MiniBubble({
    required this.isUser,
    required this.text,
    required this.outcome,
    this.images = const [],
    this.onResend,
    this.onRollback,
  });

  final bool isUser;
  final String text;
  final String outcome;
  final List<AiImageAttachment> images;

  /// 重发这条（会把它之后的对话删掉重来）。
  final VoidCallback? onResend;

  /// 只撤回，原话回到输入框。
  final VoidCallback? onRollback;

  @override
  State<_MiniBubble> createState() => _MiniBubbleState();
}

class _MiniBubbleState extends State<_MiniBubble> {
  /// 正在等第二下确认的那个动作（'resend' / 'rollback' / null）。
  ///
  /// 重发会删掉这条之后的对话，误触代价不小，所以要确认一次；但悬浮层里
  /// 不能用弹窗（会生在悬浮窗底下看不见），于是改成"点一下变确认、再点执行"，
  /// 3 秒没动作自动复位。
  String? _confirming;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  void _arm(String action, VoidCallback run) {
    if (_confirming == action) {
      _reset?.cancel();
      setState(() => _confirming = null);
      run();
      return;
    }
    _reset?.cancel();
    setState(() => _confirming = action);
    _reset = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _confirming = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = widget.isUser;
    final text = widget.text;
    final hasActions = isUser &&
        (widget.onResend != null || widget.onRollback != null) &&
        text.trim().isNotEmpty;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? scheme.primaryContainer.withValues(alpha: 0.85)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (widget.images.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final image in widget.images)
                      GestureDetector(
                        onTap: () => ImagePreviewOverlay.show(context, image),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 88,
                            height: 88,
                            child: _MiniImage(image: image),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (isUser)
              Text(
                text.length > 300 ? '${text.substring(0, 300)}…' : text,
                style: const TextStyle(fontSize: 12.5, height: 1.35),
              )
            else
              MarkdownMessage(text: text.isEmpty ? '_（无文字回复）_' : text),
            if (hasActions)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onResend != null)
                      _MiniAction(
                        icon: Icons.refresh_rounded,
                        label: _confirming == 'resend' ? '确认重发' : '重发',
                        hot: _confirming == 'resend',
                        onTap: () => _arm('resend', widget.onResend!),
                      ),
                    if (widget.onRollback != null) ...[
                      const SizedBox(width: 8),
                      _MiniAction(
                        icon: Icons.undo_rounded,
                        label: _confirming == 'rollback' ? '确认撤回' : '撤回',
                        hot: _confirming == 'rollback',
                        onTap: () => _arm('rollback', widget.onRollback!),
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
}

/// 气泡下面那种小号文字按钮。
class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.hot = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// 等确认状态：换成醒目色，用户知道再点一下就真的执行。
  final bool hot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = hot ? scheme.error : scheme.onPrimaryContainer;
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniConfirm extends StatelessWidget {
  const _MiniConfirm({
    required this.count,
    required this.irreversible,
    required this.names,
    required this.onConfirm,
    required this.onReject,
  });

  final int count;
  final bool irreversible;
  final String names;
  final VoidCallback onConfirm;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = irreversible ? scheme.error : scheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            irreversible ? '需要确认（含不可逆操作）' : '需要确认 $count 个写操作',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.bold,
              color: accent,
            ),
          ),
          const SizedBox(height: 2),
          Text(names, style: const TextStyle(fontSize: 11.5)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onReject,
                  child: const Text('拒绝'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: onConfirm,
                  style: irreversible
                      ? FilledButton.styleFrom(
                          backgroundColor: scheme.error,
                          foregroundColor: scheme.onError,
                        )
                      : null,
                  child: const Text('确认'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 快问的结果窗：无边框、可拖、可关、可按边缩放。
///
/// "无边"是用户要的形态：没有标题栏、没有工具条，就是一小块浮在屏幕上的字。
/// 所以拖动把手做成顶部一条看不见的热区（中间画一个很淡的短横提示可以拖），
/// 关闭和复制是右上角两个几乎透明的小点——不看它时它不存在，要用时手一伸就到。
class _QuickResultCard extends StatelessWidget {
  const _QuickResultCard({
    required this.win,
    required this.field,
    required this.onMove,
    required this.onResize,
    required this.onClose,
  });

  final QuickResultWindow win;
  final Size field;
  final void Function(double dx, double dy) onMove;
  final void Function({
    double dLeft,
    double dTop,
    double dRight,
    double dBottom,
  }) onResize;
  final VoidCallback onClose;

  /// 边缘热区。比聊天窗窄一点：这窗本来就小，太宽的话中间没地方滚动。
  static const _grip = 16.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: GlassPanel(
            radius: 18,
            blur: Glass.blurStrong,
            shadowY: 12,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                // 顶部：拖动区 + 问题回显 + 关闭/复制。
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) => onMove(
                    d.delta.dx / field.width,
                    d.delta.dy / field.height,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 6, 2),
                    child: Row(
                      children: [
                        Icon(
                          win.failed
                              ? Icons.error_outline
                              : Icons.drag_indicator,
                          size: 14,
                          color: win.failed
                              ? scheme.error
                              : scheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            win.question,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant
                                  .withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: win.answer));
                            final navContext = appNavigatorKey.currentContext;
                            if (navContext == null || !navContext.mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(navContext).showSnackBar(
                              const SnackBar(
                                content: Text('已复制'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          child: const _GhostButton(
                            icon: Icons.copy_all_outlined,
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onClose,
                          child: const _GhostButton(icon: Icons.close),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: SingleChildScrollView(
                      child: win.failed
                          ? Text(
                              win.answer,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.error,
                              ),
                            )
                          : MarkdownMessage(text: win.answer),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _Edge(
          alignment: Alignment.centerLeft,
          width: _grip,
          cursor: SystemMouseCursors.resizeLeftRight,
          onDrag: (d) => onResize(dLeft: d.dx / field.width),
          onEnd: () {},
        ),
        _Edge(
          alignment: Alignment.centerRight,
          width: _grip,
          cursor: SystemMouseCursors.resizeLeftRight,
          onDrag: (d) => onResize(dRight: d.dx / field.width),
          onEnd: () {},
        ),
        _Edge(
          alignment: Alignment.bottomCenter,
          height: _grip,
          cursor: SystemMouseCursors.resizeUpDown,
          onDrag: (d) => onResize(dBottom: d.dy / field.height),
          onEnd: () {},
        ),
      ],
    );
  }
}
