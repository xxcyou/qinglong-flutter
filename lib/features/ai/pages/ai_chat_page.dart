import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/formatter.dart';
import '../../../core/utils/error_text.dart';
import '../../browser/browser_engine.dart';
import '../models/ai_message.dart';
import '../models/ai_plan.dart';
import '../providers/chat_provider.dart';
import '../providers/audit_provider.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/local_file_picker.dart';
import '../floating/ai_dock_provider.dart';
import '../mcp/mcp_provider.dart';
import '../skills/skill_provider.dart';
import '../widgets/agent_process_card.dart';
import '../widgets/ai_canvas_sheet.dart';
import '../widgets/ai_composer.dart';
import '../widgets/agent_stream_card.dart';
import '../widgets/session_usage_chip.dart';
import '../widgets/ai_session_list.dart';
import '../widgets/ai_control_sheets.dart';
import '../widgets/ai_question_card.dart';
import '../widgets/particle_dissolve.dart';
import '../widgets/queue_strip.dart';
import 'mcp_server_page.dart';
import 'skill_list_page.dart';
import '../widgets/markdown_message.dart';
import '../../../shared/mono_text.dart';
import '../../terminal/pages/shell_files_page.dart';

class AiChatPage extends ConsumerStatefulWidget {
  const AiChatPage({super.key});

  @override
  ConsumerState<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends ConsumerState<AiChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  /// 是否跟着最新内容走。
  ///
  /// 默认跟随：回复一边流一边往下滚，用户不用一直手动拉到底。
  /// 但用户往上翻看历史时必须立刻停下——正在读旧消息却被拽回底部
  /// 比不自动滚更烦。判据是"离底部还有多远"，不是"有没有滑过"。
  bool _pinned = true;

  /// AI 页左侧半屏文件面板。
  bool _filePanelOpen = false;

  static const _filePanelFractionKey = 'ai_file_panel_fraction_v1';

  /// 面板宽度占屏幕比例，默认 2/3；可拖动右侧小白条在 0.4~0.95 间调整。
  /// 调好后会记住，下次滑出来还是这个大小。
  double _filePanelFraction = 0.66;

  /// 开始滑动的位置：从屏幕最左边缘滑会留给系统返回手势，避免误触。
  double _fileDragStartDx = -1;

  void _openFilePanel() => setState(() => _filePanelOpen = true);
  void _closeFilePanel() => setState(() => _filePanelOpen = false);

