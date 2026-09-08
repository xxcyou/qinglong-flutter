import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/llm/llm_client.dart';
import '../../../core/llm/llm_config_provider.dart';
import '../../../core/llm/llm_provider.dart';
import '../../../core/network/error_handler.dart';
import '../../../core/local_shell/proot_bridge.dart';
import '../../../core/local_shell/shell_lock.dart';
import '../../../core/utils/logger.dart';
import '../../../router.dart';
import '../../panels/providers/panel_list_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../agent/agent_loop.dart';
import '../agent/agent_team.dart';
import '../agent/external_tool.dart';
import '../agent/mcp_gateway.dart';
import '../../browser/browser_tools.dart';
import '../../editor/editor_tools.dart';
import '../../../shared/editor_bus.dart';
import '../agent/meta_tools.dart';
import '../agent/qinglong_skill.dart';
import '../agent/tool_registry.dart';
import '../mcp/mcp_provider.dart';
import '../memory/memory_provider.dart';
import '../skills/skill_models.dart';
import '../skills/skill_provider.dart';
import '../models/ai_message.dart';
import '../models/agent_event.dart';
import '../models/agent_task_plan.dart';
import '../models/approval_mode.dart';
import '../models/ai_plan.dart';
import '../models/audit_log.dart';
import '../models/chat_runtime.dart';
import '../models/tool_call_record.dart';
import '../../browser/browser_engine.dart';
import '../floating/ai_dock_provider.dart';
import '../../home/home_navigation_provider.dart';
import '../widgets/ai_canvas_sheet.dart';
import 'audit_provider.dart';

class ChatState {
  const ChatState({
    this.sessions = const [],
    this.currentSessionId = 'default',
    this.availableModels = const [],
    this.isLoadingModels = false,
    this.modelsError,
    this.selectedModel = '',
    this.reasoningEffort = 0,
    this.approvalMode = AiApprovalMode.cautious,
    this.autoCompressThreshold = 0.8,
    this.modelContextLimits = const {},
    this.modelTestResults = const {},
    this.testingModel,
    this.liveAgentEvents = const [],
    this.liveReasoning = '',
    this.liveContent = '',
    this.liveContentFull = '',
    this.liveReasoningChars = 0,
    this.liveContentChars = 0,
    this.liveTool = '',
    this.livePlan = const AgentTaskPlan(),
    this.toolRecords = const [],
    this.pendingPlan = const [],
    this.pendingQuestion,
    this.queue = const [],
    this.interruptedRun,
    this.lastPromptTokens = 0,
    this.lastCacheHitTokens = 0,
    this.isLoading = false,
    this.lastTurns = 0,
    this.lastTokens = 0,
    this.error,
  });

  final List<AiSession> sessions;
  final String currentSessionId;
  final List<String> availableModels;
  final bool isLoadingModels;

  /// 自动获取模型的失败原因（成功时为 null），用于在模型弹窗里直说哪一步挂了。
  final String? modelsError;
  final String selectedModel;
  final int reasoningEffort;

  /// 写操作确认策略。
  final AiApprovalMode approvalMode;
  final double autoCompressThreshold;
  final Map<String, int> modelContextLimits;
  final Map<String, bool?> modelTestResults;
  final String? testingModel;
  final List<AgentEvent> liveAgentEvents;

  /// 正在流出来的思考（reasoning_content）。冒多少显示多少，
  /// 这一轮结束就清空——那时它已经变成 [liveAgentEvents] 里的一条思考事件。
  final String liveReasoning;

  /// 正在流出来的正文。
  final String liveContent;

  /// 正在流出来的正文**全文**。
  ///
  /// [liveContent] 出于性能只留尾部 6000 字；快问正文悬浮窗要显示整段内容，
  /// 所以快问运行时这里多存一份完整正文。非快问轮次保持空，不白费内存。
  final String liveContentFull;

  /// 思考/正文的**真实**字数。
  ///
  /// [liveReasoning] 出于性能只留尾部 6000 字，所以它的 length 会卡在 6001
  /// 不再涨——界面上"思考 6001 字"看着像模型停了，其实还在写。字数一律读这两个。
  final int liveReasoningChars;
  final int liveContentChars;

  /// 模型这一轮刚开口要调的工具名（参数还没收完就先报出来）。
  final String liveTool;

  /// 这一轮有没有正在流的内容。
  bool get hasLiveStream =>
      liveReasoning.isNotEmpty || liveContent.isNotEmpty || liveTool.isNotEmpty;

  /// 正在跑的这一轮的任务清单：AI 每更新一步，界面上的勾就动一下。
  final AgentTaskPlan livePlan;
  final List<ToolCallRecord> toolRecords;
  final List<AiPlanAction> pendingPlan;

  /// 模型正在等用户回答的问题（ask_user）。非空时聊天页显示提问卡片。
  final AgentQuestion? pendingQuestion;

  /// 排队待发的消息：AI 还在跑时用户继续输入，先排队，跑完自动依次发出。
  final List<QueuedMessage> queue;

  /// 上次被闪退/杀进程打断的运行，可在界面上一键继续。
  final InterruptedRun? interruptedRun;

  /// 上一轮真实的 prompt_tokens（上下文实际占用），与累计计费量区分。
  final int lastPromptTokens;

  /// 上一轮命中提示词缓存的 token 数。
  final int lastCacheHitTokens;
  final bool isLoading;

  /// 上一次 Agent 运行的轮次与 token 消耗，用于界面上做成本提示。
  final int lastTurns;
  final int lastTokens;
  final Object? error;

  List<AiChatMessage> get messages {
    for (final session in sessions) {
      if (session.id == currentSessionId) return session.messages;
    }
    return const [];
  }

  AiSession? get currentSession {
    for (final session in sessions) {
      if (session.id == currentSessionId) return session;
    }
    return null;
  }

  int get contextLimit => selectedModel.isEmpty
      ? 8000
      : (modelContextLimits[selectedModel] ?? 8000);

  /// 本会话累计计费 token。
  ///
  /// 每条 assistant 消息带着那一次运行的 usage.totalTokens，累加就是"这个会话
  /// 一共花了多少"。注意它必然远大于上下文占用：每一轮都要重发全部历史。
  int get sessionTokens {
    var sum = 0;
    for (final m in messages) {
      sum += m.totalTokens;
    }
    return sum;
  }

  /// 本会话请求次数。
  ///
  /// 一"轮"就是一次发给模型的请求（工具调用会多跑几轮），所以把每次运行的
  /// 轮数加起来才是真实请求数——按消息条数算会少算一大截。
  int get sessionRequests {
    var sum = 0;
    for (final m in messages) {
      sum += m.turns;
    }
    return sum;
  }

  /// 正在跑的这一轮是第几轮（没在跑就是 0）。界面用它做"运行中也在涨"的动态统计。
  int get liveTurn {
    if (!isLoading) return 0;
    for (final e in liveAgentEvents.reversed) {
      if (e.turn > 0) return e.turn;
    }
    return 1;
  }