  Future<void> _loadFilePanelFraction() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_filePanelFractionKey);
      if (saved != null && saved >= 0.4 && saved <= 0.95 && mounted) {
        setState(() => _filePanelFraction = saved);
      }
    } catch (_) {
      // 记不住宽度不影响功能，用默认值继续。
    }
  }

  Future<void> _saveFilePanelFraction() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_filePanelFractionKey, _filePanelFraction);
    } catch (_) {
      // 忽略写入失败。
    }
  }

  /// 每条消息一个 RepaintBoundary key：撤回时按它抓图做消散。
  /// 用列表而不是 Map<int,GlobalKey>，因为索引就是消息在会话里的位置，
  /// 撤回只会从尾部截断，前面的 key 保持不变正好复用。
  final List<GlobalKey?> _bubbleKeys = [];

  final _listKey = GlobalKey();

  GlobalKey _bubbleKeyAt(int index) {
    while (_bubbleKeys.length <= index) {
      _bubbleKeys.add(null);
    }
    return _bubbleKeys[index] ??= GlobalKey();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadFilePanelFraction();
    Future.microtask(() async {
      await ref.read(chatProvider.notifier).loadSessions();
      // 会话读完再看有没有被打断的运行：恢复要切到原会话，顺序反了会切错。
      await ref.read(chatProvider.notifier).loadInterruptedRun();
      // 只读缓存，不发请求：模型列表在设置页手动获取一次就够了。
      ref.read(chatProvider.notifier).loadCachedModels();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // 160 逻辑像素的容差：手指刚好停在最后一条上也算"在底部"。
    final atBottom = pos.maxScrollExtent - pos.pixels <= 160;
    if (atBottom != _pinned) setState(() => _pinned = atBottom);
  }

  /// 内容变了就跟到底。用 jumpTo 而不是动画：流式回复每秒改好几次
  /// state，动画会互相打断，看起来一顿一顿的。
  void _followTail() {
    if (!_pinned) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if ((max - _scrollController.position.pixels).abs() < 1) return;
      _scrollController.jumpTo(max);
    });
  }

  /// 撤回：把被删掉的那几条"炸"掉，再把原话放回输入框。
  ///
  /// 顺序很讲究——必须先抓图，再改数据。数据一改，ListView 立刻把那些条目
  /// 卸载掉，RenderObject 没了就什么都抓不到，只能看到一次生硬的跳变。
  Future<void> _rollbackTo(int index) async {
    final notifier = ref.read(chatProvider.notifier);
    final keys = <GlobalKey>[];
    for (var i = index; i < _bubbleKeys.length; i++) {
      final key = _bubbleKeys[i];
      if (key != null) keys.add(key);
    }
    final pieces = await captureDissolvePieces(keys);
    // 粒子关在列表区里：飘到标题栏或输入框上面就露馅了。
    final listBox = _listKey.currentContext?.findRenderObject();
    Rect? clip;
    if (listBox is RenderBox && listBox.hasSize) {
      clip = listBox.localToGlobal(Offset.zero) & listBox.size;
    }
    if (!mounted) {
      for (final piece in pieces) {
        piece.image.dispose();
      }
      return;
    }
    playDissolve(context, pieces, clip: clip);
    final text = notifier.rollbackTo(index);
    // 撤回的本意基本都是"这句我想重新说"，所以原话直接回到输入框，
    // 用户改两个字就能再发，不用自己复制粘贴。
    if (text.trim().isNotEmpty) {
      _controller.text = text;
      _controller.selection = TextSelection.collapsed(offset: text.length);
    }
    _pinned = true;
    _followTail();
  }

  void _send() {
    final dock = ref.read(aiDockProvider.notifier);
    // 附件（本地文件、页面自动带上来的日志）要拼进提问里，
    // 和悬浮窗走同一个 composePrompt，两边行为一致。
    final prompt = dock.composePrompt(_controller.text);
    if (prompt.trim().isEmpty) return;
    _controller.clear();
    dock.consumeChips();
    // 自己发的消息一定要看到，所以先强制恢复跟随。
    _pinned = true;
    ref.read(chatProvider.notifier).send(prompt);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  /// 挑一个本地文件当附件。
  Future<void> _pickFile() async {
    final picked = await LocalFilePicker.pick(context);
    if (picked == null || !mounted) return;
    final label = ref.read(aiDockProvider.notifier).pushFile(
          path: picked.path,
          name: picked.name,
          content: picked.content,
          language: picked.language,
          truncated: picked.truncated,
          // 这里已经在聊天界面了，别再把悬浮窗弹出来盖住它。
          open: false,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已附上 $label'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Widget _buildTail(BuildContext context, ChatState state) {
    // 提问优先于计划确认：模型问了话，先把话答上，别让两张卡片抢地方。
    final question = state.pendingQuestion;
    if (question != null) {
      return AiQuestionCard(
        // key 跟着提问号走：同一句话问第二遍时也会重建，不会继承"已回答"。
        key: ValueKey('q${question.id}'),
        question: question,
        onAnswer: (answer) {
          ref.read(chatProvider.notifier).send(answer);
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _scrollToBottom());
        },
      );
    }
    if (state.pendingPlan.isNotEmpty) {
      final notifier = ref.read(chatProvider.notifier);
      return _PlanConfirmCard(
        plan: state.pendingPlan,
        onConfirm: notifier.confirmPlan,
        onReject: notifier.rejectPlan,
      );
    }
    return const SizedBox.shrink();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _showSessionManager() => AiSessionList.showSheet(context);

  void _showAudit() {
    ref.read(auditProvider.notifier).load();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final audit = ref.watch(auditProvider);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            final logs = audit.logs;
            return Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'AI / QL 操作审计',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Expanded(
                  child: logs.isEmpty
                      ? const Center(child: Text('暂无审计记录'))
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: logs.length,
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                          itemBuilder: (context, index) {
                            final log = logs[index];
                            return Card(
                              child: ListTile(
                                title: Text('${log.action} · ${log.result}'),
                                subtitle: Text('${log.module}｜${log.detail}'),
                                trailing: Text(
                                  '${log.time.hour.toString().padLeft(2, '0')}:${log.time.minute.toString().padLeft(2, '0')}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 消息新增、流式回复变长、工具时间线增加，都要跟到底。
    ref.listen<ChatState>(chatProvider, (previous, next) {
      if (previous == null) return;
      final changed = previous.messages.length != next.messages.length ||
          previous.liveAgentEvents.length != next.liveAgentEvents.length ||
          previous.messages.lastOrNull?.content.length !=
              next.messages.lastOrNull?.content.length ||
          previous.pendingQuestion != next.pendingQuestion ||
          previous.pendingPlan.length != next.pendingPlan.length;
      // 流式文字每 80ms 长一截。它只让最后那张卡内部变高，
      // 卡自己会贴着底显示最新一行，这里只需要把列表跟到底。
      final streaming =
          previous.liveReasoningChars != next.liveReasoningChars ||
              previous.liveContentChars != next.liveContentChars ||
              previous.liveTool != next.liveTool;
      if (changed || streaming) _followTail();
    });
    final state = ref.watch(chatProvider);
    final notifier = ref.read(chatProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    // 附件与悬浮窗共用一份：composePrompt 也只认这一份。
    // 只订阅 chips：整份 dock state 里还有悬浮球坐标，拖球时会每帧变，
    // 照它重建的话整个 AI 页跟着一帧一次重绘。
    final chips = ref.watch(aiDockProvider.select((s) => s.chips));

    final mcpCount = ref.watch(mcpProvider).tools.length;
    final skillCount = ref.watch(skillProvider).enabled.length;

    return Stack(
      children: [
        GestureDetector(
          // 半屏文件面板：右滑打开，再左滑收起；面板打开时不挡右侧聊天区。
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (details) {
            _fileDragStartDx = details.globalPosition.dx;
          },
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            // 从屏幕最左边沿开始的手势让给系统返回；离边稍远再右滑才开面板。
            if (!_filePanelOpen && velocity > 300 && _fileDragStartDx > 60) {
              _openFilePanel();
            }
            if (_filePanelOpen && velocity < -300) _closeFilePanel();
          },
          child: GlassScaffold(
            title: 'AI 助手',
            subtitle: [
              state.selectedModel.isEmpty ? '未选择模型' : state.selectedModel,
              if (skillCount > 0) '$skillCount 技能',
              if (mcpCount > 0) '$mcpCount MCP 工具',
            ].join(' · '),
            actions: [
              // 会话用量：贴着浏览器按钮左边，半透明、不抢戏，但一直在动。
              const Padding(
                padding: EdgeInsets.only(right: 2),
                child: SessionUsageChip(),
              ),
              // 浏览器入口：常驻内核，点开就是个正常浏览器（悬浮窗，可拖可缩放）。
              // 登录、Cloudflare 人机验证都在这里手动点掉——AI 用的是同一个内核，
              // 所以你验证过一次，它后面调接口就一直带着票。
              ValueListenableBuilder<bool>(
                valueListenable: BrowserEngine.instance.visible,
                builder: (context, visible, _) => IconButton(
                  tooltip: visible ? '浏览器已打开' : '打开浏览器（登录 / 过人机验证）',
                  onPressed: () => visible
                      ? BrowserEngine.instance.hide()
                      : BrowserEngine.instance.show(),
                  icon: Icon(
                    visible ? Icons.public : Icons.public_outlined,
                    color: visible ? scheme.primary : null,
                  ),
                ),
              ),
              IconButton(
                tooltip: '会话列表',
                onPressed: _showSessionManager,
                icon: const Icon(Icons.forum_outlined),
              ),
              IconButton(
                tooltip: '审计记录',
                onPressed: _showAudit,
                icon: const Icon(Icons.receipt_long_outlined),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'approval':
                      AiControlSheets.showApproval(context);
                    case 'context':
                      AiControlSheets.showContext(context, ref);
                    case 'skills':
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SkillListPage()),
                      );
                    case 'mcp':
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const McpServerPage()),
                      );
                    case 'new':
                      notifier.createSession();
                    case 'clear':
                      notifier.clear();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'approval',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.verified_user_outlined),
                      title: const Text('确认策略'),
                      subtitle: Text(state.approvalMode.label),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'context',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.data_usage_outlined),
                      title: Text('上下文与压缩'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'skills',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.auto_stories_outlined),
                      title: const Text('技能库'),
                      subtitle: Text('$skillCount 个已启用'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'mcp',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.extension_outlined),
                      title: const Text('MCP 扩展'),
                      subtitle: Text(mcpCount == 0 ? '未接入' : '$mcpCount 个工具'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'new',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.add_comment_outlined),
                      title: Text('新建会话'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'clear',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_sweep_outlined),
                      title: Text('清空当前会话'),
                    ),
                  ),
                ],
              ),
            ],
            body: Column(
              children: [
                Expanded(
                  child: state.messages.isEmpty
                      ? _WelcomeView(
                          onTap: (text) {
                            // 走 _send 而不是直接 send：不然示例问句会把已挂的附件丢掉。
                            _controller.text = text;
                            _send();
                          },
                        )
                      : Builder(
                          builder: (context) {
                            final hasLive = state.liveAgentEvents.isNotEmpty;
                            final hasLivePlan = state.livePlan.isNotEmpty;
                            // 请求已发出但一个字都还没回来时也占一格：那正是最需要
                            // "它在动"这个信号的几秒钟。
                            final hasStream = state.isLoading;
                            final extraCount = (hasLivePlan ? 1 : 0) +
                                (hasLive ? 1 : 0) +
                                (hasStream ? 1 : 0) +
                                1;
                            return ListView.builder(
                              key: _listKey,
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                              itemCount: state.messages.length + extraCount,
                              itemBuilder: (context, index) {
                                if (index < state.messages.length) {
                                  return RepaintBoundary(
                                    key: _bubbleKeyAt(index),
                                    child: _MessageBubble(
                                      message: state.messages[index],
                                      onResend: state.isLoading
                                          ? null
                                          : () => notifier.resendAt(index),
                                      onRollback: state.isLoading
                                          ? null
                                          : () => _rollbackTo(index),
                                    ),
                                  );
                                }
                                var slot = index - state.messages.length;
                                if (hasLivePlan) {
                                  if (slot == 0) {
                                    // 下面紧跟过程卡（它只有 bottom margin），
                                    // 所以这里必须自己留下边距，否则两张卡贴在一起。
                                    return TaskPlanCard(
                                      plan: state.livePlan,
                                      margin: const EdgeInsets.only(bottom: 8),
                                    );
                                  }
                                  slot -= 1;
                                }
                                if (hasLive) {
                                  if (slot == 0) {
                                    return AgentProcessCard(
                                      events: state.liveAgentEvents,
                                      running: state.isLoading,
                                      initiallyExpanded: state.isLoading,
                                      totalTokens: state.lastTokens,
                                    );
                                  }
                                  slot -= 1;
                                }
                                if (hasStream && slot == 0) {
                                  return AgentStreamCard(
                                    reasoning: state.liveReasoning,
                                    content: state.liveContent,
                                    reasoningChars: state.liveReasoningChars,
                                    contentChars: state.liveContentChars,
                                    tool: state.liveTool,
                                  );
                                }
                                return _buildTail(context, state);
                              },
                            );
                          },
                        ),
                ),
                // 往上翻过就出现这个按钮：不用一路滑回去。
                if (!_pinned && state.messages.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 0, 14, 6),
                      child: GlassPill(
                        icon: Icons.arrow_downward_rounded,
                        label: state.isLoading ? '跟随最新' : '回到最新',
                        color: scheme.primary,
                        dense: true,
                        onTap: () {
                          setState(() => _pinned = true);
                          _scrollToBottom();
                        },
                      ),
                    ),
                  ),
                // 错误条只在"错误没能挂到某条消息上"时才出现（比如拉模型列表失败）。
                // 发送失败已经在那条用户消息下面标红了，两处都画等于报两次错。
                if (state.error != null &&
                    !(state.currentSession?.messages
                            .any((m) => m.failedToSend) ??
                        false))
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline,
                            size: 17, color: scheme.onErrorContainer),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            errorText(state.error!),
                            style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onErrorContainer,
                            ),
                            maxLines: 3,
                          ),
                        ),
                      ],
                    ),
                  ),
                // "AI 在等你回答"常驻条：提问卡在列表末尾，用户往上翻就看不见了，
                // 而这时候不答任务就一直挂着。点一下跳到那张卡。
                if (state.pendingQuestion != null && !_pinned)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        setState(() => _pinned = true);
                        _scrollToBottom();
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.help_outline,
                                size: 16, color: scheme.primary),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'AI 在等你回答：${state.pendingQuestion!.question}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                            Icon(Icons.arrow_downward_rounded,
                                size: 15, color: scheme.primary),
                          ],
                        ),
                      ),
                    ),
                  ),
                // 清单常驻在输入框上方：跑长任务时不用往上翻就知道到第几步。
                if (state.livePlan.isNotEmpty)
                  TaskPlanStrip(plan: state.livePlan, running: state.isLoading),
                if (state.interruptedRun != null)
                  ResumeStrip(
                    run: state.interruptedRun!,
                    onResume: notifier.resumeInterruptedRun,
                    onDiscard: notifier.discardInterruptedRun,
                  ),
                QueueStrip(
                  queue: state.queue,
                  onReorder: notifier.reorderQueue,
                  onRemove: notifier.dequeue,
                  onInterruptSend: notifier.interruptAndSend,
                ),
                // 附件条。用的是悬浮窗那份 chips：两边共享同一个会话，
                // 附件当然也得是同一份，否则在这里加的附件发出去不带上。
                if (chips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (var i = 0; i < chips.length; i++)
                            InputChip(
                              visualDensity: VisualDensity.compact,
                              avatar: Icon(
                                chips[i].readOnly
                                    ? Icons.visibility_outlined
                                    : Icons.attachment,
                                size: 14,
                              ),
                              label: Text(
                                chips[i].label,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              onDeleted: () => ref
                                  .read(aiDockProvider.notifier)
                                  .removeChip(i),
                            ),
                        ],
                      ),
                    ),
                  ),
                // 不用 SafeArea：它会照系统小白条的完整高度（这台机 ~48px）
                // 往上垫一整条，输入框下面就空出一条谁也用不上的带子。
                // 手势条本身是半透明浮层，压在它上面并不影响操作，
                // 所以只留它的 1/4 作为呼吸位。
                Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.paddingOf(context).bottom * 0.25,
                  ),
                  child: AiComposer(
                    state: state,
                    controller: _controller,
                    onSend: _send,
                    onStop: notifier.stopAgent,
                    onModelTap: () => AiControlSheets.showModelPicker(context),
                    onStrengthTap: () => AiControlSheets.showStrength(context),
                    onContextTap: () =>
                        AiControlSheets.showContext(context, ref),
                    onApprovalTap: () => AiControlSheets.showApproval(context),
                    onAttach: _pickFile,
                  ),
                ),
              ],
            ),
          ),
        ),
        _buildFilePanel(),
      ],
    );
  }

  /// 左侧半屏文件管理面板：右滑出来、左滑/右上角收起。
  /// 点击文本/代码文件时用悬浮编辑器打开，不离开 AI 页面。
  Widget _buildFilePanel() {
    final size = MediaQuery.sizeOf(context);
    final scheme = Theme.of(context).colorScheme;
    final panelWidth = size.width * _filePanelFraction;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      left: _filePanelOpen ? 0 : -panelWidth - 12,
      top: 0,
      bottom: 0,
      width: panelWidth,
      child: Material(
        color: Colors.transparent,
        child: ClipRRect(
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(20),
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(
                sigmaX: Glass.blurStrong, sigmaY: Glass.blurStrong),
            child: Container(
              color: scheme.surface.withValues(alpha: 0.96),
              child: Stack(
                children: [
                  // 左滑收回的范围包含整个已经展开的半屏，不只在右边缝上触发。
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragEnd: (details) {
                      if ((details.primaryVelocity ?? 0) < -300) {
                        _closeFilePanel();
                      }
                    },
                    child: ShellFilesPage(
                      asSheet: true,
                      floatingEditor: true,
                      onClose: _closeFilePanel,
                      closeIcon: Icons.arrow_back_ios_new_rounded,
                    ),
                  ),
                  // 右缘中间的小白条：按住左右拉可改面板宽度，松开固定。
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Align(
                      alignment: Alignment.center,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: (_) {
                          HapticFeedback.lightImpact();
                        },
                        onHorizontalDragUpdate: (details) {
                          final delta = details.delta.dx / size.width;
                          setState(() {
                            _filePanelFraction =
                                (_filePanelFraction + delta).clamp(0.4, 0.95);
                          });
                        },
                        onHorizontalDragEnd: (_) {
                          HapticFeedback.selectionClick();
                          _saveFilePanelFraction();
                        },
                        child: Container(
                          width: 5,
                          height: 76,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(3),
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
    );
  }
}

class _WelcomeView extends StatelessWidget {
  const _WelcomeView({required this.onTap});

  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const examples = <(IconData, String, String)>[
      (Icons.list_alt_outlined, '看看现在有哪些任务', '现在有哪些任务？分别多久跑一次'),
      (Icons.bug_report_outlined, '排查某个任务为什么失败', '帮我看看最近失败的任务，读日志分析原因'),
      (Icons.code_outlined, '写个签到脚本并建任务', '帮我写个脚本每天 8 点签到，并创建对应定时任务'),
      (
        Icons.terminal_outlined,
        '在本机 Debian 里跑命令',
        '在本机 Debian 里看看 python 版本和 /workspace 有什么'
      ),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 12),
      children: [
        Center(
          child: Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.smart_toy_outlined,
              size: 32,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Center(
          child: Text(
            '青龙专用 AI 助手',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            '会自己查证再回答，改东西之前按策略征求你的同意',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 24),
        for (final (icon, title, prompt) in examples)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              // 半透：背景那三团流动的光斑要能透过示例卡。
              color: scheme.surfaceContainerLow.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onTap(prompt),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(icon, size: 19, color: scheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              prompt,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.north_west,
                        size: 15,
                        color: scheme.onSurfaceVariant,
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
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.onResend,
    this.onRollback,
  });

  final AiChatMessage message;

  /// 重发这条（撤回到它之前再重新问一次）。
  final VoidCallback? onResend;

  /// 只撤回，不重发。
  final VoidCallback? onRollback;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final scheme = Theme.of(context).colorScheme;
    final footer = _footer();

    final bubble = Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * (isUser ? 0.82 : 0.92),
        ),
        decoration: BoxDecoration(
          color: isUser ? scheme.primaryContainer : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          border: isUser
              ? null
              : Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isUser)
              SelectableText(
                message.content,
                style: TextStyle(
                  height: 1.4,
                  color: scheme.onPrimaryContainer,
                ),
              )
            else
              MarkdownMessage(
                text: message.content.isEmpty ? '_（无文字回复）_' : message.content,
              ),
            // 用户消息的操作按钮直接摆出来。
            // 长按行不通：SelectableText 会把长按吃掉去做文字选择，
            // 手势竞争里外层的 GestureDetector 拿不到事件。
            if (isUser && (onResend != null || onRollback != null))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onResend != null)
                      _BubbleAction(
                        icon: Icons.refresh,
                        label: '重发',
                        color: scheme.onPrimaryContainer,
                        onTap: () => _confirmResend(context),
                      ),
                    if (onRollback != null) ...[
                      const SizedBox(width: 10),
                      _BubbleAction(
                        icon: Icons.undo,
                        label: '撤回到这里',
                        color: scheme.onPrimaryContainer,
                        onTap: () => _confirmRollback(context),
                      ),
                    ],
                  ],
                ),
              ),
            if (!isUser && footer.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(
                      _footerIcon(),
                      size: 12.5,
                      color: _failed() ? scheme.error : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        footer,
                        style: TextStyle(
                          fontSize: 11,
                          color: _failed()
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (onResend != null) ...[
                      InkWell(
                        onTap: () => _confirmResend(context),
                        child: Icon(
                          Icons.refresh,
                          size: 15,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    if (onRollback != null) ...[
                      InkWell(
                        onTap: () => _confirmRollback(context),
                        child: Icon(
                          Icons.undo,
                          size: 15,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    InkWell(
                      onTap: () {
                        Clipboard.setData(
                          ClipboardData(text: message.content),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已复制回复'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      child: Icon(
                        Icons.copy_rounded,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );

    final interactive = bubble;

    if (isUser) {
      // 没发出去的那条：气泡下面一行红字，说清"这句没送到"和为什么。
      // 它不是 AI 的回复，所以不做成气泡；也不进上下文（见 sendError 注释）。
      if (!message.failedToSend) return interactive;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          interactive,
          _SendErrorLine(
            error: message.sendError,
            onRetry: onResend,
          ),
          // 断线前已经跑过的工具留在这里：多轮任务中途失败时，
          // 用户要能看到"断在哪一步"。
          if (message.agentEvents.isNotEmpty)
            AgentProcessCard(
              events: message.agentEvents,
              turns: message.turns,
              totalTokens: message.totalTokens,
            ),
        ],
      );
    }
    final hasExtras = message.agentEvents.isNotEmpty ||
        message.taskPlan.isNotEmpty ||
        message.canvases.isNotEmpty;
    if (!hasExtras) return interactive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.agentEvents.isNotEmpty)
          AgentProcessCard(
            events: message.agentEvents,
            turns: message.turns,
            totalTokens: message.totalTokens,
          ),
        if (message.taskPlan.isNotEmpty)
          TaskPlanCard(
            plan: message.taskPlan,
            // 清单卡默认 top:8，但它上面是过程卡（自带 bottom:8）或直接是
            // 列表边缘，两边一起算就成了 16 的空档。这里只留下边距。
            margin: const EdgeInsets.only(bottom: 8),
          ),
        interactive,
        // 弹窗关了内容不会丢：这些卡片一直在，点一下重新打开。
        //
        // margin 必须显式给：默认的 top:8 是"卡在气泡上方"时的间距，
        // 而这里卡在气泡**下方**——气泡自己的 bottom:10 已经把位置占了，
        // 再叠 top:8 反而让卡片贴着下一条用户消息（就是"重叠/贴边"的来源）。
        for (final canvas in message.canvases)
          AiCanvasCard(
            canvas: canvas,
            margin: const EdgeInsets.only(bottom: 10),
          ),
      ],
    );
  }

  /// 重发前确认：它会把这条之后的对话全部删掉重来，属于不可撤销的显示层操作。
  Future<void> _confirmResend(BuildContext context) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                '重新发送这条？',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '会先撤回这条之后的所有对话，再按原内容重新问一次。'
                '面板上已经执行过的改动不会跟着回滚。',
                style: TextStyle(fontSize: 12.5),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('确认重发'),
              onTap: () => Navigator.of(context).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
    if (ok == true) onResend?.call();
  }

  Future<void> _confirmRollback(BuildContext context) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Text(
                '撤回到这条之前？这条及之后的对话会被删除，'
                '面板上已执行的改动不会回滚。',
                style: TextStyle(fontSize: 13),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.undo),
              title: const Text('确认撤回'),
              onTap: () => Navigator.of(context).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
    if (ok == true) onRollback?.call();
  }

  bool _failed() =>
      message.outcome == 'failed' || message.outcome == 'cancelled';

  IconData _footerIcon() => switch (message.outcome) {
        'failed' => Icons.error_outline,
        'cancelled' => Icons.stop_circle_outlined,
        'exhausted' => Icons.hourglass_empty,
        'awaitingConfirm' => Icons.pan_tool_outlined,
        'awaitingInput' => Icons.help_outline,
        _ => Icons.check_circle_outline,
      };

  static String _kilo(int value) => Formatter.tokens(value);

  String _footer() {
    final parts = <String>[];
    switch (message.outcome) {
      case 'failed':
        parts.add('任务失败');
      case 'cancelled':
        parts.add('已中断');
      case 'exhausted':
        parts.add('未确认完成');
      case 'awaitingConfirm':
        parts.add('等待确认');
      case 'completed':
        // 普通一问一答不写"已完成"：那是给多步任务看的状态，
        // 贴在每句闲聊下面像流水线打卡。
        if (message.toolCalls.isNotEmpty) parts.add('已完成');
    }
    if (message.turns > 1) parts.add('${message.turns} 轮');
    // 两个数字含义不同，必须分开写清楚，否则"十几万 token"看着莫名其妙：
    // 计费 = 每轮重发历史的累计量；上下文 = 最后一轮真实占用。
    if (message.totalTokens > 0) parts.add('计费 ${_kilo(message.totalTokens)}');
    final contextTokens = Formatter.serverContextTokens(
        message.promptTokens, message.cachedTokens);
    if (contextTokens > 0) {
      parts.add('上下文 ${_kilo(contextTokens)}');
    }
    if (message.cachedTokens > 0 && contextTokens > 0) {
      final rate =
          (message.cachedTokens / contextTokens * 100).round().clamp(0, 100);
      parts.add('缓存命中 $rate%');
    }
    return parts.join(' · ');
  }
}

class _PlanConfirmCard extends StatelessWidget {
  const _PlanConfirmCard({
    required this.plan,
    required this.onConfirm,
    required this.onReject,
  });

  final List<AiPlanAction> plan;
  final VoidCallback onConfirm;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasIrreversible = plan.any((a) => !a.reversible);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: hasIrreversible ? scheme.error : scheme.primary,
          width: 1.2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            color: (hasIrreversible ? scheme.error : scheme.primary)
                .withValues(alpha: 0.10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  hasIrreversible
                      ? Icons.warning_amber_rounded
                      : Icons.pan_tool_outlined,
                  size: 17,
                  color: hasIrreversible ? scheme.error : scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hasIrreversible
                        ? '需要你确认（含不可逆操作）'
                        : '需要你确认这 ${plan.length} 个写操作',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: hasIrreversible ? scheme.error : scheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final action in plan)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color:
                          scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                action.type,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontFamily: kMonoFamily,
                                  fontFamilyFallback: kMonoFallback,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: action.reversible
                                    ? scheme.secondaryContainer
                                    : scheme.errorContainer,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                action.reversible ? '可逆' : '不可逆',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.bold,
                                  color: action.reversible
                                      ? scheme.onSecondaryContainer
                                      : scheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (action.target.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '对象：${action.target}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        if (action.impact.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '影响：${action.impact}',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onReject,
                        icon: const Icon(Icons.close, size: 17),
                        label: const Text('拒绝'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onConfirm,
                        style: hasIrreversible
                            ? FilledButton.styleFrom(
                                backgroundColor: scheme.error,
                                foregroundColor: scheme.onError,
                              )
                            : null,
                        icon: const Icon(Icons.check, size: 17),
                        label: const Text('确认执行'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 气泡里的一颗小操作按钮（图标 + 文字）。
/// "这条没发出去"的红字行。
///
/// 刻意做成裸文字而不是气泡：气泡意味着"有人说了话"，而这里恰恰是**没人说话**
/// ——请求连模型都没到。旁边给一个重发入口，点了就按原文重问一次。
class _SendErrorLine extends StatelessWidget {
  const _SendErrorLine({required this.error, this.onRetry});

  final String error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 40, right: 2, bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(Icons.error_outline_rounded, size: 14, color: scheme.error),
          const SizedBox(width: 5),
          Flexible(
            child: SelectableText(
              '未发送成功：$error',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: scheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onRetry,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.refresh_rounded, size: 13, color: scheme.error),
                    const SizedBox(width: 2),
                    Text(
                      '重试',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BubbleAction extends StatelessWidget {
  const _BubbleAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color.withValues(alpha: 0.75)),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                color: color.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