  ChatState copyWith({
    List<AiSession>? sessions,
    String? currentSessionId,
    List<String>? availableModels,
    bool? isLoadingModels,
    String? modelsError,
    bool clearModelsError = false,
    String? selectedModel,
    int? reasoningEffort,
    AiApprovalMode? approvalMode,
    double? autoCompressThreshold,
    Map<String, int>? modelContextLimits,
    Map<String, bool?>? modelTestResults,
    String? testingModel,
    List<AgentEvent>? liveAgentEvents,
    String? liveReasoning,
    String? liveContent,
    String? liveContentFull,
    int? liveReasoningChars,
    int? liveContentChars,
    String? liveTool,
    bool clearLiveText = false,
    AgentTaskPlan? livePlan,
    List<ToolCallRecord>? toolRecords,
    List<AiPlanAction>? pendingPlan,
    AgentQuestion? pendingQuestion,
    bool clearPendingQuestion = false,
    List<QueuedMessage>? queue,
    InterruptedRun? interruptedRun,
    bool clearInterruptedRun = false,
    int? lastPromptTokens,
    int? lastCacheHitTokens,
    bool? isLoading,
    int? lastTurns,
    int? lastTokens,
    Object? error,
    bool clearError = false,
  }) {
    return ChatState(
      sessions: sessions ?? this.sessions,
      currentSessionId: currentSessionId ?? this.currentSessionId,
      availableModels: availableModels ?? this.availableModels,
      isLoadingModels: isLoadingModels ?? this.isLoadingModels,
      modelsError: clearModelsError ? null : modelsError ?? this.modelsError,
      selectedModel: selectedModel ?? this.selectedModel,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      approvalMode: approvalMode ?? this.approvalMode,
      autoCompressThreshold:
          autoCompressThreshold ?? this.autoCompressThreshold,
      modelContextLimits: modelContextLimits ?? this.modelContextLimits,
      modelTestResults: modelTestResults ?? this.modelTestResults,
      testingModel: testingModel ?? this.testingModel,
      liveAgentEvents: liveAgentEvents ?? this.liveAgentEvents,
      liveReasoning: clearLiveText ? '' : liveReasoning ?? this.liveReasoning,
      liveContent: clearLiveText ? '' : liveContent ?? this.liveContent,
      liveContentFull:
          clearLiveText ? '' : liveContentFull ?? this.liveContentFull,
      liveReasoningChars:
          clearLiveText ? 0 : liveReasoningChars ?? this.liveReasoningChars,
      liveContentChars:
          clearLiveText ? 0 : liveContentChars ?? this.liveContentChars,
      liveTool: clearLiveText ? '' : liveTool ?? this.liveTool,
      livePlan: livePlan ?? this.livePlan,
      toolRecords: toolRecords ?? this.toolRecords,
      pendingPlan: pendingPlan ?? this.pendingPlan,
      pendingQuestion:
          clearPendingQuestion ? null : pendingQuestion ?? this.pendingQuestion,
      queue: queue ?? this.queue,
      interruptedRun:
          clearInterruptedRun ? null : interruptedRun ?? this.interruptedRun,
      lastPromptTokens: lastPromptTokens ?? this.lastPromptTokens,
      lastCacheHitTokens: lastCacheHitTokens ?? this.lastCacheHitTokens,
      isLoading: isLoading ?? this.isLoading,
      lastTurns: lastTurns ?? this.lastTurns,
      lastTokens: lastTokens ?? this.lastTokens,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class ChatNotifier extends Notifier<ChatState> {
  static const _prefsKey = 'ai_sessions_v1';
  static const _settingsKey = 'ai_settings_v1';

  /// 当前运行中的 Agent 取消令牌，停止按钮用它中断。
  AgentCancelToken? _cancelToken;

  /// 本次运行累积的事件，写入消息以便回看。
  final List<AgentEvent> _runEvents = [];

  @override
  ChatState build() {
    ref.onDispose(_clearLive);
    // 模型相关的状态（有哪些模型、选了哪个、每个多长上下文）真相在提供商总表里，
    // 这里只是它当前那一家的投影。换提供商 / 刷新模型列表都从这条线过来，
    // 免得两处各存一份、切一次就对不上。
    ref.listen<LlmRegistry>(llmRegistryProvider, (_, next) {
      _syncFromRegistry(next);
    });
    // 总表可能在本 notifier 建好之前就读完了（那时不会再有变更事件），
    // 所以首帧之后主动对一次。
    Future.microtask(() => _syncFromRegistry(ref.read(llmRegistryProvider)));
    return ChatState(
      sessions: [
        AiSession(id: 'default', title: '默认会话'),
      ],
      currentSessionId: 'default',
    );
  }

  /// 只加载一次。用户点过确认策略/选过模型之后，迟到的磁盘读取不能再
  /// 把界面上的选择覆盖回旧值（之前就是这么丢设置的）。
  bool _settingsLoaded = false;

  Future<void> loadSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 设置与会话解耦：以前设置的恢复嵌在"有持久化会话"分支里，
      // 首次安装或会话被清空时，模型与确认策略就静默丢了。
      _restoreSettings(prefs);
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) {
        await _persist();
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final sessions = [
        for (final item in decoded)
          if (item is Map<String, dynamic>) AiSession.fromJson(item),
      ];
      if (sessions.isEmpty) return;
      // 下次打开以上一次用过的会话为主：按 updatedAt 取最新，而不是列表第一条。
      var lastId = sessions.first.id;
      var lastAt = sessions.first.updatedAt;
      for (final s in sessions.skip(1)) {
        if (s.updatedAt.isAfter(lastAt)) {
          lastAt = s.updatedAt;
          lastId = s.id;
        }
      }
      state = state.copyWith(
        sessions: sessions,
        currentSessionId: lastId,
      );
    } catch (e) {
      Logger.e('ai', 'load sessions failed', e);
    }
  }

  void _restoreSettings(SharedPreferences prefs) {
    if (_settingsLoaded) return;
    _settingsLoaded = true;
    final settingsRaw = prefs.getString(_settingsKey);
    if (settingsRaw == null || settingsRaw.isEmpty) return;
    try {
      final decoded = jsonDecode(settingsRaw);
      if (decoded is! Map<String, dynamic>) return;
      // 模型列表 / 选中模型 / 上下文长度不在这里读了——它们跟着提供商走，
      // 由 LlmRegistry 负责（老键里的这几项会被总表迁移一次，然后就不用了）。
      state = state.copyWith(
        reasoningEffort: (decoded['reasoningEffort'] as num?)?.toInt() ??
            state.reasoningEffort,
        approvalMode:
            AiApprovalMode.fromName(decoded['approvalMode']?.toString()),
        autoCompressThreshold:
            (decoded['autoCompressThreshold'] as num?)?.toDouble() ??
                state.autoCompressThreshold,
      );
    } catch (_) {
      // 忽略旧/坏设置。
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _settingsKey,
        jsonEncode({
          'reasoningEffort': state.reasoningEffort,
          'approvalMode': state.approvalMode.name,
          'autoCompressThreshold': state.autoCompressThreshold,
        }),
      );
    } catch (e) {
      Logger.e('ai', 'persist ai settings failed', e);
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode([for (final s in state.sessions) s.toJson()]),
      );
    } catch (e) {
      Logger.e('ai', 'persist sessions failed', e);
    }
  }

  List<LlmMessage> _history({String userInput = ''}) {
    // 历史里不能带 tool_calls：对应的 tool 结果消息并没有持久化，
    // 只发半截会让严格实现的服务端直接 400。改成把用过的工具写进正文摘要，
    // 模型照样知道上一轮做过什么。
    final msgs = [
      for (final m in state.messages)
        if (!m.failedToSend) m
    ];
    // assistant 回复要带**工具结果明细**，不能只带工具名。
    //
    // 这是"中断后重来"那个 bug 的根因：被中断时 tool_calls 留在了历史里、
    // 结果却一个都没留（tool 消息不持久化），模型下一轮看到的是"我调用过
    // cron_list、script_read、shell_exec…"但没有任何返回内容——它只能把
    // 那几步全部重跑一遍，用户看到的就是"中断一次白烧一遍 token"。
    // 现在**每一条** assistant 回复都带完整工具结果明细，超了上下文预算
    // 由 `_historyWithAutoCompress` 从最旧的开始裁，不会因为“只记最近几条”
    // 让 AI 忘掉前面几百轮干过的事。
    // ===== 簿记（"这一轮调用过的工具：…"、工具结果明细）绝不能写进 =====
    // ===== assistant 消息的正文里 =====
    //
    // 现场故障：连着问三个问题，第三问模型不调 ask_user 了，气泡里直接吐出
    // 「这一轮调用过的工具：ask_user」——那句话是**我们自己**加的簿记。
    // 原因很直白：它被拼在 assistant 消息的末尾，于是模型看到的"我自己的
    // 历史发言"每条都长这样，它就照着这个格式续写：既然"我的回复里写一句
    // 调用过 ask_user"就行，那还调什么工具。用户看到的就是提问卡不出现、
    // 气泡里躺着一句系统内部记录。
    //
    // 所以现在：assistant 消息只留模型真正说过的话，簿记改挂到**紧随其后的
    // 那条 user 消息**前面（没有后续 user 消息就作为末尾一条 user 追加）。
    // 放在 user 一侧，模型只会把它当"用户/系统告诉我的事实"，不会当成
    // 自己的说话模板去模仿。
    return [
      LlmMessage(role: 'system', content: _systemPrompt(userInput: userInput)),
      // 发送失败的消息不进上下文。模型压根没收到过它，把它当"说过的话"
      // 塞进历史，模型会以为自己已经回过，下一轮基于一段不存在的对话推理。
      ...weaveHistory(
        [
          for (final m in msgs)
            LlmMessage(
              role: m.role == 'assistant' ? 'assistant' : m.role,
              content: _historyContent(m),
            ),
        ],
        [
          for (final m in msgs)
            _historyNote(m, detailed: m.role == 'assistant'),
        ],
      ),
    ];
  }

  /// 把"消息 + 这条消息的簿记"编织成最终 payload。
  ///
  /// 规则：簿记不留在 assistant 消息里，往后挂到**紧随其后的那条 user 消息**
  /// 前面；后面没有 user 消息了就作为末尾一条 user 追加。
  /// [notes] 与 [msgs] 一一对应，空串表示这条没有簿记。
  @visibleForTesting
  static List<LlmMessage> weaveHistory(
    List<LlmMessage> msgs,
    List<String> notes,
  ) {
    final out = <LlmMessage>[];
    final carried = <String>[];
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      if (m.role != 'assistant' && carried.isNotEmpty) {
        out.add(
          LlmMessage(
            role: m.role,
            content: [...carried, m.content].join('\n'),
          ),
        );
        carried.clear();
        continue;
      }
      out.add(m);
      final note = i < notes.length ? notes[i] : '';
      if (note.isNotEmpty) carried.add(note);
    }
    if (carried.isNotEmpty) {
      out.add(LlmMessage(role: 'user', content: carried.join('\n')));
    }
    return out;
  }

  /// 一条 assistant 回复里的工具明细最多占这么多字符。
  ///
  /// 这里**不放全文**：全文可以远超 token 预算，几百轮必炸。改成只留小摘要
  /// + 缓存 key，AI 需要完整内容时调 `tool_cache_read` 按 key 取，不重跑原工具。
  static const _toolDigestBudget = 6000;

  /// 单条工具结果在明细里保留的摘要长度。
  static const _toolDigestPerCall = 220;

  /// 所有 assistant 回复都带工具明细（摘要 + 缓存指针）；超预算由自动压缩从旧到新裁掉。

  /// 把这条回复的执行过程压成"工具 → 摘要 + 缓存 key"清单。
  ///
  /// 数据来自持久化的 agentEvents（工具起止都在里面），所以退出重进、
  /// 中断重来都还在。倒着取最近的若干条：越靠后的越可能是下一步要用的。
  ///
  /// 策略：不塞全文，塞「简短摘要 + 缓存 key + 明确指令」——模型需要完整
  /// 内容时应该调 `tool_cache_read(key)`（本地取，不用重跑外部工具），
  /// 而不是傻乎乎地把同一个文件/命令再查一遍。
  String _toolDigest(AiChatMessage m) {
    final done = [
      for (final e in m.agentEvents)
        if (e.kind == AgentEventKind.toolEnd) e,
    ];
    if (done.isEmpty) return '';
    final lines = <String>[];
    var used = 0;
    for (final e in done.reversed) {
      final name = (e.toolName ?? '').trim();
      if (name.isEmpty) continue;
      final raw = (e.fullResult ?? e.result ?? '').trim();
      if (raw.isEmpty) continue;
      final cacheKey = _toolCacheKey(e);
      final body = raw.length > _toolDigestPerCall
          ? '${raw.substring(0, _toolDigestPerCall)}…'
          : raw;
      final args =
          e.args == null || e.args!.isEmpty ? '' : ' ${jsonEncode(e.args)}';
      final line = '· $name${args.length > 160 ? '' : args}'
          ' ${e.ok ? '→' : '✗'} $body'
          '【完整 ${raw.length} 字已缓存 key=$cacheKey；'
          '需要全文/复述时调 tool_cache_read(key="$cacheKey")，别重跑原工具】';
      if (used + line.length > _toolDigestBudget) break;
      used += line.length;
      lines.add(line);
    }
    if (lines.isEmpty) return '';
    return lines.reversed.join('\n');
  }

  /// 工具结果缓存的稳定 key：工具名 + 参数。
  ///
  /// 同一工具同一参数在一个会话里可能调过多次（比如 shell_exec），
  /// [tool_cache_read] 返回最近一次的结果；要最新状态应直接用原工具。
  static String _toolCacheKey(AgentEvent e) =>
      '${e.toolName ?? ''}|${_canonicalArgs(e.args)}';

  static String _canonicalArgs(Map<String, dynamic>? args) {
    if (args == null || args.isEmpty) return '';
    final entries = args.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return jsonEncode({
      for (final e in entries) e.key: e.value,
    });
  }

  /// 一条历史消息的正文：**只有模型/用户真正说过的话**。
  ///
  /// assistant 消息还要把提问卡的排版剥掉，见 [stripQuestionCard]。
  String _historyContent(AiChatMessage m) =>
      m.role == 'assistant' ? stripQuestionCard(m.content) : m.content;

  /// 从 assistant 正文里剥掉"提问卡排版"，返回 (剩下的话, 那个问题)。
  ///
  /// ## 为什么必须剥
  ///
  /// 模型调 ask_user 时 content 常常是空的，所以这边会把问题本身拼进消息
  /// （见 send 里组装 assistantContent 的那段），否则历史里看不到自己问过什么，
  /// 下一轮会重复问。但那段拼出来的东西长这样：
  ///
  ///     ❓第一个问题：今天早上你吃早餐了吗？
  ///     （日常闲聊第一个问题）
  ///     候选：吃了 / 随便对付一口 / 还没吃
  ///
  /// 这套 `❓ / （说明）/ 候选：` 排版是**界面**的渲染格式，可它原样进了历史。
  /// 模型看到"我上一条回复就是这么写的"，第二问就照抄格式手写一遍，
  /// 不再调 ask_user——界面于是不弹卡、不挂起，追问链在第二问就断了
  /// （用户实录：第一问正常，第二问气泡里只有文字、过程卡零工具调用，
  /// 第三问根本没来）。
  ///
  /// 所以历史里只留模型真说过的话，问题挪进 user 一侧的系统记录
  /// （见 [_historyNote]）。界面显示不受影响：气泡读的是原始 content。
  @visibleForTesting
  static String stripQuestionCard(String content) =>
      _splitQuestionCard(content).$1;

  /// 同上，返回被剥掉的那个问题（给 [_historyNote] 用）。
  @visibleForTesting
  static String questionOfCard(String content) =>
      _splitQuestionCard(content).$2;

  static (String, String) _splitQuestionCard(String content) {
    if (!content.contains('❓')) return (content, '');
    final kept = <String>[];
    var question = '';
    var inCard = false;
    for (final line in content.split('\n')) {
      final t = line.trim();
      if (t.startsWith('❓')) {
        inCard = true;
        question = t.replaceFirst('❓', '').trim();
        continue;
      }
      // ❓ 之后紧跟的说明行 /候选行都属于这张卡，一起剥掉。
      if (inCard &&
          (RegExp(r'^候选\s*[：:]').hasMatch(t) ||
              (t.startsWith('（') && t.endsWith('）')) ||
              (t.startsWith('(') && t.endsWith(')')))) {
        continue;
      }
      inCard = false;
      kept.add(line);
    }
    return (kept.join('\n').trim(), question);
  }

  /// 这条 assistant 回复对应的簿记，挂到后面那条 user 消息上（见 [_history]）。
  ///
  /// 两类内容：① 这一轮实际跑过的工具（全部带结果明细）；
  /// ② 提问那一轮的"提问必须走 ask_user"提醒。
  String _historyNote(AiChatMessage m, {bool detailed = false}) {
    // 被中断 / 半途停下的那一轮：把已经跑过的工具连**结果**一起交回去。
    if (detailed) {
      final digest = _toolDigest(m);
      if (digest.isNotEmpty) {
        final interrupted = m.outcome == 'cancelled';
        final head = interrupted
            ? '（系统记录 · 上一轮被用户中断了。**下面这些工具已经真的执行过了，'
                '结果就在这儿**，不要重复调用同样的参数——接着往下做，'
                '或者按用户新说的方向走。）'
            : '（系统记录 · 上一轮实际执行过的工具与结果，供你接着用，不用重复查：）';
        return [head, digest].join('\n');
      }
    }
    if (m.toolCalls.isEmpty) return '';
    final names = <String>{for (final t in m.toolCalls) t.name}.join('、');
    // 被剥掉的那个问题在这里交回去：模型要知道自己问过什么，不然会重复问。
    final asked0 = questionOfCard(m.content);
    // 措辞很要紧。原来写的是"上一轮**已**调用工具：ask_user"，模型把它读成
    // "这件事做过了"，于是需要连着问三个问题的场景，第二问直接被咽回去，
    // 自己瞎猜着往下做。现在改成中性描述 + 明说可以再调。
    //
    // 提问那一轮还要额外交代一句"我是用工具问的"。历史里 tool_calls 被抹掉了
    // （见 _history 的说明），提问只剩一行 `❓ xxx` 纯文本；模型照着这个范例学，
    // 问到第三个问题时就直接写正文——界面上不弹提问卡、也不挂起等答案，
    // 用户看到的现象就是"后面的提问不调工具了"。
    final asked = m.toolCalls.any((t) => t.name == 'ask_user');
    // "系统记录 ·" 这个前缀是给模型看的路牌：这段不是它自己的话，
    // 不要当模板抄。真抄了循环那边还有一道兜底（见 AgentLoop.echoedBookkeeping）。
    return asked
        ? '（系统记录 · 你上一轮通过 ask_user 工具问的是'
            '${asked0.isEmpty ? '一个问题' : '「$asked0」'}，'
            '所以我这边弹出了提问卡、你才收到我的回答。'
            '**注意：❓、（说明）、候选：这套排版是我的界面自动画的，'
            '不是你写的格式**——你自己在正文里手写一遍不算提问，'
            '我不会看到可回答的提问卡，界面也不会停下来等我答。'
            '下一个问题照样要调 ask_user，问第几个都一样。'
            '这一轮执行到的工具：$names）'
        : '（系统记录 · 上一轮执行到的工具：$names。这只是记录，'
            '需要就可以再调——换了对象/参数，或者还有别的信息要问，都该接着调。）';
  }

  /// 系统提示词 + 运行期环境信息（当前面板、本机 Debian 是否可用）。
  String _approvalPromptLine() {
    return switch (state.approvalMode) {
      AiApprovalMode.strict => '严格模式。任何写操作都会被挂起等用户点确认，调用写工具后先停下说明操作/对象/影响。',
      AiApprovalMode.cautious => '仅危险确认。可逆的写操作（新建、改内容、启停开关等）会直接执行，'
          '不可逆的（删除、覆盖、运行任务、执行 shell 命令、面板更新）才挂起等确认。',
      AiApprovalMode.full => '全部放行。用户已授权你直接执行任何工具，不会再有确认卡片；'
          '正因为没有兜底，破坏性操作前要自己先备份、先核实目标是否正确。',
    };
  }

  /// 系统提示词。
  ///
  /// 顺序刻意安排成"静态在前、动态在后"：DeepSeek 等厂商的提示词缓存按
  /// **前缀**命中，前缀里只要有一个字变了（比如精确到秒的时间戳），后面几万
  /// token 全部按未命中计费。之前时间戳就排在第二段，等于把缓存彻底废掉。
  /// 现在把技能目录、MCP 目录、元能力说明这些长且稳定的内容排在前面，
  /// 把面板/时间/记忆这些会变的排在最后，且时间只精确到小时。
  String _systemPrompt({String userInput = ''}) {
    final mcpState = ref.read(mcpProvider);
    final mcpTools = mcpState.tools;
    final collapsed = McpGateway.shouldCollapse(mcpTools.length);

    final lines = <String>[qinglongSystemPrompt];

    // ---- 静态段（跨轮、跨会话稳定，用来吃满提示词缓存）----
    if (collapsed) {
      final mcpCatalog = McpGateway.promptCatalog(mcpState);
      if (mcpCatalog.isNotEmpty) {
        lines
          ..add('')
          ..add(mcpCatalog);
      }
    }
    final skillCatalog = ref.read(skillProvider.notifier).promptCatalog();
    if (skillCatalog.isNotEmpty) {
      lines
        ..add('')
        ..add(skillCatalog);
    }
    lines
      ..add('')
      ..add(BrowserTools.promptBlock());
    // 编辑器那一大段只在用户真开着编辑器时才带：没开编辑器却挂着
    // "改代码要用 editor_*"，模型会先调一遍 editor_* 撞一鼻子灰才反应过来，
    // 白烧一轮 token。没开就只留一句话说明。
    lines
      ..add('')
      ..add(EditorTools.promptBlock());
    lines
      ..add('')
      ..add(
        MetaTools.promptBlock(
          memoryCount: ref.read(memoryProvider).items.length,
          skillCount: ref.read(skillProvider).skills.length,
          mcpServerCount: mcpState.servers.length,
        ),
      );

    // ---- 动态段（每次可能不同，排最后，破坏的缓存最少）----
    final panel = ref.read(currentPanelProvider);
    final now = DateTime.now();
    lines
      ..add('')
      ..add('## 当前运行环境')
      ..add(
        panel == null
            ? '- 青龙面板：未选择。需要面板的工具会失败，先让用户在“面板”页添加或选择面板。'
            : '- 青龙面板：${panel.name}（${panel.baseUrl}）',
      )
      ..add(
        '- 本机 Debian：/workspace、/home/coomi、/opt/coomi-dev、/tmp 可读写；'
        '终端页和 shell_* 工具看到的是同一份文件。',
      )
      // 精确到小时：秒级时间戳会让每一次请求都缓存未命中，而任务里几乎
      // 没有需要秒级精度的场景，要精确时间可以自己 shell_exec date。
      ..add(
        '- 当前时间：${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)} 时（需要精确时间用 shell_exec date）',
      )
      ..add('- 写操作确认策略：${_approvalPromptLine()}');
    // 用户开着哪个代码编辑器：直接决定 editor_* 该往哪写，必须实时。
    final editorState = EditorTools.promptState();
    if (editorState.isNotEmpty) lines.add(editorState);
    if (mcpTools.isNotEmpty && !collapsed) {
      lines.add(
        '- 扩展工具（MCP）：已接入 ${mcpTools.length} 个外部工具，'
        '名字形如 服务器前缀__工具名（例如 ${mcpTools.first.localName}）。'
        '需要联网搜索、控制外部系统等超出青龙范围的事情时，先看这些工具能不能干。',
      );
    }
    final memoryBlock =
        ref.read(memoryProvider.notifier).promptBlock(userInput);
    if (memoryBlock.isNotEmpty) {
      lines
        ..add('')
        ..add(memoryBlock);
    }
    return lines.join('\n');
  }

  /// 子代理的系统提示词。
  ///
  /// 刻意比主提示词短：子代理只做一件被交待清楚的事，不需要知道会话礼节、
  /// 也不需要"要不要总结"这类分寸判断。三条硬约束必须写明——它没有界面，
  /// 问不了用户；它的产出只有最后那段文字；别去动任务范围外的东西。
  String _workerPrompt() {
    final panel = ref.read(currentPanelProvider);
    return [
      '你是一个任务工人代理，由主代理派来完成**一个具体子任务**。',
      '',
      '规则：',
      '1. 你没有界面，联系不到用户：不要提问、不要等确认，'
          '缺信息就用只读工具自己查，实在缺到做不了就在结论里说清缺什么。',
      '2. 只做交给你的这一件事，不要顺手改别的文件、不要扩大范围——'
          '同一时刻可能还有别的工人在干活，越界会互相覆盖。',
      '3. 别猜结果。要算就写脚本用 shell_script 跑出来，要看内容就读文件，'
          '拿到真实输出再下结论。',
      '4. 干完直接给结论：做了什么、结果是什么、有什么异常。'
          '不要复述过程细节，主代理只需要结论。',
      '5. 终端和浏览器是全机共用的，可能要排队等一会儿，这是正常的，别反复重试。',
      '',
      panel == null
          ? '- 青龙面板：未选择，需要面板的工具会失败。'
          : '- 青龙面板：${panel.name}（${panel.baseUrl}）',
      '- 本机 Debian：/workspace、/home/coomi、/opt/coomi-dev、/tmp 可读写。',
    ].join('\n');
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  int _estimateTokens(List<LlmMessage> messages) {
    final chars = messages.fold<int>(
      0,
      (sum, m) => sum + m.content.length + m.toolCalls.length * 80,
    );
    return (chars / 3.5).ceil();
  }

  /// 按 模型上下文上限 * 自动压缩阈值 裁剪历史，优先丢弃最早的非系统消息。
  List<LlmMessage> _historyWithAutoCompress({String userInput = ''}) {
    final history = _history(userInput: userInput);
    final limit = state.contextLimit;
    if (limit <= 0 || history.length < 2) return history;
    final threshold = (limit * state.autoCompressThreshold).round();
    var trimmed = history;
    var estimated = _estimateTokens(trimmed);
    while (estimated > threshold && trimmed.length > 2) {
      trimmed = [trimmed.first, ...trimmed.sublist(2)];
      estimated = _estimateTokens(trimmed);
    }
    if (trimmed.length != history.length) {
      Logger.d('ai', 'auto compress: ${history.length} -> ${trimmed.length}');
    }
    return trimmed;
  }

  /// 生成“当前上下文内容”的可读预览，供上下文面板展开查看。
  ///
  /// 用的是真正会发给模型的同一份 history（含系统提示、用户、AI、
  /// 工具结果明细），不是界面上的气泡列表——所以展开后能看到 AI
  /// 到底记住了哪些东西。
  String contextPreview({int maxChars = 8000}) {
    final history = _history();
    final out = <String>[];
    var used = 0;
    for (final m in history) {
      final role = switch (m.role) {
        'system' => '【系统】',
        'user' => '【用户】',
        'assistant' => '【AI】',
        'tool' => '【工具】',
        _ => '[${m.role}]',
      };
      final content = m.content.replaceAll('\n', ' ⏎ ');
      final snippet =
          content.length > 180 ? '${content.substring(0, 180)}…' : content;
      final line = '$role（${content.length} 字）$snippet';
      if (used + line.length > maxChars) {
        out.add('…（预览截断，只展示前 $maxChars 字符）');
        break;
      }
      used += line.length;
      out.add(line);
    }
    return out.join('\n');
  }

  /// 发送。AI 正在跑的时候不再丢弃输入，而是进排队区。
  Future<void> send(String text) async {
    final value = text.trim();
    if (value.isEmpty) return;
    if (state.isLoading) {
      enqueue(value);
      return;
    }
    await _sendNow(value);
    // 这里不再无条件 drain：_sendNow 收尾时已经按"是否挂起"判断过一次。
    _pumpQueue();
  }

  // ------------------------------------------------------------ 排队区

  /// 加入排队。跑完当前任务会按顺序自动发出。
  void enqueue(String text) {
    final value = text.trim();
    if (value.isEmpty) return;
    state =
        state.copyWith(queue: [...state.queue, QueuedMessage.create(value)]);
  }

  void dequeue(String id) {
    state = state.copyWith(
      queue: state.queue.where((q) => q.id != id).toList(),
    );
  }

  void clearQueue() => state = state.copyWith(queue: const []);

  /// 拖拽重排：把 [oldIndex] 的那条挪到 [newIndex]。
  void reorderQueue(int oldIndex, int newIndex) {
    final list = [...state.queue];
    if (oldIndex < 0 || oldIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    final target = newIndex.clamp(0, list.length);
    list.insert(target, item);
    state = state.copyWith(queue: list);
  }

  /// 置顶：下一个就发它。
  void promoteQueued(String id) {
    final index = state.queue.indexWhere((q) => q.id == id);
    if (index <= 0) return;
    reorderQueue(index, 0);
  }

  /// 紧急插队：立刻中断当前运行，把这条排到最前面，中断后马上发出。
  ///
  /// 中断不回滚已执行的写操作（和"停止"按钮一样），所以这是显式动作，
  /// 由用户在排队条上点"中断并立即发送"触发。
  void interruptAndSend(String id) {
    promoteQueued(id);
    if (state.isLoading) {
      // stopAgent 收尾时会 drain 队列，被顶到最前的这条先发。
      stopAgent();
      return;
    }
    // 用户宁愿先发这条，也就是不打算回答那个挂起的问题了：
    // 主动把提问撤掉，否则 _drainQueue 的"挂起中不自动发"保护会把它挡住，
    // 点了"中断并立即发送"却什么都不发生。
    if (state.pendingQuestion != null) {
      state = state.copyWith(clearPendingQuestion: true);
    }
    unawaited(_drainQueue());
  }

  /// 依次把排队消息发出去。
  Future<void> _drainQueue() async {
    while (state.queue.isNotEmpty &&
        !state.isLoading &&
        state.pendingQuestion == null &&
        state.pendingPlan.isEmpty) {
      final next = state.queue.first;
      state = state.copyWith(queue: state.queue.sublist(1));
      await _sendNow(next.text);
    }
  }

  /// 运行代号。点"停止"后自增，旧运行回来的结果一律丢弃。
  ///
  /// 没有这个的话，"停止"必须等 Agent 循环自己走完当前一步才生效，
  /// 用户感觉就是"点了没反应"。有了它，界面可以立刻收尾。
  int _runGeneration = 0;

  /// [appendUser] = false 用于"继续上次被打断的任务"：那条用户消息在闪退前
  /// 就已经落盘了，再追加一遍界面上会出现两条一模一样的提问。
  Future<void> _sendNow(String value, {bool appendUser = true}) async {
    final session = state.currentSession;
    if (session == null) return;
    final gen = ++_runGeneration;

    if (appendUser) {
      final userMessage = AiChatMessage(
          role: 'user', content: value, createdAt: DateTime.now());
      final updated = AiSession(
        id: session.id,
        title: session.title == '新会话' ? _titleFrom(value) : session.title,
        messages: [...session.messages, userMessage],
        createdAt: session.createdAt,
        updatedAt: DateTime.now(),
      );
      _replaceSession(updated);
    }

    state = state.copyWith(
      isLoading: true,
      pendingPlan: const [],
      clearPendingQuestion: true,
      clearInterruptedRun: true,
      liveAgentEvents: const [],
      clearLiveText: true,
      clearError: true,
    );
    _runEvents.clear();
    _clearLive();
    // 先落盘"我正在跑什么"：闪退时内存里的事件全没了，磁盘上这份能救回来。
    _activeRunInput = value;
    _activeRunSessionId = session.id;
    unawaited(_saveActiveRun());
    // 让出一帧：用户消息必须先画出来。后面组装系统提示词（技能目录、MCP 目录、
    // 记忆检索）是同步的重活，挤在同一帧里会让"发送"看起来卡好几秒。
    await Future<void>.delayed(const Duration(milliseconds: 16));
    if (gen != _runGeneration) return;
    try {
      final result = await _runAgent(
        {},
        onEvent: _appendAgentEvent,
        userInput: value,
      );
      // 已经被"停止"接管过了，这份结果作废。
      if (gen != _runGeneration) return;
      final current = state.currentSession;
      if (current == null) return;
      // 模型提问时 content 常常是空的，得把问题本身写进消息，
      // 否则下一轮历史里看不到自己问过什么，会重复问。
      final question = result.question;
      final assistantContent = question == null
          ? result.content
          : [
              if (result.content.trim().isNotEmpty) result.content.trim(),
              '❓ ${question.question}',
              if (question.context.isNotEmpty) '（${question.context}）',
              if (question.options.isNotEmpty)
                '候选：${question.options.join(' / ')}',
            ].join('\n');
      final assistantMessage = AiChatMessage(
        role: 'assistant',
        content: assistantContent,
        toolCalls: [
          for (final r in result.toolRecords)
            AiToolCall(name: r.toolName, arguments: r.args),
        ],
        createdAt: DateTime.now(),
        agentEvents: List<AgentEvent>.from(_runEvents),
        outcome: result.outcome.name,
        turns: result.turns,
        totalTokens: result.usage.totalTokens,
        promptTokens: result.lastPromptTokens,
        cachedTokens: result.lastCacheHitTokens,
        taskPlan: result.taskPlan,
        canvases: result.canvases,
      );
      _replaceSession(
        AiSession(
          id: current.id,
          title: current.title,
          messages: [...current.messages, assistantMessage],
          createdAt: current.createdAt,
          updatedAt: DateTime.now(),
        ),
      );
      // 提问是硬阻塞：不回答就什么都不会继续。所以它必须自己浮到用户眼前。
      //
      // 悬浮球收起、人又不在 AI 页时，提问窗压根不画（见 AiDockOverlay._layers），
      // 球也不转——用户看到的就是"问了一次之后彻底卡住"。这里把窗口展开，
      // 问题连同候选按钮立刻出现在最上层。
      if (question != null) _surfaceQuestion();
      state = state.copyWith(
        toolRecords: result.toolRecords,
        pendingPlan: result.pendingActions,
        pendingQuestion: question,
        clearPendingQuestion: question == null,
        isLoading: false,
        liveAgentEvents: const [],
        clearLiveText: true,
        lastTurns: result.turns,
        lastTokens: result.usage.totalTokens,
        lastPromptTokens: result.lastPromptTokens,
        lastCacheHitTokens: result.lastCacheHitTokens,
        clearError: true,
      );
      _auditRun(result);
      // 正常收尾：清掉"未完成运行"标记，重开 APP 不该再提示继续。
      unawaited(_clearActiveRun());
      unawaited(BrowserEngine.instance.settleAfterRun());
      _pumpQueue();
    } catch (e) {
      Logger.e('ai', 'send failed', e);
      if (gen != _runGeneration) return;
      final current = state.currentSession;
      if (current == null) return;
      // 模型调用失败 = 这句话根本没送出去。
      //
      // 以前这里追加一条 assistant「出错了：xxx」，两个后果都很糟：
      // ①它进了上下文，模型下一轮以为自己答过话；②用户看到的是"AI 回了一句
      // 错误"，而不是"我这句没发出去"。现在把错误挂回那条用户消息上，
      // 界面在气泡下面标红字，历史里连这条用户消息一起跳过。
      final messages = [...current.messages];
      final lastUser = messages.lastIndexWhere((m) => m.isUser);
      if (lastUser >= 0) {
        messages[lastUser] = messages[lastUser].copyWith(
          sendError: _friendlyError(e),
          // 失败前已经跑过的工具照样留着：多轮任务中途断线时，
          // 用户得能看到"断在哪一步"。
          agentEvents: List<AgentEvent>.from(_runEvents),
        );
      }
      _replaceSession(
        AiSession(
          id: current.id,
          title: current.title,
          messages: messages,
          createdAt: current.createdAt,
          updatedAt: DateTime.now(),
        ),
      );
      state = state.copyWith(
        isLoading: false,
        liveAgentEvents: const [],
        clearLiveText: true,
        error: e,
      );
      unawaited(_clearActiveRun());
      unawaited(BrowserEngine.instance.settleAfterRun());
      _pumpQueue();
    }
  }

  /// 把挂起的提问顶到用户面前：悬浮球是收起的就展开它。
  ///
  /// 只在"人不在 AI 页"时动手——AI 页自己会把提问卡画在消息流末尾并滚到底，
  /// 再展开悬浮窗等于在他眼前盖一层多余的窗口。
  void _surfaceQuestion() {
    try {
      if (ref.read(homeTabIndexProvider) == 2) return;
      final dock = ref.read(aiDockProvider);
      // 快问模式下问题由快问自己的提问窗接住：不展开完整悬浮窗，
      // 否则用户一问问题就被强行踢出快问输入框。
      if (dock.quickOpen || dock.quickBusy) return;
      if (dock.visible) {
        if (!dock.expanded) ref.read(aiDockProvider.notifier).open();
        return;
      }
      // 悬浮球被关掉了：没有球、没有窗，问题只存在于 AI 页的消息流里。
      // 给一条带跳转的提示，否则这一轮真的会看起来"死了"。
      final context = appNavigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('AI 在等你回答一个问题'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: '去看看',
            onPressed: () => ref.read(homeTabIndexProvider.notifier).state = 2,
          ),
        ),
      );
    } catch (e) {
      // 展开失败不该影响这一轮的结果落地。
      Logger.d('ai', 'surface question failed: $e');
    }
  }

  /// 一轮跑完后把排队里的下一条接上。
  ///
  /// 这里补的是一个真实的死局：[send] 在 isLoading 时把输入丢进队列就返回了，
  /// 而队列原先只有 `send` 自己跑完才会 drain——如果那一条正是"回答提问"，
  /// 提问卡已经锁成"已回答"，队列却没人来取，界面就永远停在那儿。
  /// 用户看到的现象就是"答完第一个问题之后卡住了"。
  void _pumpQueue() {
    if (state.queue.isEmpty || state.isLoading) return;
    // 挂起等回答 / 等确认时不许自动接下一条：那会立刻开新一轮，
    // 把提问卡（clearPendingQuestion）连问题一起抹掉，用户答什么都没了。
    // 队列不会丢，等这个问题答完，_sendNow 收尾时自然接上。
    if (state.pendingQuestion != null || state.pendingPlan.isNotEmpty) return;
    unawaited(_drainQueue());
  }

  // ------------------------------------------------- 崩溃恢复（未完成的运行）

  /// 当前运行的输入与会话，落盘用。
  String _activeRunInput = '';
  String _activeRunSessionId = '';

  static const _activeRunKey = 'ai_active_run_v1';

  Future<void> _saveActiveRun() async {
    if (_activeRunInput.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _activeRunKey,
        InterruptedRun.encode(
          InterruptedRun(
            sessionId: _activeRunSessionId,
            userInput: _activeRunInput,
            events: List<AgentEvent>.from(_runEvents),
            startedAt: DateTime.now(),
          ),
        ),
      );
    } catch (e) {
      Logger.e('ai', 'save active run failed', e);
    }
  }

  Future<void> _clearActiveRun() async {
    _activeRunInput = '';
    _activeRunSessionId = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_activeRunKey);
    } catch (e) {
      Logger.e('ai', 'clear active run failed', e);
    }
  }

  /// 启动时检查有没有被打断的运行。
  Future<void> loadInterruptedRun() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final run = InterruptedRun.decode(prefs.getString(_activeRunKey) ?? '');
      if (run == null) return;
      state = state.copyWith(
        interruptedRun: run,
        // 把已有过程直接摆回界面上，用户能看到"上次做到哪了"。
        liveAgentEvents: run.events,
      );
    } catch (e) {
      Logger.e('ai', 'load interrupted run failed', e);
    }
  }

  /// 继续被打断的运行：切回原会话，重发原输入。
  Future<void> resumeInterruptedRun() async {
    final run = state.interruptedRun;
    if (run == null || state.isLoading) return;
    state =
        state.copyWith(clearInterruptedRun: true, liveAgentEvents: const []);
    if (run.sessionId.isNotEmpty &&
        run.sessionId != state.currentSessionId &&
        state.sessions.any((s) => s.id == run.sessionId)) {
      state = state.copyWith(currentSessionId: run.sessionId);
    }
    // 上次那条用户消息很可能已经在会话里了：只有确实不在才补一条。
    final last = state.currentSession?.messages;
    final alreadyThere = last != null &&
        last.isNotEmpty &&
        last.last.role == 'user' &&
        last.last.content == run.userInput;
    if (state.isLoading) {
      enqueue(run.userInput);
      return;
    }
    await _sendNow(run.userInput, appendUser: !alreadyThere);
    _pumpQueue();
  }

  /// 放弃被打断的运行。
  Future<void> discardInterruptedRun() async {
    state =
        state.copyWith(clearInterruptedRun: true, liveAgentEvents: const []);
    await _clearActiveRun();
  }

  Future<void> confirmPlan() async {
    final plan = state.pendingPlan;
    if (plan.isEmpty || state.isLoading) return;
    // 必须与 AgentLoop 的键算法一致（参数按 key 排序），否则确认后仍会被再次挂起。
    final keys = <String>{
      for (final a in plan)
        if (a.data != null) AgentLoop.cacheKeyOf(a.type, a.data!),
    };
    state = state.copyWith(
      pendingPlan: const [],
      isLoading: true,
      liveAgentEvents: const [],
      clearLiveText: true,
    );
    _runEvents.clear();
    try {
      final result = await _runAgent(keys, onEvent: _appendAgentEvent);
      final current = state.currentSession;
      if (current == null) return;
      _replaceSession(
        AiSession(
          id: current.id,
          title: current.title,
          messages: [
            ...current.messages,
            AiChatMessage(
              role: 'assistant',
              content: result.content.isNotEmpty
                  ? result.content
                  : '计划已执行，请到对应模块查看结果。',
              createdAt: DateTime.now(),
              agentEvents: List<AgentEvent>.from(_runEvents),
              outcome: result.outcome.name,
              turns: result.turns,
              totalTokens: result.usage.totalTokens,
              promptTokens: result.lastPromptTokens,
              cachedTokens: result.lastCacheHitTokens,
              taskPlan: result.taskPlan,
              canvases: result.canvases,
            ),
          ],
          createdAt: current.createdAt,
          updatedAt: DateTime.now(),
        ),
      );
      state = state.copyWith(
        toolRecords: result.toolRecords,
        pendingPlan: result.pendingActions,
        isLoading: false,
        liveAgentEvents: const [],
        clearLiveText: true,
        lastTurns: result.turns,
        lastTokens: result.usage.totalTokens,
        clearError: true,
      );
      _auditRun(result);
      unawaited(BrowserEngine.instance.settleAfterRun());
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e,
      );
      final current = state.currentSession;
      if (current != null) {
        // 和 _sendNow 一样：失败原因挂回用户那条消息，不再伪造一条 AI 回复。
        final messages = [...current.messages];
        final lastUser = messages.lastIndexWhere((m) => m.isUser);
        if (lastUser >= 0) {
          messages[lastUser] = messages[lastUser].copyWith(
            sendError: _friendlyError(e),
            agentEvents: List<AgentEvent>.from(_runEvents),
          );
        }
        _replaceSession(
          AiSession(
            id: current.id,
            title: current.title,
            messages: messages,
            createdAt: current.createdAt,
            updatedAt: DateTime.now(),
          ),
        );
      }
    }
  }

  void rejectPlan() {
    if (state.pendingPlan.isEmpty || state.isLoading) return;
    ref.read(auditProvider.notifier).add(
          module: 'ai',
          action: 'plan_reject',
          detail: state.pendingPlan.map((a) => a.type).join(', '),
          result: 'rejected',
        );
    state = state.copyWith(
      pendingPlan: const [],
    );
    final current = state.currentSession;
    if (current != null) {
      _replaceSession(
        AiSession(
          id: current.id,
          title: current.title,
          messages: [
            ...current.messages,
            const AiChatMessage(
              role: 'assistant',
              content: '已取消本次计划，没有执行任何写操作。',
            ),
          ],
          createdAt: current.createdAt,
          updatedAt: DateTime.now(),
        ),
      );
    }
  }

  // ------------------------------------------------------------ 重发 / 撤回

  /// 撤回到某条消息之前：删掉它自己和它之后的全部消息。
  ///
  /// 返回被撤回的那条用户消息正文，方便调用方决定要不要重发。
  /// 注意这只回滚**对话**，不回滚已经在面板上真实发生的写操作——
  /// 那些不可逆，界面上不能假装撤销了。
  String rollbackTo(int index) {
    final current = state.currentSession;
    if (current == null) return '';
    if (index < 0 || index >= current.messages.length) return '';
    final target = current.messages[index];
    _replaceSession(
      AiSession(
        id: current.id,
        title: current.title,
        messages: current.messages.sublist(0, index),
        createdAt: current.createdAt,
        updatedAt: DateTime.now(),
      ),
    );
    state = state.copyWith(
      pendingPlan: const [],
      clearPendingQuestion: true,
      liveAgentEvents: const [],
      clearLiveText: true,
      clearError: true,
    );
    return target.content;
  }

  /// 重发某条用户消息：撤回到它之前，然后重新发一次。
  ///
  /// 对 assistant 消息调用时，自动往上找最近的那条用户消息。
  Future<void> resendAt(int index) async {
    if (state.isLoading) return;
    final current = state.currentSession;
    if (current == null) return;
    var target = index;
    while (target >= 0 && !current.messages[target].isUser) {
      target--;
    }
    if (target < 0) return;
    final text = rollbackTo(target);
    if (text.trim().isEmpty) return;
    await send(text);
  }

  void clear() {
    final current = state.currentSession;
    if (current == null) return;
    _replaceSession(
      AiSession(
        id: current.id,
        title: current.title,
        messages: const [],
        createdAt: current.createdAt,
        updatedAt: DateTime.now(),
      ),
    );
    state = state.copyWith(
      toolRecords: const [],
      pendingPlan: const [],
      liveAgentEvents: const [],
      clearLiveText: true,
      error: null,
    );
  }

  /// 从当前提供商的缓存装载模型列表（不发任何请求）。
  ///
  /// AI 页进页面时用这个。以前每次进 AI 页都去拉一次 /models：慢、费流量，
  /// 没网时还会在页面上糊一条"获取模型列表失败"。真正需要更新列表时，
  /// 用户会去设置页点「获取模型列表」。
  Future<void> loadCachedModels() async {
    // 总表可能还没读完（首帧就进 AI 页的情况），先等它。
    await ref.read(llmRegistryProvider.notifier).load();
    _syncFromRegistry(ref.read(llmRegistryProvider));
    if (state.modelsError != null) {
      state = state.copyWith(clearModelsError: true);
    }
  }

  /// 把提供商总表投影到聊天状态。
  ///
  /// 只在总表读完之后做：没读完就投影，界面会先闪一下"没有模型"，
  /// 用户以为配置丢了。
  void _syncFromRegistry(LlmRegistry registry) {
    if (!registry.loaded) return;
    final provider = registry.active;
    final models = provider.allModels;
    final limits = <String, int>{
      for (final m in models)
        m: _guessContextLimit(m, provider.contextLimits[m]),
    };
    final selected = provider.defaultModel.isNotEmpty
        ? provider.defaultModel
        : (models.isNotEmpty ? models.first : '');
    // 换了家才清连通性结论：同一家里改一下某个模型的上下文长度，
    // 不该把刚测出来的"可用/不可用"全抹掉。
    final switched = provider.id != _syncedProviderId;
    _syncedProviderId = provider.id;
    final same = !switched &&
        selected == state.selectedModel &&
        models.length == state.availableModels.length &&
        models.every(state.availableModels.contains) &&
        limits.length == state.modelContextLimits.length &&
        limits.entries.every((e) => state.modelContextLimits[e.key] == e.value);
    // 没变就别写 state：每次写都会把 AI 页整颗重建一次。
    if (same) return;
    state = state.copyWith(
      availableModels: models,
      // 换提供商要整份换掉，不能合并：同名模型在两家网关上的上下文经常不同，
      // 合并会把上一家的数字留在界面上。
      modelContextLimits: limits,
      selectedModel: selected,
      modelTestResults: switched ? const {} : state.modelTestResults,
    );
  }

  /// 上一次投影的是哪家，用来判断"是不是换了家"。
  String _syncedProviderId = '';

  /// 拉当前提供商的模型列表。
  Future<void> loadModels() =>
      loadModelsFor(ref.read(llmRegistryProvider).active.id);

  /// 拉指定提供商的模型列表，写进它自己的缓存。
  ///
  /// 每家一份缓存，所以在弹窗里翻看另一家、顺手点一下"获取"，
  /// 不会把当前这家的列表冲掉。
  Future<void> loadModelsFor(String providerId) async {
    final registry = ref.read(llmRegistryProvider);
    final target = registry.byId(providerId);
    if (target == null) return;
    state = state.copyWith(isLoadingModels: true, clearModelsError: true);
    try {
      final config = await ref
          .read(llmRegistryProvider.notifier)
          .configFor(providerId, model: target.defaultModel);
      final fetched = await LlmClient.listModels(config: config);
      // 保留手填的模型：接口列表刷新不该把用户自己加的名字抹掉。
      final manual = target.manualModels
          .where((m) => !fetched.contains(m))
          .toList(growable: false);
      // 去重后排序：网关经常返回上百个同族模型，按名字排一下好找。
      final models = <String>{...fetched}.toList()..sort();
      final all = <String>{...models, ...manual};
      await ref.read(llmRegistryProvider.notifier).setModels(
        providerId,
        models: models,
        manualModels: manual,
        contextLimits: {
          for (final m in all)
            m: _guessContextLimit(m, target.contextLimits[m]),
        },
      );
      // 选中的模型没在新列表里（网关下线了它）就回落到第一个。
      if (all.isNotEmpty &&
          (target.defaultModel.isEmpty || !all.contains(target.defaultModel))) {
        await ref
            .read(llmRegistryProvider.notifier)
            .setDefaultModel(providerId, all.first);
      }
      state = state.copyWith(
        isLoadingModels: false,
        clearError: true,
        clearModelsError: true,
      );
    } catch (e) {
      Logger.e('ai', 'load models failed', e);
      // 失败原因单独记一份：弹窗里直接显示，不必去翻调试日志。
      state = state.copyWith(
        isLoadingModels: false,
        error: e,
        modelsError: _modelsErrorText(e),
      );
    }
  }

  /// 把异常翻成一句人能看懂的失败原因。
  String _modelsErrorText(Object e) {
    final text = e.toString();
    // 自签名 HTTPS 排最前：它的异常文本里也带 SocketException，
    // 会被下面那条"连不上服务地址"截走，把人引去查网络。
    if (isCertError(e)) return certHint;
    if (isPlaintextToTlsError(e)) return schemeHint;
    if (text.contains('SocketException') ||
        text.contains('Failed host lookup')) {
      return '连不上服务地址，检查 Base URL 与网络';
    }
    if (text.contains('401') || text.contains('403')) {
      return '鉴权失败，检查 API Key';
    }
    if (text.contains('timeout') || text.contains('Timeout')) {
      return '请求超时，服务未响应';
    }
    final match = RegExp(r'(?:ApiException|Exception): (.+)').firstMatch(text);
    return match?.group(1)?.trim() ?? text;
  }

  /// 连通性测试。返回 (是否通, 失败原因)。
  ///
  /// 原来只返回 bool，界面统一弹"连接失败，检查 URL / Key / 模型"——真正的原因
  /// （自签名证书没被信任、401、模型名不存在）全被 `catch (_)` 吃掉了。
  /// 自签 HTTPS 的内网网关最吃亏：照着提示反复检查 URL 和 Key，
  /// 而问题在设置里另一个开关上。
  Future<(bool, String)> testConnectionDetail() async {
    final config = await ref.read(llmConfigProvider.future);
    final effective = _configFor(config);
    try {
      await LlmClient.testConnection(config: effective)
          .timeout(const Duration(seconds: 20));
      return (true, '');
    } on TimeoutException {
      return (false, '20 秒没有响应：地址不通或服务没起来。');
    } catch (e) {
      return (false, _friendlyError(e));
    }
  }

  Future<bool> testConnection() async => (await testConnectionDetail()).$1;

  /// 测某一家提供商（不必先把它设为当前）。
  Future<(bool, String)> testProviderDetail(String providerId) async {
    final config =
        await ref.read(llmRegistryProvider.notifier).configFor(providerId);
    if (config.baseUrl.trim().isEmpty) {
      return (false, '这家还没填 Base URL。');
    }
    if (config.model.trim().isEmpty) {
      return (false, '这家还没有模型：先点「获取并缓存模型」，或手动添加一个模型名。');
    }
    try {
      await LlmClient.testConnection(config: config)
          .timeout(const Duration(seconds: 20));
      return (true, '');
    } on TimeoutException {
      return (false, '20 秒没有响应：地址不通或服务没起来。');
    } catch (e) {
      return (false, _friendlyError(e));
    }
  }

  void createSession() {
    final session = AiSession(
      id: 's${DateTime.now().millisecondsSinceEpoch}',
      title: '新会话',
    );
    state = state.copyWith(
      sessions: [...state.sessions, session],
      currentSessionId: session.id,
      toolRecords: const [],
      pendingPlan: const [],
      liveAgentEvents: const [],
      clearLiveText: true,
      clearError: true,
    );
    _persist();
  }

  /// 改会话名字。自动标题取的是首句提问，会话攒多了不一定认得出来，
  /// 所以两处会话管理（AI 页 / 悬浮窗）都给了就地改名。
  void renameSession(String id, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final sessions = [
      for (final s in state.sessions)
        if (s.id == id)
          AiSession(
            id: s.id,
            title: trimmed,
            messages: s.messages,
            createdAt: s.createdAt,
            updatedAt: s.updatedAt,
          )
        else
          s,
    ];
    state = state.copyWith(sessions: sessions);
    _persist();
  }

  void selectSession(String id) {
    final index = state.sessions.indexWhere((s) => s.id == id);
    if (index < 0) return;
    // 标记成"最近用过"，下次启动才会默认回到这个会话。
    final sessions = [...state.sessions];
    final old = sessions[index];
    sessions[index] = AiSession(
      id: old.id,
      title: old.title,
      messages: old.messages,
      createdAt: old.createdAt,
      updatedAt: DateTime.now(),
    );
    state = state.copyWith(
      sessions: sessions,
      currentSessionId: id,
      toolRecords: const [],
      pendingPlan: const [],
      clearError: true,
    );
    _persist();
  }

  void deleteSession(String id) {
    if (state.sessions.length <= 1) {
      clear();
      return;
    }
    final sessions =
        state.sessions.where((s) => s.id != id).toList(growable: false);
    final current = state.currentSessionId == id
        ? sessions.first.id
        : state.currentSessionId;
    state = state.copyWith(
      sessions: sessions,
      currentSessionId: current,
      toolRecords: const [],
      pendingPlan: const [],
    );
    _persist();
  }

  Future<void> testModel(String model) async {
    if (state.testingModel != null) return;
    state = state.copyWith(
      testingModel: model,
      clearError: true,
    );
    final config = await ref.read(llmConfigProvider.future);
    bool ok;
    try {
      await LlmClient.testConnection(
        config: _configFor(config, model: model),
      ).timeout(const Duration(seconds: 20));
      ok = true;
    } catch (_) {
      ok = false;
    }
    state = state.copyWith(
      testingModel: null,
      modelTestResults: {...state.modelTestResults, model: ok},
    );
  }

  /// 选模型（当前提供商内部换一个）。
  void setModel(String model) => setProviderAndModel(
        ref.read(llmRegistryProvider).active.id,
        model,
      );

  /// 选提供商 + 模型。模型弹窗现在是两步：先挑家，再挑模型。
  ///
  /// 两件事必须一起落地：先切家再选模型的话，中间那一瞬间当前模型属于
  /// 上一家，这时候恰好发出去的请求会带着"张冠李戴"的模型名。
  Future<void> setProviderAndModel(String providerId, String model) async {
    final registry = ref.read(llmRegistryProvider.notifier);
    final target = ref.read(llmRegistryProvider).byId(providerId);
    if (target == null) return;
    if (model.isNotEmpty) {
      await registry.setDefaultModel(providerId, model);
    }
    await registry.setActive(providerId);
    // setActive/setDefaultModel 都会触发投影，这里不用自己改 state。
  }

  /// 手动添加模型名（加到当前提供商名下）。
  ///
  /// /v1/models 不是所有网关都实现，有的只暴露部分模型；允许手填之后
  /// 这些名字要能活过一次"刷新模型"，所以单独记一份来源。
  Future<void> addManualModel(String model) =>
      addManualModelTo(ref.read(llmRegistryProvider).active.id, model);

  Future<void> addManualModelTo(String providerId, String model) async {
    final name = model.trim();
    if (name.isEmpty) return;
    final registry = ref.read(llmRegistryProvider);
    final target = registry.byId(providerId);
    if (target == null) return;
    final notifier = ref.read(llmRegistryProvider.notifier);
    await notifier.updateProvider(target.copyWith(
      manualModels: target.manualModels.contains(name)
          ? target.manualModels
          : [...target.manualModels, name],
      contextLimits: {
        ...target.contextLimits,
        name: target.contextLimits[name] ?? _guessContextLimit(name, null),
      },
      defaultModel: name,
    ));
    await notifier.setActive(providerId);
  }

  /// 移除一个模型（只影响本地列表；下次刷新若接口仍返回它会回来）。
  Future<void> removeModel(String model) async {
    final registry = ref.read(llmRegistryProvider);
    final target = registry.active;
    if (target.id.isEmpty) return;
    final models =
        target.models.where((m) => m != model).toList(growable: false);
    final manual =
        target.manualModels.where((m) => m != model).toList(growable: false);
    final limits = {...target.contextLimits}..remove(model);
    final rest = <String>{...models, ...manual}.toList()..sort();
    await ref.read(llmRegistryProvider.notifier).updateProvider(
          target.copyWith(
            models: models,
            manualModels: manual,
            contextLimits: limits,
            defaultModel: target.defaultModel == model
                ? (rest.isNotEmpty ? rest.first : '')
                : target.defaultModel,
          ),
        );
  }

  Future<void> setModelContextLimit(String model, int limit) async {
    final target = ref.read(llmRegistryProvider).active;
    if (target.id.isEmpty) return;
    await ref.read(llmRegistryProvider.notifier).updateProvider(
          target.copyWith(
            contextLimits: {...target.contextLimits, model: limit},
          ),
        );
  }

  void setReasoningEffort(int value) {
    state = state.copyWith(reasoningEffort: value.clamp(0, 3));
    _saveSettings();
  }

  void setAutoCompressThreshold(double value) {
    state = state.copyWith(
      autoCompressThreshold: value.clamp(0.3, 1.0),
    );
    _saveSettings();
  }

  /// 给一份基础配置补上"界面上现在选的东西"（模型、思考强度）。
  ///
  /// `keepModel: true` 用于子代理那份配置——它的模型是设置里单独指定的，
  /// 不能被主代理当前选的模型盖掉。
  LlmConfig _configFor(
    LlmConfig base, {
    String? model,
    bool keepModel = false,
  }) {
    final effectiveModel = model ??
        (keepModel
            ? base.model
            : (state.selectedModel.isNotEmpty
                ? state.selectedModel
                : base.model));
    return LlmConfig(
      baseUrl: base.baseUrl,
      model: effectiveModel,
      apiKey: base.apiKey,
      reasoningEffort: state.reasoningEffort,
      // 采样与透传参数都来自设置页，这里原样带上，别在中途丢掉。
      temperature: base.temperature,
      topP: base.topP,
      maxTokens: base.maxTokens,
      frequencyPenalty: base.frequencyPenalty,
      presencePenalty: base.presencePenalty,
      extraBody: base.extraBody,
      extraHeaders: base.extraHeaders,
      receiveTimeoutSeconds: base.receiveTimeoutSeconds,
    );
  }

  /// 流式缓冲。**不能**每来一片就 setState：一轮思考有几百上千片，
  /// 那等于让整个 AI 页每秒重建几十次，界面反而更卡、还会打断滚动。
  /// 攒在这里，按 [_liveFlushInterval] 统一刷。
  final StringBuffer _liveReasoning = StringBuffer();
  final StringBuffer _liveContent = StringBuffer();
  String _liveTool = '';
  Timer? _liveTimer;

  static const _liveFlushInterval = Duration(milliseconds: 80);

  /// 流式缓冲上限：只留尾部。整段思考在这一轮收尾时会完整落进
  /// 思考事件，缓冲里留全文纯属浪费——每次刷新都要重新拼一遍大字符串。
  static const _liveTailChars = 6000;

  static String _tail(String text) => text.length <= _liveTailChars
      ? text
      : '…${text.substring(text.length - _liveTailChars)}';

  void _appendAgentDelta(AgentDelta delta) {
    if (delta.reset) {
      if (_liveReasoning.isEmpty && _liveContent.isEmpty && _liveTool.isEmpty) {
        return;
      }
      _liveReasoning.clear();
      _liveContent.clear();
      _liveTool = '';
      _flushLive();
      return;
    }
    if (delta.reasoning.isNotEmpty) _liveReasoning.write(delta.reasoning);
    if (delta.content.isNotEmpty) _liveContent.write(delta.content);
    // 工具名一出来就立刻刷：用户等的就是"它开始动手了"这个信号。
    if (delta.toolName.isNotEmpty && delta.toolName != _liveTool) {
      _liveTool = delta.toolName;
      _flushLive();
      return;
    }
    _liveTimer ??= Timer(_liveFlushInterval, _flushLive);
  }

  void _flushLive() {
    _liveTimer?.cancel();
    _liveTimer = null;
    // 运行已经结束（或被停止）：这是一次迟到的刷新，别把清干净的界面写回去。
    if (!state.isLoading) {
      Logger.d('ai', 'live flush dropped: not loading');
      return;
    }
    // 只有快问正文窗需要全文；普通聊天窗/完整悬浮窗继续用 tail 省内存。
    final quickLive = ref.read(aiDockProvider).quickOpen &&
        ref.read(aiDockProvider).quickBusy;
    state = state.copyWith(
      liveReasoning: _tail(_liveReasoning.toString()),
      liveContent: _tail(_liveContent.toString()),
      liveContentFull: quickLive ? _liveContent.toString() : '',
      liveReasoningChars: _liveReasoning.length,
      liveContentChars: _liveContent.length,
      liveTool: _liveTool,
    );
  }

  void _clearLive() {
    _liveTimer?.cancel();
    _liveTimer = null;
    _liveReasoning.clear();
    _liveContent.clear();
    _liveTool = '';
  }

  void _appendAgentEvent(AgentEvent event) {
    _runEvents.add(event);
    state = state.copyWith(
      liveAgentEvents: [...state.liveAgentEvents, event],
    );
    // 每个工具边界落一次盘：闪退随时可能发生，而写 prefs 很便宜。
    // 思考事件不落盘（可能很长且很频繁），工具起止才是有价值的进度点。
    if (event.kind == AgentEventKind.toolEnd ||
        event.kind == AgentEventKind.toolStart) {
      unawaited(_saveActiveRun());
    }
  }

  /// 切换写操作确认策略。
  void setApprovalMode(AiApprovalMode mode) {
    if (state.approvalMode == mode) return;
    state = state.copyWith(approvalMode: mode);
    _saveSettings();
  }

  /// 中断正在运行的 Agent。已执行完的写操作不会回滚。
  /// 停止：立刻生效。
  ///
  /// 三件事同时做——掐掉正在飞的 HTTP 请求、作废这次运行的结果、马上把界面
  /// 收尾成"已中断"。以前只置了一个布尔标志，循环要走到下一个检查点才会退出，
  /// 最坏情况得等一次 180 秒的接收超时。
  void stopAgent() {
    if (!state.isLoading) return;
    _clearLive();
    _cancelToken?.cancel();
    _cancelToken = null;
    _runGeneration++;
    final current = state.currentSession;
    if (current != null) {
      _replaceSession(
        AiSession(
          id: current.id,
          title: current.title,
          messages: [
            ...current.messages,
            AiChatMessage(
              role: 'assistant',
              content: '已中断。上面的思考和工具结果都留着了——'
                  '你直接说下一步想干什么就行：接着往下做、换个方向、'
                  '或者当成一个全新的需求，我自己会判断。',
              createdAt: DateTime.now(),
              agentEvents: List<AgentEvent>.from(_runEvents),
              outcome: 'cancelled',
            ),
          ],
          createdAt: current.createdAt,
          updatedAt: DateTime.now(),
        ),
      );
    }
    state = state.copyWith(
      isLoading: false,
      liveAgentEvents: const [],
      clearLiveText: true,
      clearError: true,
    );
    unawaited(_clearActiveRun());
    unawaited(BrowserEngine.instance.settleAfterRun());
    // 中断往往是为了先发那条急事，这里立刻把排队里的第一条顶上去。
    unawaited(_drainQueue());
  }

  /// 把底层异常翻译成用户能看懂的话，并给出下一步。
  String _friendlyError(Object error) {
    final text = error.toString();
    // 证书要放在最前面判：自签名握手失败的文本里带 SocketException 字样，
    // 会被下面那条"域名解析失败"截走，把人引到检查网络上去。
    if (isCertError(error)) return certHint;
    if (isPlaintextToTlsError(error)) return schemeHint;
    if (text.contains('Failed host lookup') ||
        text.contains('SocketException')) {
      return '连不上 AI 服务（域名解析失败）。检查手机网络，或到设置里确认 Base URL 是否正确。';
    }
    if (text.contains('timeout') || text.contains('Timeout')) {
      return 'AI 服务响应超时。可以重试，或换一个更快的模型。';
    }
    if (text.contains('401') || text.contains('403')) {
      return 'AI 服务拒绝访问（鉴权失败）。到设置里检查 API Key。';
    }
    if (text.contains('429')) {
      return 'AI 服务限流了，稍等一下再试。';
    }
    return text;
  }

  Future<AgentResult> _runAgent(
    Set<String> confirmedKeys, {
    void Function(AgentEvent event)? onEvent,
    String userInput = '',
  }) async {
    // 清单是"这一轮"的东西，开跑先清掉上一轮残留。
    state = state.copyWith(livePlan: const AgentTaskPlan());
    final config = await ref.read(llmConfigProvider.future);
    final registry = QlToolRegistry(
      panelGetter: () => ref.read(currentPanelProvider),
    );
    final history = _historyWithAutoCompress(userInput: userInput);
    final token = AgentCancelToken();
    _cancelToken = token;
    try {
      // 基础工具集：子代理拿的就是这一份（不含任务代理工具，防止无限分裂）。
      final baseTools = _buildExternalTools();
      final llmConfig = _configFor(config);
      // 子代理可以走另一家提供商 / 另一个模型：派出去查资料的活用便宜快的
      // 模型更划算，贵的留给主代理做判断。没设过就还是主代理那份。
      final plan = ref.read(llmRegistryProvider).subAgent;
      final workerConfig = plan.overridesModel
          ? _configFor(
              await ref.read(llmRegistryProvider.notifier).subAgentConfig(),
              keepModel: true,
            )
          : llmConfig;
      AgentLoop spawnWorker() => AgentLoop(
            config: workerConfig,
            registry: QlToolRegistry(
              panelGetter: () => ref.read(currentPanelProvider),
            ),
            confirmedActionKeys: confirmedKeys,
            externalTools: baseTools,
            approvalMode: state.approvalMode,
            maxTurns: plan.maxTurns,
            cancelToken: token,
          );
      return await AgentLoop(
        config: llmConfig,
        registry: registry,
        confirmedActionKeys: confirmedKeys,
        externalTools: [
          ...baseTools,
          // 任务代理组只挂在主代理身上。
          ...AgentTeamTools.build(
            spawn: spawnWorker,
            seed: (task) => [
              LlmMessage(role: 'system', content: _workerPrompt()),
              LlmMessage(role: 'user', content: task),
            ],
            onEvent: onEvent,
            parallel: plan.parallel,
            workerModel:
                plan.overridesModel ? workerConfig.model : llmConfig.model,
          ),
        ],
        approvalMode: state.approvalMode,
        maxTurns: ref.read(llmRegistryProvider).mainMaxTurns,
        cancelToken: token,
        // 每轮 LLM 请求一回来就刷新顶部上下文/token，不用等整轮跑完。
        onUsage: (total, prompt, cache) {
          if (_cancelToken != token) return;
          state = state.copyWith(
            lastTokens: total,
            lastPromptTokens: prompt,
            lastCacheHitTokens: cache,
          );
        },
      ).run(
        history: history,
        onEvent: onEvent,
        onDelta: _appendAgentDelta,
        onPlan: (plan) => state = state.copyWith(livePlan: plan),
        onCanvas: (canvas) {
          // 生成即弹：用户等了半天，不该还要自己去点一下才看到成品。
          //
          // 分两种落点：悬浮窗模式下弹成同层的浮动窗口，AI 页里还是底部弹窗。
          // 原因是悬浮层画在路由 Navigator 之上，底部弹窗会被它整块盖住——
          // 用户只会看到"AI 说弹了个卡片，但屏幕上什么都没有"。
          final dock = ref.read(aiDockProvider);
          if (dock.expanded || dock.quickOpen || dock.quickBusy) {
            // 完整悬浮窗、快问模式都走浮动画布窗；只有 AI 页正文才用底部弹窗。
            ref.read(aiDockProvider.notifier).showCanvas(canvas);
            return;
          }
          final context = appNavigatorKey.currentContext;
          if (context != null) AiCanvasSheet.show(context, canvas);
        },
        onCanvasClose: (window) {
          final notifier = ref.read(aiDockProvider.notifier);
          if (window == '*') {
            notifier.closeAllCanvases();
          } else {
            notifier.closeCanvas(window);
          }
        },
      );
    } finally {
      if (_cancelToken == token) _cancelToken = null;
    }
  }

  static String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  /// 组装运行期扩展工具：元能力（记忆/技能/MCP 自管理）+ 技能读取 + MCP 工具。
  List<ExternalTool> _buildExternalTools() {
    final tools = <ExternalTool>[
      ...MetaTools.build(
        memory: ref.read(memoryProvider.notifier),
        skills: ref.read(skillProvider.notifier),
        mcp: ref.read(mcpProvider.notifier),
        mcpState: ref.read(mcpProvider),
        skillList: ref.read(skillProvider).skills,
      ),
      // 会话内工具结果缓存：上下文只留摘要 + key，模型要全文时按 key 取，
      // 不用把同一个文件/命令再跑一遍，也不会把几千字结果塞进历史撑爆 token。
      ExternalTool(
        name: 'tool_cache_read',
        description: '读取本会话内某次工具调用的完整原始返回（不会重新执行那个工具）。'
            '当系统记录里的工具结果被截断、或用户让你复述/查看之前读到的完整内容时使用。'
            'key 在系统记录的工具摘要里，形如 toolName|{"path":"..."}。'
            '注意这是缓存快照：文件/面板状态可能已变化，需要最新数据时直接用原工具。',
        parameters: const {
          'type': 'object',
          'properties': {
            'key': {
              'type': 'string',
              'description':
                  '缓存 key，例如 shell_read_file|{"path":"/workspace/dino.html"}'
            },
          },
          'required': ['key'],
        },
        origin: '会话结果缓存',
        invoke: (args) async {
          final key = args['key']?.toString().trim() ?? '';
          if (key.isEmpty) return 'key 不能为空。';
          // 完整事件序列：已落盘的历史 + 正在跑的 live（同一轮里先读后写再读缓存
          // 这种场景，写事件还在 live 里，没进 messages）。
          final events = <AgentEvent>[
            for (final m in state.messages)
              for (final e in m.agentEvents)
                if (e.kind == AgentEventKind.toolEnd) e,
            for (final e in state.liveAgentEvents)
              if (e.kind == AgentEventKind.toolEnd) e,
          ];
          var found = -1;
          for (var i = events.length - 1; i >= 0; i--) {
            if (_toolCacheKey(events[i]) == key) {
              found = i;
              break;
            }
          }
          if (found < 0) {
            final available = <String>{};
            for (final e in events) {
              if ((e.fullResult ?? e.result ?? '').trim().isEmpty) continue;
              available.add(_toolCacheKey(e));
            }
            return '没有找到 key=$key。\n当前会话可用缓存 key：\n'
                '${available.isEmpty ? '（无）' : available.join('\n')}';
          }
          final e = events[found];
          // 写操作之后缓存作废：比如 AI 先读脚本→改脚本→再读缓存，
          // 必须让 AI 知道这份是旧的，去用原工具拿最新内容，不能卡在循环里。
          for (var i = found + 1; i < events.length; i++) {
            if (!events[i].isWrite) continue;
            return '缓存已失效：${e.toolName} 的结果发生在 ${events[i].toolName}'
                '（写操作）之后就不再可信。'
                '请直接用原工具重新读取最新内容，不要使用这份旧缓存，也不要重复改写。';
          }
          final full = e.fullResult ?? e.result ?? '';
          if (full.trim().isEmpty) return '这个 key 对应的结果为空。';
          return '${e.toolName} 完整返回（${full.length} 字，来自本会话缓存）：\n$full';
        },
      ),
    ];

    // 浏览器内核：过 CF 验证 / 抓包 / 注入脚本都在这一组里。
    tools.addAll(BrowserTools.build());

    // 可视化代码编辑：**只有用户真开着编辑器才挂这组工具**。
    //
    // 编辑器没开的时候挂着它们，模型会去"试一下"——editor_list 或
    // editor_patch 各一轮，拿回来一句"没有打开任何编辑器"，纯浪费。
    // 工具表里干脆没有，它就直接走 script_* / shell_*。
    if (EditorBus.instance.hasEditor) {
      tools.addAll(EditorTools.build());
    }

    final skillNotifier = ref.read(skillProvider.notifier);
    if (ref.read(skillProvider).enabled.isNotEmpty) {
      tools.add(
        ExternalTool(
          name: 'skill_read',
          description: '读取一个技能的操作手册或附件代码/资源文件。'
              '看到匹配场景时先读手册再动手；需要看技能里的脚本时传 path。',
          parameters: const {
            'type': 'object',
            'properties': {
              'name': {'type': 'string', 'description': '技能名，例如 script-debug'},
              'path': {
                'type': 'string',
                'description': '可选。技能内相对路径，如 scripts/check.py',
              },
            },
            'required': ['name'],
          },
          origin: '本地技能库',
          invoke: (args) async => skillNotifier.read(
            args['name']?.toString() ?? '',
            path: args['path']?.toString(),
          ),
        ),
      );
      tools.add(
        ExternalTool(
          name: 'skill_install',
          description: '从市面技能仓库/GitHub/直链完整安装一个技能（含 SKILL.md、'
              'scripts 代码、references 资料）。'
              '输入可以是 GitHub 仓库首页、技能子目录、或 SKILL.md raw 直链。'
              '用户说"装个技能/这个仓库不错帮我装成技能"时用这个，不要只抓 README 拼个简化版。',
          parameters: const {
            'type': 'object',
            'properties': {
              'url': {'type': 'string', 'description': 'GitHub 仓库/目录/直链'},
            },
            'required': ['url'],
          },
          origin: '技能市场',
          isWrite: true,
          invoke: (args) async =>
              skillNotifier.importFromSource(args['url']?.toString() ?? ''),
        ),
      );
      tools.add(
        ExternalTool(
          name: 'skill_run',
          description: '把技能里的某个脚本（如 scripts/xxx.py、scripts/xxx.js）'
              '落盘到本机终端 /workspace/skills/<技能名>/ 并直接运行。'
              '运行前先 skill_read 看手册确认脚本用途和参数。',
          parameters: const {
            'type': 'object',
            'properties': {
              'name': {'type': 'string', 'description': '技能名'},
              'script': {
                'type': 'string',
                'description': '技能内脚本路径，如 scripts/check.py',
              },
              'args': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': '传给脚本的参数（可选）',
              },
              'timeoutSeconds': {
                'type': 'integer',
                'description': '超时，默认 60',
              },
            },
            'required': ['name', 'script'],
          },
          origin: '本地技能库',
          isWrite: true,
          invoke: (args) async {
            String clip(String s, [int n = 20000]) =>
                s.length > n ? '${s.substring(0, n)}\n…（输出已截断）' : s;
            final name = args['name']?.toString() ?? '';
            final script = args['script']?.toString() ?? '';
            final skill = skillNotifier.skillByName(name);
            if (skill == null) {
              return '没有技能「$name」。可用：${skillNotifier.enabledNames.join('、')}';
            }
            final file = skillNotifier.skillFile(name, script);
            if (file == null) {
              final avail = skill.files.isEmpty
                  ? '（没有附件文件）'
                  : skill.files.map((f) => f.path).join('、');
              return '技能「$name」没有脚本「$script」。附件：$avail';
            }
            final ext = file.path.toLowerCase();
            final bin = ext.endsWith('.js')
                ? 'node'
                : (ext.endsWith('.sh') || ext.endsWith('.bash'))
                    ? 'bash'
                    : 'python3';
            final base = '/workspace/skills/${skill.name}';
            final guestPath = '$base/${file.path}';
            final timeout = (args['timeoutSeconds'] as num?)?.toInt() ?? 60;
            final argList = <String>[
              for (final a in (args['args'] as List? ?? const [])) a.toString(),
            ];
            return ShellLock.run(
              ShellLock.terminal,
              () async {
                final bridge = ProotBridge();
                final parent =
                    guestPath.substring(0, guestPath.lastIndexOf('/'));
                await bridge.exec(command: 'mkdir', args: ['-p', parent]);
                await bridge.writeFile(path: guestPath, content: file.content);
                final result = await bridge.exec(
                  command: bin,
                  args: [guestPath, ...argList],
                  cwd: base,
                  timeoutSeconds: timeout,
                );
                return '技能脚本已运行：$bin $guestPath\n'
                    '退出码：${result.exitCode}\n'
                    'stdout：${clip(result.stdout)}\n'
                    'stderr：${clip(result.stderr)}';
              },
              label: 'skill_run:$name/${file.path}',
              timeout: Duration(seconds: timeout + 60),
            );
          },
        ),
      );
      tools.add(
        ExternalTool(
          name: 'skill_export',
          description: '把技能里的附件文件（含二进制 tarball/zip）落盘到'
              ' /workspace/skills/<技能名>/<path>。'
              '文本直接写盘；二进制用 base64 解码写盘。'
              '装带资源的市面技能时先 skill_export，再 shell_archive_extract 解压、'
              '或 shell_exec 执行。',
          parameters: const {
            'type': 'object',
            'properties': {
              'name': {'type': 'string', 'description': '技能名'},
              'path': {
                'type': 'string',
                'description': '技能内附件路径，例如 scripts/tool.tar.gz',
              },
            },
            'required': ['name', 'path'],
          },
          origin: '本地技能库',
          isWrite: true,
          invoke: (args) async {
            final name = args['name']?.toString() ?? '';
            final path = args['path']?.toString() ?? '';
            final skill = skillNotifier.skillByName(name);
            if (skill == null) {
              return '没有技能「$name」。可用：${skillNotifier.enabledNames.join('、')}';
            }
            final file = skillNotifier.skillFile(name, path);
            if (file == null) {
              final avail = skill.files.isEmpty
                  ? '（没有附件文件）'
                  : skill.files.map((f) => f.path).join('、');
              return '技能「$name」没有附件「$path」。附件：$avail';
            }
            final base = '/workspace/skills/${skill.name}';
            final guestPath = '$base/${file.path}';
            final parent = guestPath.substring(0, guestPath.lastIndexOf('/'));
            return ShellLock.run(
              ShellLock.file(guestPath),
              () async {
                final bridge = ProotBridge();
                await bridge.exec(command: 'mkdir', args: ['-p', parent]);
                final binaryMode =
                    file.binary || SkillFile.isBinaryPath(file.path);
                if (binaryMode) {
                  final b64 = file.content.replaceAll(RegExp(r'\s'), '');
                  List<int> decoded;
                  try {
                    decoded = base64Decode(b64);
                  } catch (_) {
                    return '附件「${file.path}」不是合法的 base64 二进制数据：'
                        '它很可能来自旧版本导入的 UTF-8 损坏数据。'
                        '请先删除该技能，再用 skill_install 从原仓库重新导入一次；'
                        '新版本会按二进制原样抓取并保存。';
                  }
                  final tmp = '/workspace/.ai/export_'
                      '${DateTime.now().microsecondsSinceEpoch}.b64';
                  await bridge.writeFile(path: tmp, content: b64);
                  final result = await bridge.exec(
                    command: 'sh',
                    args: [
                      '-c',
                      'base64 -d ${_quote(tmp)} > '
                          '${_quote(guestPath)}'
                          ' && rm -f ${_quote(tmp)}',
                    ],
                    timeoutSeconds: 120,
                  );
                  if (result.exitCode != 0) {
                    return '二进制导出失败：${result.stderr}';
                  }
                  return '已导出二进制附件：$guestPath'
                      '（${decoded.length} 字节）';
                }
                await bridge.writeFile(path: guestPath, content: file.content);
                return '已导出文本附件：$guestPath';
              },
              label: 'skill_export:$name/${file.path}',
              timeout: const Duration(seconds: 180),
            );
          },
        ),
      );
    }

    final mcp = ref.read(mcpProvider);
    final mcpNotifier = ref.read(mcpProvider.notifier);
    // 工具多时只挂 3 个网关入口，目录走提示词（省下每轮几万 token 的 schema）。
    if (McpGateway.shouldCollapse(mcp.tools.length)) {
      tools.addAll(McpGateway.build(state: mcp, notifier: mcpNotifier));
      return tools;
    }
    for (final tool in mcp.tools) {
      final server = mcp.servers.where((s) => s.id == tool.serverId);
      if (server.isEmpty || !server.first.enabled) continue;
      final schema = tool.schema.isEmpty
          ? const {'type': 'object', 'properties': <String, dynamic>{}}
          : tool.schema;
      tools.add(
        ExternalTool(
          name: tool.localName,
          description:
              '[MCP:${server.first.name}] ${tool.description.isEmpty ? tool.name : tool.description}',
          parameters: schema,
          origin: 'MCP ${server.first.name}',
          // MCP 不声明副作用。按名字保守分类：像查询的当只读直接执行，
          // 其余当危险写操作（严格与仅危险都会先问用户）。
          isWrite: !tool.looksReadOnly,
          danger: !tool.looksReadOnly,
          invoke: (args) => mcpNotifier.callTool(tool.localName, args),
        ),
      );
    }
    return tools;
  }

  /// 把一次运行里所有工具调用写进审计。
  ///
  /// 之前审计只记"计划挂起/确认/拒绝"三种事件，于是在"全部放行"策略下永远
  /// 是空的——用户看到的就是"不管执行什么都显示空"。真正该记的是每一次
  /// 工具调用本身。
  void _auditRun(AgentResult result) {
    final entries = <AuditLog>[];
    for (final r in result.toolRecords) {
      final target = _auditTarget(r.args);
      entries.add(
        AuditLog(
          time: r.createdAt ?? DateTime.now(),
          module: _auditModule(r.toolName),
          action: r.toolName,
          detail: [
            if (target.isNotEmpty) target,
            if (r.durationMs != null && r.durationMs! > 0) '${r.durationMs}ms',
            if (r.result.isNotEmpty)
              r.result.length > 120
                  ? '${r.result.substring(0, 120).replaceAll('\n', ' ')}…'
                  : r.result.replaceAll('\n', ' '),
          ].join(' · '),
          result: r.status.isEmpty ? 'ok' : r.status,
        ),
      );
    }
    entries.add(
      AuditLog(
        time: DateTime.now(),
        module: 'ai',
        action: 'agent_run',
        detail: '${result.turns} 轮 · ${result.toolRecords.length} 次工具 · '
            '${result.usage.totalTokens} tokens',
        result: result.outcome.name,
      ),
    );
    ref.read(auditProvider.notifier).addAll(entries);
  }

  /// 按工具名前缀归类模块，审计列表里好筛。
  String _auditModule(String tool) {
    if (tool.startsWith('cron_')) return 'cron';
    if (tool.startsWith('script_')) return 'script';
    if (tool.startsWith('env_')) return 'env';
    if (tool.startsWith('dep_')) return 'dep';
    if (tool.startsWith('config_')) return 'config';
    if (tool.startsWith('log_')) return 'log';
    if (tool.startsWith('system_')) return 'system';
    if (tool.startsWith('shell_')) return 'shell';
    if (tool.startsWith('memory_')) return 'memory';
    if (tool.startsWith('skill_')) return 'skill';
    if (tool.startsWith('mcp_')) return 'mcp';
    return 'ai';
  }

  String _auditTarget(Map<String, dynamic> args) {
    for (final key in [
      'name',
      'id',
      'path',
      'file',
      'command',
      'query',
      'content'
    ]) {
      final value = args[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isEmpty) continue;
      return text.length > 60 ? '${text.substring(0, 60)}…' : text;
    }
    return '';
  }

  void _replaceSession(AiSession next) {
    final sessions = [
      for (final s in state.sessions)
        if (s.id == next.id) next else s,
    ];
    state = state.copyWith(sessions: sessions);
    _persist();
  }

  String _titleFrom(String text) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length <= 12 ? clean : '${clean.substring(0, 12)}…';
  }

  int _guessContextLimit(String model, int? current) {
    if (current != null && current > 0) return current;
    final name = model.toLowerCase();
    if (name.contains('128k') || name.contains('131072')) return 128000;
    if (name.contains('64k') || name.contains('65536')) return 64000;
    if (name.contains('32k') || name.contains('32768')) return 32000;
    if (name.contains('16k') || name.contains('16384')) return 16000;
    if (name.contains('1m') || name.contains('1000k')) return 1000000;
    // 兜底用设置页里的"默认上下文长度"，比硬编码 8000 更贴近实际模型。
    return ref.read(settingsProvider).llmDefaultContextLimit;
  }
}

final chatProvider =
    NotifierProvider<ChatNotifier, ChatState>(ChatNotifier.new);
