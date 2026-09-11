import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/llm/llm_client.dart';
import '../../../core/network/api_exception.dart';
import '../models/agent_event.dart';
import '../models/agent_task_plan.dart';
import '../models/canvas_result_bus.dart';
import '../models/approval_mode.dart';
import '../models/ai_plan.dart';
import '../models/tool_call_record.dart';
import 'external_tool.dart';
import 'tool_registry.dart';

/// 用户可以随时中断正在跑的 Agent。
class AgentCancelToken {
  bool _cancelled = false;

  /// 当前正在飞的那次 LLM 请求。
  ///
  /// 光有布尔标志不够：请求已经发出去以后，循环卡在 await 上，最长要等
  /// 180 秒的 receiveTimeout 才会回到能检查标志的地方——用户看到的就是
  /// "点了停止半天没反应"。所以取消时必须把 HTTP 请求本身也掐掉。
  CancelToken? _http;

  bool get isCancelled => _cancelled;

  /// 每轮请求前登记，请求结束后清掉。
  set httpToken(CancelToken? token) {
    if (_cancelled) {
      token?.cancel('user cancelled');
      return;
    }
    _http = token;
  }

  void cancel() {
    _cancelled = true;
    _http?.cancel('user cancelled');
    _http = null;
  }
}

class AgentCancelledException implements Exception {
  const AgentCancelledException();

  @override
  String toString() => '任务已被用户中断';
}

enum AgentOutcome {
  completed,
  failed,
  awaitingConfirm,

  /// 模型主动向用户提问，等人回答后才能继续。
  awaitingInput,
  cancelled,
  exhausted,
}

class AgentResult {
  const AgentResult({
    this.content = '',
    this.toolRecords = const [],
    this.pendingActions = const [],
    this.outcome = AgentOutcome.completed,
    this.usage = const LlmUsage(),
    this.turns = 0,
    this.question,
    this.lastPromptTokens = 0,
    this.lastCacheHitTokens = 0,
    this.taskPlan = const AgentTaskPlan(),
    this.canvases = const [],
  });

  final String content;
  final List<ToolCallRecord> toolRecords;
  final List<AiPlanAction> pendingActions;
  final AgentOutcome outcome;
  final LlmUsage usage;
  final int turns;

  /// outcome == awaitingInput 时，模型向用户提的问题。
  final AgentQuestion? question;

  /// 最后一次请求命中缓存的 token 数。
  ///
  /// 必须与 [lastPromptTokens] 同属一轮，否则"命中率"会算出 195% 这种鬼数字
  /// （累计缓存 ÷ 单轮上下文）。
  final int lastCacheHitTokens;

  /// 最后一次请求的 prompt_tokens。
  ///
  /// 这是"上下文实际占了多少"的唯一可信数字：usage.totalTokens 是整轮 Agent
  /// 累加的**计费量**（每一轮都要重发全部历史，所以会远大于上下文本身），
  /// 拿它算上下文百分比必然虚高。两个数字含义不同，界面要分开显示。
  final int lastPromptTokens;

  /// 本轮的任务清单（模型自己拆的）。空表示它没拆。
  final AgentTaskPlan taskPlan;

  /// 本轮生成的 HTML 互动卡片。
  final List<AiCanvas> canvases;
}

/// 模型主动提问：一句问题 + 可选的候选答案。
///
/// 之前 Agent 只能"猜着办"或者在正文里问一句然后自己收工，用户回答了也接不上。
/// 现在提问是一次真正的挂起：循环停在这里，等 UI 把答案作为新一轮输入送回来。
class AgentQuestion {
  AgentQuestion({
    required this.question,
    this.options = const [],
    this.allowFreeText = true,
    this.context = '',
  }) : id = ++_seq;

  static int _seq = 0;

  /// 每个提问一个自增号。
  ///
  /// 界面拿它当 Widget key：没有它的话，第二次问同样一句话时 Flutter 会复用
  /// 上一张卡片的 State，而那张卡片的"已回答"标记还是 true——按钮全灰，
  /// 看起来就是"提问窗口不出现了"。
  final int id;

  final String question;

  /// 候选答案，UI 直接渲染成可点按钮（"能可视化就可视化"）。
  final List<String> options;

  /// 是否允许自由输入。
  final bool allowFreeText;

  /// 为什么要问，帮用户判断。
  final String context;
}

/// 持续型 Agent：OpenAI 兼容 function calling + 只读直执行 / 写操作计划确认。
///
/// 相比初版的改进：
/// - tool 结果按协议回填 tool_call_id，避免服务端把工具轮次当噪音丢掉；
/// - 只读结果缓存会在任何写操作后失效，既拦掉真正的重复查询，也不会读到过期数据；
/// - 模型必须调用 task_complete 宣告成败，否则会被追问继续干活，不会中途自我总结收工；
/// - 工具输出统一裁剪，长日志不再冲爆上下文；
/// - 支持取消、token 记账、轮次预算提醒。
class AgentLoop {
  /// 打回簿记回声时引用给模型看的例句。
  static const _echoHint = '这一轮调用过的工具：ask_user';

  AgentLoop({
    required this.config,
    required this.registry,
    required this.confirmedActionKeys,
    this.externalTools = const [],
    this.approvalMode = AiApprovalMode.cautious,
    this.maxTurns = 200,
    this.cancelToken,
    this.onUsage,
    this.outputCleaner,
  });

  final LlmConfig config;
  final QlToolRegistry registry;
  final Set<String> confirmedActionKeys;

  /// 运行期注入的扩展工具（MCP / 技能）。与内置工具同等参与确认策略。
  final List<ExternalTool> externalTools;

  /// 确认策略：严格 / 仅危险 / 全部放行。
  final AiApprovalMode approvalMode;
  final int maxTurns;
  final AgentCancelToken? cancelToken;

  /// 每完成一轮 LLM 请求就回调一次最新用量，界面据此实时刷新上下文/token。
  final void Function(int totalTokens, int promptTokens, int cacheHitTokens)?
      onUsage;

  /// 输出整理插件：把模型原始输出（正文/思考）清理成展示文本。
  /// 返回 null 表示插件未生效，保留原文本。
  final String? Function(String)? outputCleaner;

  static const _maxToolResultChars = 30000;

  /// 工具结果在历史里的"退役"长度。
  ///
  /// 同一段 30000 字的日志会在**每一轮**被完整重发，跑 10 轮就是 10 倍开销。
  /// 模型真正需要全文的时候只有紧接着的那几轮，之后它已经把结论写进正文了。
  /// 所以隔了 [_toolResultFreshTurns] 轮以上的工具结果压缩到这个长度。
  static const _agedToolResultChars = 2000;

  /// 最近几轮的工具结果保持全文。
  static const _toolResultFreshTurns = 3;

  /// 只读结果最多复用这么久。超过就重新跑一次——面板和本机的状态一直在变，
  /// "我们没写过"不代表"它没变"。
  static const _readCacheTtl = Duration(seconds: 45);

  /// 单个工具的执行上限（看门狗）。
  ///
  /// 没有这道闸门的后果是实测出来的：某个工具卡在网络/锁/子进程上不返回，
  /// 整个 Agent 就停在那儿——界面上是一个转不完的圈，用户等半天没有任何进度，
  /// 只能自己点停止。工具那层各有各的超时（甚至没有），这里再兜一层统一的死线：
  /// 到点就把这一次调用判成失败，把"超时了"当成工具结果交给模型，让它换路走。
  static const _toolTimeout = Duration(seconds: 75);

  /// 天生慢的工具给更长的死线：跑脚本、执行命令、开网页、装依赖本来就慢，
  /// 用 75 秒去卡它们只会把正常任务打断。
  static const _slowToolTimeout = Duration(seconds: 300);

  static Duration _timeoutFor(String name) {
    const slow = [
      'shell_exec',
      'shell_script',
      'shell_install',
      'cron_run',
      'script_run',
      'browser_open',
      'browser_control',
      'browser_fetch',
      'browser_script',
      'browser_wait',
      'dependency_',
      'panel_update',
      'editor_run',
      // 装技能可能拉整个仓库目录（含脚本/资源/二进制），天然是慢操作；
      // 跑技能脚本、导出/写入大二进制、解压归档也一样。
      'skill_install',
      'skill_run',
      'skill_export',
      'shell_write_binary',
      'shell_read_binary',
      'shell_archive_extract',
    ];
    return slow.any(name.startsWith) ? _slowToolTimeout : _toolTimeout;
  }

  /// 天生一直在变的工具：结果**永不复用**。
  ///
  /// 日志在长、任务在跑、磁盘在写、页面在刷新，复用等于给用户看旧照片。
  static bool _isVolatileTool(String name) {
    const volatile = [
      'log_',
      'cron_log',
      'cron_list',
      // 订阅在拉取时状态会自己 queued → running → idle，日志也一直在长：
      // 复用旧结果会让模型死咬"还在拉"或者提前宣布"已经拉完"。
      'sub_list',
      'sub_log',
      'system_info',
      'shell_exec',
      'shell_script',
      'browser_capture',
      'browser_console',
      'browser_read',
      'editor_read',
      'editor_log',
      'task_status',
    ];
    return volatile.any(name.startsWith);
  }

  /// 这段正文是不是"在提问"。
  ///
  /// 用来抓一个很具体的翻车：追问链问到第三、第四个问题时，模型不再调
  /// ask_user，而是把问题写进正文——界面上没有提问卡、也不会挂起等答案，
  /// 用户看到的就是"提问不调工具了"。
  static bool looksLikePlainQuestion(String text) {
    final body = text.trim();
    if (body.isEmpty) return false;
    // 只看**最后一句**，不是最后 N 个字。
    //
    // 按字数截尾会误判："那句 Cannot find module? 是依赖没装，我已经装上了"——
    // 问号在中间，结论在末尾，这是陈述句。按句子切开取最后一段就分得清了。
    final sentences = body
        .split(RegExp(r'[。！!；;\n]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final last = sentences.isEmpty ? body : sentences.last;
    if (last.contains('？') || last.contains('?')) return true;
    const heads = ['请问', '请告诉我', '你想', '要不要', '需要我', '选哪', '哪一个', '填什么'];
    return heads.any(last.contains);
  }

  /// 我们自己塞进历史的簿记原话。
  ///
  /// 现场故障：连问三个问题，第三问模型不调 ask_user 了，气泡里直接吐出
  /// 「这一轮调用过的工具：ask_user」。那句是 chat_provider 给历史加的系统
  /// 记录——以前它被拼在 assistant 消息末尾，模型于是把"我的回复里提一句
  /// 调用过 ask_user"当成了合法的提问方式。
  ///
  /// 源头已经改掉（簿记搬到 user 一侧，见 ChatNotifier._historyNote），
  /// 这里是兜底：模型真抄了就当"这一轮白跑"，拽回去让它真的调工具。
  static final _bookkeepingEcho = RegExp(
    r'(这一轮|上一轮)(调用过|执行到|已调用)的工具|'
    r'(通过|我是调)\s*ask_user\s*工具(问出去|提问)|'
    r'正文里写问号不算提问|系统记录\s*·',
  );

  /// 正文是不是在抄系统簿记（而不是真的回答/真的调工具）。
  static bool echoedBookkeeping(String text) => _bookkeepingEcho.hasMatch(text);

  /// 把抄来的簿记句子从正文里剔掉，返回剩下的真话。
  static String stripBookkeeping(String text) {
    final kept = _splitSentences(text)
        .where((s) => !_bookkeepingEcho.hasMatch(s))
        .join(' ')
        .replaceAll(RegExp(r'[（(]\s*[）)]'), '')
        .trim();
    return kept;
  }

  /// 客套收尾语：这些不是真问题，答不答都不影响任务。
  ///
  /// 不能一见问号就拦：正常收尾说一句"还需要我做别的吗？"是礼貌，
  /// 把它也拽回 ask_user 会变成每次干完活都强行弹一张提问卡。
  static final _politeCloser = RegExp(
    r'(还(需要|有什么|要不要)|需要我(再|帮你)?(做|看|查|加)?(别的|其他|点什么)|'
    r'还想(要|让我)|要我继续(吗|么)|是否还需要|有别的(事|需求)|随时(叫我|说)|'
    r'其他需求|还有什么(想|要)|需要的话)',
  );

  /// "不答就没法往下走"的问题。命中的关键词都要求用户**给出信息或做选择**。
  static final _blockingHeads = RegExp(
    r'(请(问|告诉我|提供|确认|指定|给我)|需要你(提供|确认|决定|指定)|'
    r'你想(要|用|选|让我)|要不要(我)?(帮你)?(改|删|建|跑|装|启用)|'
    r'选(哪|一个|哪个)|哪(一个|个|台|条|份)|用(哪|什么)|填(什么|哪)|'
    r'是(哪|什么|多少)|多少|什么时候|叫什么|(用户名|密码|token|地址|端口|路径)是)',
  );

  /// 按句子切开，**问号自己算一句的结尾**（并且保留问号）。
  ///
  /// 不能只按 `。；\n` 切：像"环境变量要写进哪个面板？还需要我做别的吗？"
  /// 会被当成一整句，末尾那句客套一命中就把前面真正的问题一起放过了。
  static List<String> _splitSentences(String body) {
    final out = <String>[];
    final buf = StringBuffer();
    void flush() {
      final t = buf.toString().trim();
      if (t.isNotEmpty) out.add(t);
      buf.clear();
    }

    for (final ch in body.split('')) {
      if ('。！!；;\n'.contains(ch)) {
        flush();
        continue;
      }
      buf.write(ch);
      // 问号连着写进去再断句：判断"这句在问话"要靠它。
      if (ch == '？' || ch == '?') flush();
    }
    flush();
    return out;
  }

  /// 收尾正文里是不是夹着一个"本该用 ask_user 问出去"的问题。
  ///
  /// 用户原话：**"四个提问，前三个好好的，第四个因为收尾导致并无调用提问工具，
  /// 这个问题变成收尾提出不是提问工具提出"**。
  ///
  /// 机制：前几问都走 ask_user（每问一次就挂起，界面弹提问卡）。到最后一问时
  /// 模型觉得"活干完了"，于是调 task_complete 收尾，把还没问的那一问塞进
  /// summary 里。task_complete 一命中就 return，问题只剩一段普通文字：
  /// 界面不弹提问卡、不挂起等答案，用户以为 AI 自己定了，实际它在等回话。
  ///
  /// 返回那句问题（空字符串 = 没有需要问的东西）。
  static String blockingQuestion(String text) {
    final body = text.trim();
    if (body.isEmpty) return '';
    final sentences = _splitSentences(body);
    // 从后往前找：真正卡住流程的那问一般在收尾语的末段。
    for (final sentence in sentences.reversed) {
      final hasMark = sentence.contains('？') || sentence.contains('?');
      if (!hasMark && !_blockingHeads.hasMatch(sentence)) continue;
      // 客套话跳过，继续往前找——"都好了，还需要别的吗？"里那句客套不算。
      if (_politeCloser.hasMatch(sentence)) continue;
      if (!hasMark && !_blockingHeads.hasMatch(sentence)) continue;
      // 只有问号、没有任何"要信息"的字眼：太弱，当客套处理。
      if (hasMark && !_blockingHeads.hasMatch(sentence)) continue;
      return sentence;
    }
    return '';
  }

  /// 正文在**照抄提问卡的排版**吗。
  ///
  /// 现场故障（用户实录）：让它连问三个问题，第一问规规矩矩调 ask_user，
  /// 第二问的气泡里直接躺着
  ///
  ///     哈哈丰盛就好，一天都有精神！🍳
  ///     ❓第二个问题：最近天气开始转凉，你晚上一般几点睡？
  ///     （日常闲聊第二个问题）
  ///     候选：10点前，养生党 / 11点左右，正常作息 / …
  ///
  /// 过程卡里只有"思考 → 收尾"，一次工具调用都没有。
  ///
  /// `❓`、`（说明）`、`候选：a / b` 这套排版是**界面自己渲染**提问卡时拼出来的
  /// （见 ChatNotifier 里组装 assistantContent 的那段），它被原样存进了消息、
  /// 又随历史发回给模型。模型看到"我上一条回复就是这么写的"，第二问就照抄格式
  /// 手写一遍——它以为这样就算问了，界面却不会弹卡、也不会挂起等答案。
  ///
  /// 治本在历史那侧（不再把这套排版塞进 assistant 正文），这里是拦截：
  /// 一看到自家排版出现在正文里，就当"这一问没问出去"。
  /// `❓` 开头的行——最硬的信号，界面之外没人会这么写。
  static final _cardMarker = RegExp(r'(^|\n)\s*❓');

  /// `候选：a / b` 行。单独出现不算（正常回答里也可能列候选），
  /// 必须同时存在一句问话才算在"手写提问卡"。
  static final _cardOptions = RegExp(r'(^|\n)\s*候选\s*[：:]');

  /// 从抄来的排版里把问题本身抠出来（抠不到就返回整段）。
  static String questionCardEcho(String text) {
    final marked = _cardMarker.hasMatch(text);
    final optioned = _cardOptions.hasMatch(text) &&
        (text.contains('？') || text.contains('?'));
    if (!marked && !optioned) return '';
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.startsWith('❓')) {
        final q = t.replaceFirst('❓', '').trim();
        if (q.isNotEmpty) return q;
      }
    }
    // 没有 ❓ 行但有"候选："：问题一般就在它上面那行。
    final lines = text.split('\n').map((l) => l.trim()).toList();
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'^候选\s*[：:]').hasMatch(lines[i]) && i > 0) {
        for (var j = i - 1; j >= 0; j--) {
          if (lines[j].isNotEmpty) return lines[j];
        }
      }
    }
    return text.trim();
  }

  /// 正文里那个"本该用 ask_user 问出去、结果只写成了文字"的问题。
  ///
  /// 三级判据，从强到弱：
  /// 1. 照抄提问卡排版（`❓` / `候选：`）——最硬的信号，见 [questionCardEcho]；
  /// 2. [blockingQuestion]：任何位置上"不答就没法往下走"的那一问；
  /// 3. [looksLikePlainQuestion]：最后一句在问话。
  ///
  /// 为什么不能只留第 3 条：现场那条正文的**最后一行是"候选：…"**，
  /// 问句夹在中间，只看最后一句就永远判不出来。
  static String unaskedQuestion(String text) {
    final body = text.trim();
    if (body.isEmpty) return '';
    final echo = questionCardEcho(body);
    if (echo.isNotEmpty) return echo;
    final blocking = blockingQuestion(body);
    if (blocking.isNotEmpty) return blocking;
    // 最后一档：末句在问话，但没有"要信息"的字眼——闲聊式提问就长这样
    //（"今天早上你吃早餐了吗？"里一个 blockingHeads 关键词都没有）。
    // 客套收尾必须排除掉，否则一句"还需要我做别的吗？"就能触发打回重来。
    if (looksLikePlainQuestion(body)) {
      final sentences = _splitSentences(body);
      final last = sentences.isEmpty ? body : sentences.last;
      if (!_politeCloser.hasMatch(last)) return last;
    }
    return '';
  }

  /// 正文在**声称自己已经调过工具**吗（过去时的口气）。
  static final _claimVerbs = RegExp(
    r'(已(经)?(调用|执行|运行|查(询|看)|读取|获取)|我(调用|执行|运行|查|读|拉)了|'
    r'调用(了|完|过|结果|返回)|执行(了|完|过|结果|返回)|工具(调用|返回|结果)|'
    r'(结果|输出|返回|日志|内容)(如下|显示|是)|根据(工具|返回|查询)(的)?结果)',
  );

  /// 正文里点名提到的工具名（只认真实存在的名字，避免把普通词当工具）。
  static List<String> mentionedTools(String text, Iterable<String> known) {
    if (text.isEmpty) return const [];
    final hit = <String>[];
    for (final name in known) {
      if (name.length < 4) continue;
      if (text.contains(name)) hit.add(name);
    }
    return hit;
  }

  /// 这一轮的正文是不是在"编工具结果"。
  ///
  /// 用户原话：**"AI 说调用工具结果没调用就说调用完了"**。模型有时把工具调用
  /// 当成一段话写出来（"我已经执行了 shell_exec，输出如下…"），实际一个请求
  /// 都没发过——底下那段"输出"全是编的。这种回复绝不能当成答完收工。
  ///
  /// 两条独立线索，命中任一条就算：
  /// ① 正文里点名了某个真实工具，而这个工具在本次运行里根本没有执行记录；
  /// ② 整场一次工具都没跑过，正文却带着"已执行 + 结果如下"这种口气。
  static String fakeToolClaim({
    required String content,
    required Iterable<String> ranTools,
    required Iterable<String> knownTools,
  }) {
    final text = content.trim();
    if (text.isEmpty) return '';
    final ran = ranTools.toSet();
    // 按句子切：判定必须落在**同一句**里（"我执行了 shell_exec，输出如下"），
    // 否则"上次那轮 cron_list 的结果我记着"这种回忆句会被冤枉。
    final sentences = text
        .split(RegExp(r'[。！!；;\n]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    // 指向"以前那轮"的句子一律放过：历史里的工具结果确实是它做过的。
    final pastRef = RegExp(r'之前|上次|上一轮|上一次|先前|早先|刚才那|历史(里|中)|已有的');
    for (final line in sentences) {
      if (!_claimVerbs.hasMatch(line)) continue;
      if (pastRef.hasMatch(line)) continue;
      final ghosts =
          mentionedTools(line, knownTools).where((n) => !ran.contains(n));
      if (ghosts.isNotEmpty) return ghosts.join('、');
    }
    // 整场一次工具都没跑过，却在正文里摆出"执行完了、结果如下"的架势：
    // 这时候没有任何真实返回可言，同样是编的。
    if (ran.isEmpty) {
      final showy = RegExp(
        r'(结果|输出|返回|日志|内容)(如下|显示|是)|'
        r'已(经)?(调用|执行|运行)(了)?(工具|命令|脚本)',
      );
      for (final line in sentences) {
        if (pastRef.hasMatch(line)) continue;
        if (_claimVerbs.hasMatch(line) && showy.hasMatch(line)) {
          return '(正文里描述的那次调用)';
        }
      }
    }
    return '';
  }

  /// 是不是"查询类"工具（只读、结果可能很长、容易被拿来一条条翻）。
  static bool _isQueryTool(String name) {
    const heads = [
      'log_',
      'script_read',
      'script_list',
      'cron_list',
      'cron_log',
      'env_list',
      'sub_list',
      'sub_log',
      'shell_read_file',
      'shell_list_files',
      'browser_capture',
      'editor_read',
    ];
    return heads.any(name.startsWith);
  }

  /// 调了这么多次工具还没有任务清单，就提醒模型拆一次。
  ///
  /// 取 4：提示词里的判定线是"3 个以上工具调用就该拆"，留一格余量给
  /// "顺手多查一个只读接口"这种单步任务，第 4 次基本可以确定是多步活了。
  static const _planNudgeToolCalls = 4;

  /// 同一个只读工具连着调这么多次还没收敛，就提醒它收窄条件。
  ///
  /// 典型翻车现场：用户问"A 脚本为什么报错"，模型 log_list 拉出全部任务的
  /// 日志，然后 log_read 一个个读 A、B、C、D——B/C/D 和这个问题毫无关系，
  /// 每份日志几千 token，一轮就能把上下文烧穿。
  static const _repeatNudgeCalls = 6;

  /// 提问工具：同样不进 registry，由循环自己拦下来。
  static const _askUserSpec = LlmFunctionSpec(
    name: 'ask_user',
    description: '关键信息缺失或有多种做法且选错代价大时，向用户提问。'
        '一次只问一个问题，尽量给出候选答案让用户点选。'
        '能自己用只读工具查到的事情不要问。'
        '**提问只有走这个工具才算问出去**：写在正文里的问号不会变成可回答的提问卡，'
        '界面也不会停下来等答案。所以第 2、第 3、第 5 个问题照样调它，'
        '一次一个，问到信息够了为止。\n'
        '特别注意：你在历史里看到的 `❓问题`、`（说明）`、`候选：a / b` 那种排版'
        '是**界面渲染提问卡时自动画的**，不是你该写的格式。'
        '自己在正文里手打一遍等于没问——用户看不到可点的提问卡，'
        '这一轮就白跑了。问题写进 question，候选放 options 数组。',
    parameters: {
      'type': 'object',
      'properties': {
        'question': {
          'type': 'string',
          'description': '一句话问题，中文，具体到可以直接回答',
        },
        'options': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '2-5 个候选答案，用户点一下就能回答；没有明确选项就留空',
        },
        'allow_free_text': {
          'type': 'boolean',
          'description': '是否允许用户自由输入，默认 true',
        },
        'context': {
          'type': 'string',
          'description': '为什么需要问这个，一句话',
        },
      },
      'required': ['question'],
    },
  );

  /// 收尾工具：**可选**。长任务用它给一个正式结论，顺手把成败标出来。
  ///
  /// 早期版本把它设成"唯一的收工方式"，模型不调就追问——结果每一句话都
  /// 被逼出一段总结，用户问"现在几点"也要收到"任务完成 → 已为你查询…"。
  /// 那不是 agent，那是流水线。现在：直接给正文就算答完，这个工具只在
  /// 真有多步任务、需要标注成败时才用。
  static const _taskCompleteSpec = LlmFunctionSpec(
    name: 'task_complete',
    description: '可选。多步任务全部干完时用它给正式结论并标注成败。'
        '一问一答、闲聊、只需要一句话的回复，直接回答就行，不要调用它。'
        '**还需要用户回答才能定的事，先调 ask_user 问，别把问题写进 summary**：'
        '收尾一发出去界面就结束等待，写在 summary 里的问题不会变成提问卡，'
        '用户看不到也答不了。要问就先问完再收尾。',
    parameters: {
      'type': 'object',
      'properties': {
        'status': {
          'type': 'string',
          'enum': ['success', 'failed'],
          'description': 'success=目标达成；failed=确认无法完成',
        },
        'summary': {
          'type': 'string',
          'description': '给用户看的中文结论：做了什么、结果如何、下一步建议。'
              '不要在这里向用户提问（要问就先调 ask_user）',
        },
      },
      'required': ['status', 'summary'],
    },
  );

  /// 任务清单工具：把复杂需求拆成可勾选的步骤。
  static const _taskPlanSpec = LlmFunctionSpec(
    name: 'task_plan',
    description: '把一个复杂需求拆成 2-8 个可执行步骤，界面会显示成任务清单让用户看进度。'
        '只在需求确实需要多步时用；一句话就能办完的事不要拆。'
        '拆完立刻开始做第一步，不要等用户点什么。',
    parameters: {
      'type': 'object',
      'properties': {
        'goal': {'type': 'string', 'description': '一句话总目标'},
        'steps': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '2-8 个步骤，每条一句话，动词开头，可独立验证',
        },
      },
      'required': ['steps'],
    },
  );

  /// 任务清单更新：标记某一步的状态。
  static const _taskStepSpec = LlmFunctionSpec(
    name: 'task_step',
    description: '更新任务清单里某一步的状态。做完一步就立刻更新，让用户看到进度。',
    parameters: {
      'type': 'object',
      'properties': {
        'index': {
          'type': 'integer',
          'description': '第几步（从 1 开始，对应 task_plan 里的顺序）',
        },
        'status': {
          'type': 'string',
          'enum': ['running', 'done', 'failed', 'skipped'],
          'description': 'running=开始做；done=做完并已核实；failed=做不了；skipped=不需要做',
        },
        'note': {'type': 'string', 'description': '一句说明，失败/跳过时必填'},
      },
      'required': ['index', 'status'],
    },
  );

  /// HTML 互动卡片：文字表达不了的东西直接画出来，还能收用户的操作结果。
  static const _canvasSpec = LlmFunctionSpec(
    name: 'ui_canvas',
    description: '生成一个 HTML 页面在弹窗里展示，可以带 CSS 和 JS。'
        '适合：小游戏、图表、动画演示、滑块验证、填表、需要用户点选的交互。'
        '不适合：能用文字说清的结论（那样只是浪费）。'
        'html 必须是完整自包含的一页，不能引用外部网址的脚本、样式、图片或字体'
        '（弹窗里没有网络，外链一律加载不出来，要图形就自己画 canvas/SVG）。'
        '需要拿用户的操作结果时把 expect_result 设为 true，'
        '页面里调用 window.aiSubmit(值) 把结果交回来，本次调用会等到结果再继续。\n'
        '多窗口（只在悬浮窗模式下生效）：给 window 起个名字就能同时摆好几个窗口'
        '（比如 game 放游戏画面、pad 放操作按钮、score 放成绩），'
        '个数不限；用同一个 window 名再调一次就是原地更新那个窗口的内容，'
        '不会又叠一个。position/rect 决定摆在哪，chromeless=true 去掉标题栏让内容贴边。\n'
        '窗口之间可以通信：页面里 window.aiSend("目标窗口名", 数据) 发送，'
        '目标页面定义 window.onAiMessage=function(数据,来源){…} 接收；'
        '目标名写 "*" 是广播。自己的窗口名在 window.aiWindow 里。'
        '另外页面可以调 window.aiClose() 自己关掉这个窗口。',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': '卡片标题，如"恐龙跳跳"'},
        'description': {'type': 'string', 'description': '一句话说明这是什么、怎么玩'},
        'html': {
          'type': 'string',
          'description': '完整 HTML（含内联 <style>/<script>），不要外链资源。'
              '需要回传结果时页面里调用 window.aiSubmit("字符串或JSON")',
        },
        'expect_result': {
          'type': 'boolean',
          'description': 'true=挂起等用户在页面里提交结果（表单/验证/选择）；'
              'false=纯展示，生成完就继续（默认）',
        },
        'result_hint': {
          'type': 'string',
          'description': 'expect_result 为 true 时，一句话告诉用户要做什么',
        },
        'window': {
          'type': 'string',
          'description': '窗口名（如 game / pad / score）。同名=原地更新那个窗口，'
              '不同名=再开一个窗口，个数不限。只在悬浮窗模式下有多窗口效果。',
        },
        'chromeless': {
          'type': 'boolean',
          'description': 'true=不要标题栏，内容贴窗口边缘，右上角只留一个淡淡的关闭点。'
              '游戏画面、全幅仪表盘用它',
        },
        'position': {
          'type': 'string',
          'description': '摆在哪：center/top/bottom/left/right/'
              'topleft/topright/bottomleft/bottomright/full。不给就自动错开',
        },
        'rect': {
          'type': 'array',
          'items': {'type': 'number'},
          'description': '精确位置 [left, top, width, height]，都是 0~1 的屏幕占比，'
              '比 position 优先。要精确排版时用它',
        },
        'close': {
          'type': 'string',
          'description': '关掉某个窗口：填窗口名，填 * 关掉全部。'
              '填了这个就不需要 title/html',
        },
      },
      'required': ['title', 'html'],
    },
  );

  Future<AgentResult> run({
    required List<LlmMessage> history,
    void Function(AgentEvent event)? onEvent,
    void Function(AgentDelta delta)? onDelta,
    void Function(AgentTaskPlan plan)? onPlan,
    void Function(AiCanvas canvas)? onCanvas,

    /// 关掉某个画布窗口（`*` = 全部）。
    void Function(String window)? onCanvasClose,
  }) async {
    final messages = List<LlmMessage>.from(history);
    final records = <ToolCallRecord>[];
    final pending = <AiPlanAction>[];
    final readCache = <String, String>{};
    final readCacheAt = <String, DateTime>{};
    final errorCache = <String, int>{};
    var content = '';
    var usage = const LlmUsage();
    var outcome = AgentOutcome.exhausted;
    var turnsUsed = 0;
    var nudged = false;
    // "该拆任务了"只推一次，推过就不再烦它。
    var planNudged = false;
    // "问题别写正文里"纠正过几次。
    //
    // 原来是个 bool（整轮只纠一次）。连着问三个问题时，第一次纠完就永久置位，
    // 第二、第三问再把问题写成正文就没人管了——现场那条"第二问只有文字、
    // 过程卡零工具"正是这么漏出去的。改成计数，最多纠 3 次。
    var plainQuestionNudges = 0;
    // 这条会话之前已经用 ask_user 问过了——也就是正处在追问链里。
    //
    // 历史里的 assistant 消息不带 tool_calls 结构（那些 tool 结果没持久化，
    // 只发半截会被服务端拒），提问在历史里只剩一行 `❓ xxx` 纯文本。模型照着
    // 这个"范例"学，第三次提问就直接写正文了。所以这里认出追问链，
    // 一旦发现它又把问题写成正文，就把它拽回 ask_user。
    //
    // 不要按 role 过滤：执行簿记现在挂在 **user** 一侧（assistant 正文必须
    // 保持干净，否则模型会把簿记当自己的说话模板抄，见
    // ChatNotifier._historyNote）。按 assistant 找会永远找不到，
    // 追问链识别整条失效。
    final askedBefore = history.any((m) => m.content.contains('ask_user'));

    /// 每个工具名被调了几次（判断"在同一个地方打转"）。
    final callCounts = <String, int>{};

    /// 已经就哪个工具提醒过了，一个工具只提醒一次。
    final repeatNudged = <String>{};
    // 工具调用标记坏掉后的重发次数（见 brokenToolMarkup）。
    var brokenRetries = 0;
    // "正文里假装调用过工具"的打回次数（见 fakeToolClaim）。
    var fakeClaimRetries = 0;
    // "收尾里夹着没问出去的问题"的打回次数（见 blockingQuestion）。
    var finishQuestionRetries = 0;
    // "正文只是抄了系统簿记"的打回次数（见 echoedBookkeeping）。
    var echoRetries = 0;
    // 本次运行认得的全部工具名：用来判断正文里点的名字是不是真工具。
    final knownToolNames = <String>{
      for (final t in registry.definitions) t.name,
      for (final t in externalTools) t.name,
      _askUserSpec.name,
      _taskCompleteSpec.name,
      _taskPlanSpec.name,
      _taskStepSpec.name,
      _canvasSpec.name,
    };
    var lastPromptTokens = 0;
    var lastCacheHitTokens = 0;
    var plan = const AgentTaskPlan();
    final canvases = <AiCanvas>[];

    void emit(AgentEvent event) => onEvent?.call(event);

    // 流式增量转发。turn 由这里补上：LlmClient 不知道自己是第几轮。
    var streamTurn = 0;
    void pipe(LlmDelta d) {
      final cb = onDelta;
      if (cb == null) return;
      cb(
        AgentDelta(
          reasoning: d.reasoning,
          content: d.content,
          toolName: d.toolName,
          reset: d.reset,
          turn: streamTurn,
        ),
      );
    }

    void checkCancelled() {
      if (cancelToken?.isCancelled == true) {
        throw const AgentCancelledException();
      }
    }

    try {
      for (var turn = 0; turn < maxTurns; turn++) {
        checkCancelled();
        turnsUsed = turn + 1;

        final httpToken = CancelToken();
        cancelToken?.httpToken = httpToken;
        streamTurn = turnsUsed;
        // 新一轮开始：把上一轮残留的流式文字清掉。上一轮的思考此刻已经
        // 变成时间线上的一条事件了，留着就是同一段话显示两遍。
        pipe(const LlmDelta(reset: true));
        LlmResponse response;
        try {
          response = await LlmClient.complete(
            config: config,
            messages: messages,
            cancelToken: httpToken,
            onDelta: onDelta == null ? null : pipe,
            tools: [
              for (final t in registry.definitions)
                LlmFunctionSpec(
                  name: t.name,
                  description: t.description,
                  parameters: t.parameters,
                ),
              for (final t in externalTools)
                LlmFunctionSpec(
                  name: t.name,
                  description: t.description,
                  parameters: t.parameters,
                ),
              _askUserSpec,
              _taskCompleteSpec,
              _taskPlanSpec,
              _taskStepSpec,
              _canvasSpec,
            ],
          );
        } on ApiException catch (e) {
          // 取消导致的失败不算错误：翻译成中断，走统一的中断收尾。
          if (e.type == ApiExceptionType.cancelled ||
              (cancelToken?.isCancelled ?? false)) {
            throw const AgentCancelledException();
          }
          rethrow;
        } finally {
          cancelToken?.httpToken = null;
        }
        // 输出整理插件：模型输出可能泄露 `<｜tool｜ calls>` 这类内部调用标记，
        // 在进入展示/历史前先按插件规则清理一遍。
        final cleaner = outputCleaner;
        if (cleaner != null) {
          final cleanContent = cleaner(response.content);
          final cleanReasoning = cleaner(response.reasoningContent);
          if (cleanContent != null || cleanReasoning != null) {
            response = response.copyWith(
              content: cleanContent ?? response.content,
              reasoningContent: cleanReasoning ?? response.reasoningContent,
            );
          }
        }
        // 请求刚回来就先看一眼有没有被取消：省掉后面一整轮工具执行。
        checkCancelled();
        // 这一轮的流式文字到此为止：下面会把思考落成事件、正文落进 content，
        // 界面该改用那两份稳定数据显示了。
        pipe(const LlmDelta(reset: true));
        usage = usage + response.usage;
        if (response.usage.promptTokens > 0) {
          lastPromptTokens = response.usage.promptTokens;
          lastCacheHitTokens = response.usage.cacheHitTokens;
        }
        // 实时用量：每轮请求回来就把最新数字推给界面，不用等整轮 Agent 跑完。
        onUsage?.call(
          usage.totalTokens,
          lastPromptTokens,
          lastCacheHitTokens,
        );

        final reasoning = response.reasoningContent.trim();
        if (reasoning.isNotEmpty) {
          emit(
            AgentEvent(
              kind: AgentEventKind.thinking,
              message: reasoning,
              // 思考也放进 result：详情页、一行预览都靠它，
              // 否则"点开思考是空的"。
              result: reasoning,
              turn: turnsUsed,
            ),
          );
        }
        // 中间那几轮的正文：单独记一条，标成"正文"。
        //
        // 它和思考是两回事——思考是内部盘算，正文是模型写给用户看的话
        // （"我先看一眼日志"、"这个报错是 xxx，我去改一下"）。以前只有
        // 最后一轮的正文能进气泡，中间几轮全被吞了，用户在时间线上只看到
        // 一串工具名。有工具调用才记：没有工具调用时这段正文就是最终答复，
        // 会原样进气泡，再记一条就重复了。
        if (response.content.trim().isNotEmpty &&
            response.toolCalls.isNotEmpty) {
          final said = response.content.trim();
          emit(
            AgentEvent(
              kind: AgentEventKind.answer,
              message: said,
              result: said,
              turn: turnsUsed,
            ),
          );
        }
        if (response.content.trim().isNotEmpty) {
          content = response.content.trim();
        }

        if (response.toolCalls.isEmpty) {
          // 正文里带着坏掉的工具调用标记：模型是想调工具的，只是格式碎了。
          // 这种轮次绝不能当"答完了"——它的正文里往往写着编出来的工具结果。
          // 明确告诉它重发一次，最多两次，免得死循环。
          if (response.brokenToolMarkup && brokenRetries < 2) {
            brokenRetries++;
            // 把这一轮的正文原样放回历史：不放的话模型看不到自己刚发过什么，
            // 很可能换个话题重来。空正文不放，省掉一条没内容的 assistant 消息。
            if (content.isNotEmpty) {
              messages.add(LlmMessage(role: 'assistant', content: content));
            }
            messages.add(
              const LlmMessage(
                role: 'user',
                content: '上一条回复里的工具调用格式坏了，系统没能识别，那次调用根本没执行。'
                    '请重新发起同一个工具调用（标准 function call，不要把调用写在正文里），'
                    '也不要凭空编造工具返回的内容。',
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.error,
                message: '工具调用格式异常，已要求重发（第 $brokenRetries 次）',
                ok: false,
                turn: turnsUsed,
              ),
            );
            continue;
          }
          // 正文只是把系统簿记抄了一遍：这一轮什么都没干。
          //
          // 典型现场就是"第三问不调工具，气泡里写着『这一轮调用过的工具：
          // ask_user』"。那不是回答、更不是提问，用户既看不到提问卡，也没有
          // 得到任何结论。抄的句子剔掉，逼它重来一次。
          if (echoedBookkeeping(content) &&
              echoRetries < 2 &&
              maxTurns - turnsUsed > 1) {
            echoRetries++;
            final kept = stripBookkeeping(content);
            content = kept.length < 8 ? '' : kept;
            messages.add(LlmMessage(role: 'assistant', content: content));
            messages.add(
              LlmMessage(
                role: 'user',
                content: '停一下。你刚才那条回复把系统记录的原话抄了一遍'
                    '（「$_echoHint」这类句子是我这边的执行簿记，不是你的话），'
                    '既没有回答我，也没有真的调用任何工具。'
                    '${askedBefore ? '如果你是想再问我一个问题，就调用 ask_user 把它问出来——'
                        '正文里写一句"调用过 ask_user"不等于问了，我这边不会弹出提问卡。' : ''}'
                    '需要查东西就发起真正的工具调用，能直接回答就直接说结论。',
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.thinking,
                message: '这一轮只抄了系统记录，已要求重做',
                result: '这一轮只抄了系统记录，已要求重做',
                turn: turnsUsed,
              ),
            );
            continue;
          }

          // 追问链里把问题写进了正文：用户那边没有提问卡、也没挂起等答案，
          // 这一轮等于白跑。拽回 ask_user 重发一次。
          //
          // ## 现场实录（第二问就断了）
          //
          // 让它连问三个问题：第一问规规矩矩 ask_user；第二问的气泡里直接是
          //
          //     哈哈丰盛就好，一天都有精神！🍳
          //     ❓第二个问题：…你晚上一般几点睡？
          //     （日常闲聊第二个问题）
          //     候选：10点前，养生党 / 11点左右，正常作息 / …
          //
          // 过程卡里"思考 → 收尾"，零次工具调用；第三问根本没来。
          //
          // 两个原因叠在一起：
          // ① 那套 `❓ / （说明）/ 候选：` 排版是**界面**渲染提问卡时拼的，却被
          //    存进消息又发回给模型当范例（治本在 ChatNotifier 那侧）；
          // ② 这道拦截原先只看 `looksLikePlainQuestion`——它只判**最后一句**，
          //    而这段正文最后一行是"候选：…"，问句夹在中间，判不出来。
          //    而且当时还挂着 `!plainQuestionNudged`（整轮只纠一次）：连着问
          //    三个问题时，第一次纠完标记就永久置位，后面每一问都畅通无阻。
          //
          // 现在：判据换成 unaskedQuestion（认排版 / 认任意位置的阻塞问句 /
          // 再退回最后一句），次数上限改成"最多 3 次"而不是"一次"——
          // 追问链本来就该允许一问一纠。
          final plainQuestion = askedBefore ? unaskedQuestion(content) : '';
          if (plainQuestion.isNotEmpty &&
              plainQuestionNudges < 3 &&
              maxTurns - turnsUsed > 1) {
            plainQuestionNudges++;
            messages.add(LlmMessage(role: 'assistant', content: content));
            // 这段正文作废：它就是那个"没问出去"的问题。
            // 留着的话下一轮模型只发 ask_user、正文为空，content 还是这段旧文字，
            // 气泡里就会出现两遍同一个问题（正文一遍、❓ 一遍）。
            content = '';
            messages.add(
              LlmMessage(
                role: 'user',
                content: '你把问题写在正文里了（「$plainQuestion」），'
                    '我这边不会弹出可回答的提问卡，界面也没有停下来等我回答——'
                    '这个问题等于没问出去。'
                    '注意：❓、（说明）、候选：这套排版是**我的界面**在渲染提问卡时'
                    '自动画出来的，你手写一遍不算提问，必须真的调用 ask_user。'
                    '现在调一次 ask_user 把这一个问题问出来'
                    '（question 写问题本身，别带 ❓；候选放 options 数组）。'
                    '前面已经问过几轮不影响，第几个问题都一样。',
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.thinking,
                message: '问题写在正文里了，已要求改用 ask_user 提问',
                result: '问题写在正文里了，已要求改用 ask_user 提问：$plainQuestion',
                turn: turnsUsed,
              ),
            );
            continue;
          }

          // 它在正文里"演"了一遍工具调用，实际一个都没执行：这轮的所谓结果
          // 全是编的，绝不能收工。拽回去让它真的调一次（整轮只纠两次，
          // 免得对着一句无关的"已查看"死循环）。
          if (fakeClaimRetries < 2 && maxTurns - turnsUsed > 1) {
            final ghost = fakeToolClaim(
              content: content,
              ranTools: records.map((r) => r.toolName),
              knownTools: knownToolNames,
            );
            if (ghost.isNotEmpty) {
              fakeClaimRetries++;
              messages.add(LlmMessage(role: 'assistant', content: content));
              // 这段正文作废：它写的"工具结果"是编的，留着会被当成最终答复
              // 显示给用户，也会污染下一轮的上下文。
              content = '';
              messages.add(
                LlmMessage(
                  role: 'user',
                  content: '停。你说你调用/执行了 $ghost，但系统这边**没有任何执行记录**——'
                      '那次调用根本没发生，你正文里写的返回内容是编的。'
                      '工具只能通过标准 function call 触发，在正文里描述调用不算调用，'
                      '我这边收不到，你也拿不到真实返回。'
                      '现在真的发起那次工具调用（一次一个，参数写全），'
                      '拿到真实返回再说结论；'
                      '确实做不到就直说做不到，不要假装做过。',
                ),
              );
              emit(
                AgentEvent(
                  kind: AgentEventKind.error,
                  message: '正文声称调用过 $ghost 但无执行记录，已要求真的调用',
                  result: '模型在正文里"演"了一次工具调用（$ghost），'
                      '本次运行没有对应的执行记录，已打回重做。',
                  ok: false,
                  turn: turnsUsed,
                ),
              );
              continue;
            }
          }

          // 模型给出正文、不再调工具 = 它认为答完了。默认相信它。
          //
          // 唯一例外：它自己列过任务清单，清单里还有没做的步骤，而且这轮
          // 确实动过手——那大概是半途而废，值得推一把。除此之外一律放行：
          // 一句话的问题就该得到一句话，被追问只会换来一段没人要的总结。
          final unfinished = plan.isNotEmpty &&
              plan.items.any(
                (i) =>
                    i.status == SubtaskStatus.pending ||
                    i.status == SubtaskStatus.running,
              );
          if (nudged ||
              turn >= maxTurns - 1 ||
              records.isEmpty ||
              !unfinished) {
            outcome = AgentOutcome.completed;
            break;
          }
          nudged = true;
          messages.add(LlmMessage(role: 'assistant', content: content));
          messages.add(
            const LlmMessage(
              role: 'user',
              content: '清单里还有没做完的步骤。'
                  '如果确实还没干完就继续动手；'
                  '如果实际已经做完（或做不下去了），把清单更新一下再给结论。',
            ),
          );
          emit(
            AgentEvent(
              kind: AgentEventKind.thinking,
              message: '清单还有剩项，继续推进…',
              turn: turnsUsed,
            ),
          );
          continue;
        }

        nudged = false;
        // 只要这一轮拿到了工具调用，坏格式的连败就算断了。
        brokenRetries = 0;

        // 这一轮所有工具的回复。声明放在 ask_user 之前：ask_user 参数残缺时
        // 也要给模型一条 tool 回复，否则它收不到任何反馈，界面上就是"提问没出现"。
        final toolMessages = <LlmMessage>[];
        var mutated = false;
        // 这一轮要不要挂起提问：真正挂起放到工具全跑完之后。
        AgentQuestion? askedQuestion;
        LlmToolCall? askedCall;

        // ask_user 优先于其他工具：问题一提出来就挂起，没答案继续跑也是白跑。
        final askCalls = response.toolCalls
            .where((c) => c.name == _askUserSpec.name)
            .toList();
        // 一轮里问了好几个问题：界面一次只能弹一个，但**不能把多的悄悄吃掉**。
        // 每一个都回一条，模型才知道"这几个我还得再问"，不会以为已经问过了。
        for (final extra in askCalls.skip(1)) {
          final text = _askQuestionOf(extra.arguments);
          toolMessages.add(
            _toolReply(
              extra,
              '界面一次只弹一个问题，这一条还没问出去'
              '${text.isEmpty ? '' : '（$text）'}。'
              '等用户答完上一个问题，你再调一次 ask_user 把它问出来——'
              '连着问几轮完全可以，别自己猜答案。',
            ),
          );
        }
        if (askCalls.isNotEmpty) {
          final askCall = askCalls.first;
          final question = _askQuestionOf(askCall.arguments);
          // 问题解析不出来时**不能静默跳过**。
          //
          // 之前这里只看 arguments['question']，取不到就什么都不做：这一轮
          // 没有任何工具回复、模型也没拿到反馈，界面上就是"第三次提问没弹出来"。
          // 模型换个字段名（text/prompt/内容）或把问题写进 context 都会踩到。
          // 现在解析放宽，真的空了就明确回一句让它重发。
          if (question.isEmpty) {
            toolMessages.add(
              _toolReply(
                askCall,
                'ask_user 的 question 是空的，用户什么都没看到。'
                '请重新调用 ask_user，把问题写在 question 字段里（一句话，别留空）。',
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.error,
                message: 'ask_user 没带问题内容，已要求重发',
                toolName: askCall.name,
                args: askCall.arguments,
                ok: false,
                turn: turnsUsed,
              ),
            );
          } else {
            // 这里**不能**直接 return。
            //
            // 模型经常一轮里既问一句又顺手要几个工具（"顺便把日志拉出来"）。
            // 早期实现一见到 ask_user 就立刻 return，同轮其它调用连一条 tool
            // 回复都没有：下一轮模型看不到那几步的结果，只能重新猜——
            // 用户看到的现象就是"工具调用被省去了"。
            // 现在先把问题攒着，等这一轮的活真跑完再挂起。
            askedQuestion = AgentQuestion(
              question: question,
              options: _askOptionsOf(askCall.arguments),
              allowFreeText: askCall.arguments['allow_free_text'] != false,
              context: askCall.arguments['context']?.toString().trim() ?? '',
            );
            askedCall = askCall;
          }
        }

        // task_complete 优先处理：命中即结束整个循环。
        // 但这一轮已经决定要提问时先放着——问题还没问出去就宣布完工，
        // 用户等于被跳过了。
        final finishCalls = askedQuestion != null
            ? const <LlmToolCall>[]
            : response.toolCalls.where((c) => c.name == _taskCompleteSpec.name);
        if (finishCalls.isNotEmpty) {
          final finishCall = finishCalls.first;
          final status =
              finishCall.arguments['status']?.toString() ?? 'success';
          final summary = finishCall.arguments['summary']?.toString() ?? '';

          // ===== 收尾里夹着一个还没问出去的问题：不许收工 =====
          //
          // 用户原话：**"假设我说四个提问，前三个好好的，第四个因为收尾导致
          // 并无调用提问工具，也就是这个问题变成收尾提出不是提问工具提出"**。
          //
          // 前三问都规规矩矩走 ask_user（弹提问卡 + 挂起等答案）。到第四问时
          // 模型觉得活干完了，就调 task_complete 把最后那问塞进 summary。
          // task_complete 一命中立刻 return：界面不弹卡、不挂起，问题退化成
          // 一段普通文字，用户以为 AI 自己拍了主意，实际它在等回话——整条
          // 追问链在最后一步断掉。
          //
          // 所以这里在 return **之前**筛一遍收尾文案：夹着"必须用户回答才能
          // 往下走"的问题就把收尾驳回，逼它改用 ask_user 问。客套收尾
          // （"还需要我做别的吗？"）不算，见 blockingQuestion。
          final finishText =
              summary.trim().isNotEmpty ? summary.trim() : content;
          // 用 unaskedQuestion 而不是 blockingQuestion：收尾文案里同样会出现
          // 照抄的 `❓ / 候选：` 排版，只认"阻塞问句"会漏掉它。
          final pendingAsk = unaskedQuestion(finishText);
          if (pendingAsk.isNotEmpty &&
              finishQuestionRetries < 2 &&
              maxTurns - turnsUsed > 1) {
            finishQuestionRetries++;
            // 只把那句问题摘掉，别的活干了什么照样留着：
            // 这段汇总本身是有用的，全清了用户就看不到已完成的部分。
            final kept = finishText.replaceFirst(pendingAsk, '').trim();
            content = kept.length < 8 ? '' : kept;
            // 这一轮的 assistant 消息只带正文、不带 tool_calls：同轮别的工具
            // 还没执行，把它们的 tool_calls 写进历史却没有配对的 tool 回复，
            // 服务端会直接报"孤立的 tool_calls"。
            if (finishText.isNotEmpty) {
              messages.add(LlmMessage(role: 'assistant', content: finishText));
            }
            messages.add(
              LlmMessage(
                role: 'user',
                content: '等一下，别收尾。你在收尾文案里问了我一句'
                    '「$pendingAsk」——这句写在 task_complete 的 summary 里，'
                    '我这边不会弹出可回答的提问卡，界面也不会停下来等我回答，'
                    '这个问题等于没问出去。'
                    '现在调用 ask_user 把它正式问一次（一次只问一个，'
                    '有候选就带上 options）；'
                    '前面已经用 ask_user 问过几轮不影响，第几个问题都一样。'
                    '等我答完你再决定要不要收尾。'
                    '如果这句其实不需要我回答（你自己能定），'
                    '那就别问，直接按你的判断做完再 task_complete。',
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.thinking,
                message: '收尾里夹着没问出去的问题，已要求改用 ask_user：$pendingAsk',
                result: '收尾里夹着没问出去的问题，已要求改用 ask_user：$pendingAsk',
                turn: turnsUsed,
              ),
            );
            continue;
          }

          if (summary.trim().isNotEmpty) content = summary.trim();
          outcome =
              status == 'failed' ? AgentOutcome.failed : AgentOutcome.completed;
          emit(
            AgentEvent(
              kind: AgentEventKind.done,
              message: outcome == AgentOutcome.failed ? '任务失败' : '任务完成',
              result: content,
              ok: outcome != AgentOutcome.failed,
              turn: turnsUsed,
            ),
          );
          return AgentResult(
            content: content,
            toolRecords: records,
            pendingActions: pending,
            outcome: outcome,
            usage: usage,
            turns: turnsUsed,
            lastPromptTokens: lastPromptTokens,
            lastCacheHitTokens: lastCacheHitTokens,
            taskPlan: plan,
            canvases: canvases,
          );
        }

        // 清单 / 画布这三个工具由循环自己吃掉：它们不碰面板，也不该走
        // 确认策略与只读缓存，纯粹是"跟界面说句话"。
        for (final call in response.toolCalls) {
          if (call.name == _taskPlanSpec.name) {
            final steps = <String>[
              for (final s in (call.arguments['steps'] as List? ?? const []))
                s.toString().trim(),
            ].where((s) => s.isNotEmpty).toList();
            if (steps.isEmpty) {
              toolMessages.add(_toolReply(call, 'steps 是空的，清单没建立。'));
              continue;
            }
            plan = AgentTaskPlan(
              goal: call.arguments['goal']?.toString().trim() ?? '',
              items: [
                for (var i = 0; i < steps.length; i++)
                  AgentSubtask(id: 'step${i + 1}', title: steps[i]),
              ],
            );
            toolMessages.add(
              _toolReply(
                call,
                '清单已建立（${steps.length} 步），已显示给用户。'
                '现在开始做第 1 步，每做完一步调用 task_step 更新状态。',
              ),
            );
            onPlan?.call(plan);
            emit(
              AgentEvent(
                kind: AgentEventKind.taskPlan,
                message: plan.promptLines(),
                toolName: call.name,
                args: call.arguments,
                turn: turnsUsed,
              ),
            );
            continue;
          }
          if (call.name == _taskStepSpec.name) {
            if (plan.isEmpty) {
              toolMessages.add(
                _toolReply(call, '还没有任务清单，先调用 task_plan 建立。'),
              );
              continue;
            }
            final rawIndex = call.arguments['index'];
            final index = rawIndex is num
                ? rawIndex.toInt()
                : int.tryParse(rawIndex?.toString() ?? '') ?? 0;
            if (index < 1 || index > plan.items.length) {
              toolMessages.add(
                _toolReply(call, 'index 越界：清单只有 ${plan.items.length} 步。'),
              );
              continue;
            }
            final statusName = call.arguments['status']?.toString() ?? 'done';
            final status = SubtaskStatus.values.firstWhere(
              (s) => s.name == statusName,
              orElse: () => SubtaskStatus.done,
            );
            final items = List<AgentSubtask>.from(plan.items);
            items[index - 1] = items[index - 1].copyWith(
              status: status,
              note: call.arguments['note']?.toString().trim() ?? '',
            );
            plan = plan.copyWith(items: items);
            final next = plan.current;
            toolMessages.add(
              _toolReply(
                call,
                '第 $index 步已标记为 ${status.label}。'
                '${next == null ? '清单全部处理完了，可以核实结果并 task_complete。' : '下一步：${next.title}'}',
              ),
            );
            onPlan?.call(plan);
            emit(
              AgentEvent(
                kind: AgentEventKind.taskPlan,
                message: plan.promptLines(),
                toolName: call.name,
                args: call.arguments,
                turn: turnsUsed,
              ),
            );
            continue;
          }
          if (call.name == _canvasSpec.name) {
            // 关窗分支：close 参数一给就只做关闭，不需要 html。
            final closeTarget =
                call.arguments['close']?.toString().trim() ?? '';
            if (closeTarget.isNotEmpty) {
              onCanvasClose?.call(closeTarget);
              toolMessages.add(
                _toolReply(
                  call,
                  closeTarget == '*'
                      ? '已关闭全部画布窗口。'
                      : '已关闭窗口「$closeTarget」（不存在的话就什么都没发生）。',
                ),
              );
              emit(
                AgentEvent(
                  kind: AgentEventKind.canvas,
                  message: '关闭画布窗口：$closeTarget',
                  toolName: call.name,
                  args: call.arguments,
                  turn: turnsUsed,
                ),
              );
              continue;
            }
            final html = call.arguments['html']?.toString() ?? '';
            if (html.trim().isEmpty) {
              toolMessages.add(_toolReply(call, 'html 是空的，卡片没生成。'));
              continue;
            }
            final expectResult = call.arguments['expect_result'] == true;
            final rawRect = call.arguments['rect'];
            final canvas = AiCanvas(
              id: 'canvas${DateTime.now().microsecondsSinceEpoch}',
              title: call.arguments['title']?.toString().trim() ?? '互动卡片',
              description:
                  call.arguments['description']?.toString().trim() ?? '',
              html: html,
              expectResult: expectResult,
              resultHint:
                  call.arguments['result_hint']?.toString().trim() ?? '',
              createdAt: DateTime.now(),
              window: call.arguments['window']?.toString().trim() ?? '',
              chromeless: call.arguments['chromeless'] == true,
              position: call.arguments['position']?.toString().trim() ?? '',
              rect: rawRect is List && rawRect.length >= 4
                  ? [
                      for (final v in rawRect.take(4))
                        (v is num) ? v.toDouble() : 0.0,
                    ]
                  : null,
            );
            canvases.add(canvas);
            onCanvas?.call(canvas);
            if (expectResult) {
              // 挂起等用户在页面里提交。等待期间照样能被"停止"打断。
              final payload = await CanvasResultBus.wait(
                canvas.id,
                isCancelled: () => cancelToken?.isCancelled == true,
              );
              checkCancelled();
              toolMessages.add(
                _toolReply(
                  call,
                  payload == null
                      ? '用户没有提交结果（关掉了或超时）。'
                          '别干等，换个思路或者问用户想怎么办。'
                      : '用户在卡片「${canvas.title}」里提交了：\n$payload',
                ),
              );
              records.add(
                ToolCallRecord(
                  toolName: call.name,
                  args: {'id': canvas.id, 'title': canvas.title},
                  status: payload == null ? 'error' : 'ok',
                  result: payload ?? '用户未提交',
                  durationMs: 0,
                  createdAt: DateTime.now(),
                ),
              );
              emit(
                AgentEvent(
                  kind: AgentEventKind.canvas,
                  message:
                      '${canvas.title}：${payload == null ? '用户未提交' : '已收到用户提交'}',
                  toolName: call.name,
                  // 参数带上完整 arguments（含 html 源码）：用户点进详情要看
                  // "这张卡片的代码长什么样"，只给 id 等于什么都没给。
                  args: {'id': canvas.id, ...call.arguments},
                  result: payload ?? '',
                  ok: payload != null,
                  turn: turnsUsed,
                ),
              );
              continue;
            }
            final open = CanvasBus.windows;
            toolMessages.add(
              _toolReply(
                call,
                '卡片「${canvas.title}」已经弹给用户了（${html.length} 字符）。'
                '不要把 HTML 再贴进回复正文，用户已经能看到实物。'
                '${canvas.window.isEmpty ? '' : '窗口名：${canvas.window}。'}'
                '${open.isEmpty ? '' : '当前开着的窗口：${open.join('、')}。'}',
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.canvas,
                message: canvas.title,
                toolName: call.name,
                args: {'id': canvas.id, ...call.arguments},
                result: canvas.description.isEmpty
                    ? '卡片已弹给用户（${html.length} 字符 HTML），参数栏里可以看源码。'
                    : canvas.description,
                turn: turnsUsed,
              ),
            );
            continue;
          }
        }

        for (final call in response.toolCalls) {
          checkCancelled();
          // 这些都在上面处理过了，不进普通工具流程。
          if (call.name == _askUserSpec.name ||
              call.name == _taskPlanSpec.name ||
              call.name == _taskStepSpec.name ||
              call.name == _canvasSpec.name) {
            continue;
          }
          final def = registry.find(call.name);
          final ext = def == null ? _findExternal(call.name) : null;
          final isWrite = def?.isWrite ?? ext?.isWrite ?? false;
          final isDanger = def?.danger ?? ext?.danger ?? false;
          final key = cacheKeyOf(call.name, call.arguments);
          final startedAt = DateTime.now();

          if (def == null && ext == null) {
            const msg = '未知工具，请从工具列表里选择';
            toolMessages.add(_toolReply(call, msg));
            records.add(
              ToolCallRecord(
                toolName: call.name,
                args: call.arguments,
                status: 'error',
                result: msg,
                durationMs: 0,
                createdAt: startedAt,
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.toolEnd,
                message: '未知工具：${call.name}',
                toolName: call.name,
                args: call.arguments,
                result: msg,
                ok: false,
                turn: turnsUsed,
              ),
            );
            continue;
          }

          // 只读结果复用：写操作会清空缓存，所以不会读到过期数据。
          //
          // 但"我们没写过"不等于"外面没变"：面板自己在跑 cron，日志、任务状态、
          // 磁盘占用每秒都在变。这类工具一律不复用，否则用户问"现在跑完了吗"
          // 永远拿到几分钟前那份，看着就像工具坏了。
          final cachedAt = readCacheAt[key];
          final stale = cachedAt != null &&
              DateTime.now().difference(cachedAt) > _readCacheTtl;
          final cached = (isWrite || _isVolatileTool(call.name) || stale)
              ? null
              : readCache[key];
          if (cached != null) {
            toolMessages.add(_toolReply(call, '（与之前完全相同的查询，直接复用结果）\n$cached'));
            records.add(
              ToolCallRecord(
                toolName: call.name,
                args: call.arguments,
                status: 'cached',
                result: cached,
                durationMs: 0,
                createdAt: startedAt,
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.toolEnd,
                message: '复用已有结果：${call.name}',
                toolName: call.name,
                args: call.arguments,
                result: cached,
                ok: true,
                turn: turnsUsed,
              ),
            );
            continue;
          }

          final failures = errorCache[key] ?? 0;
          if (failures >= 3) {
            const msg = '同样的调用（参数一字不差）已经失败三次，别再原样重试了。'
                '换个参数、换条路，或者先把失败的原因修掉'
                '（修完就能再试这条，写操作会解锁它）。';
            toolMessages.add(_toolReply(call, msg));
            records.add(
              ToolCallRecord(
                toolName: call.name,
                args: call.arguments,
                status: 'blocked',
                result: msg,
                durationMs: 0,
                createdAt: startedAt,
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.toolEnd,
                message: '重复失败已拦截：${call.name}',
                toolName: call.name,
                args: call.arguments,
                result: msg,
                ok: false,
                turn: turnsUsed,
              ),
            );
            continue;
          }

          emit(
            AgentEvent(
              kind: AgentEventKind.toolStart,
              message: isWrite ? '需要确认：${call.name}' : '调用工具：${call.name}',
              toolName: call.name,
              args: call.arguments,
              turn: turnsUsed,
            ),
          );

          final needsConfirm = _needsConfirm(isWrite, isDanger) &&
              !confirmedActionKeys.contains(key);
          if (needsConfirm) {
            pending.add(
              AiPlanAction(
                type: call.name,
                target: _describeTarget(call.arguments),
                impact: (def?.impact.isNotEmpty ?? false)
                    ? def!.impact
                    : ext != null
                        ? '扩展工具（${ext.origin.isEmpty ? '外部' : ext.origin}）：${call.name}'
                        : '写操作：${call.name}',
                reversible: def?.reversible ?? !isDanger,
                data: call.arguments,
              ),
            );
            toolMessages.add(
              _toolReply(
                call,
                '已挂起等待用户确认。请在回复里说明这次要做什么、影响是什么，然后停下等确认。',
              ),
            );
            records.add(
              ToolCallRecord(
                toolName: call.name,
                args: call.arguments,
                status: 'pending_confirm',
                result: '等待用户确认',
                durationMs: 0,
                createdAt: startedAt,
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.planPending,
                message: '写操作等待确认：${call.name}',
                toolName: call.name,
                args: call.arguments,
                turn: turnsUsed,
              ),
            );
            continue;
          }

          final deadline = _timeoutFor(call.name);
          try {
            // 看门狗：工具自己不返回时，这里到点就抛 TimeoutException。
            // 注意它只是**放弃等待**，底层那个请求可能还在跑（Dart 没法强杀
            // 一个 Future）——所以超时后一律按"结果未知"处理，让模型去核实，
            // 而不是当成"没做"。
            final raw = await (ext != null
                    ? ext.invoke(call.arguments)
                    : registry.execute(
                        toolName: call.name,
                        args: call.arguments,
                        confirm: isWrite,
                      ))
                .timeout(deadline);
            final result = _truncate(raw);
            final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
            if (isWrite) {
              mutated = true;
            } else if (!_isVolatileTool(call.name)) {
              readCache[key] = result;
              readCacheAt[key] = DateTime.now();
            }
            errorCache.remove(key);
            toolMessages.add(_toolReply(call, result));
            records.add(
              ToolCallRecord(
                toolName: call.name,
                args: call.arguments,
                status: 'ok',
                // UI/历史记录保留完整原始输出；只有喂给模型的上下文用截断版。
                result: raw,
                durationMs: elapsed,
                createdAt: startedAt,
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.toolEnd,
                message: '工具完成：${call.name}',
                toolName: call.name,
                args: call.arguments,
                result: result,
                // 原始返回单独留一份给界面：模型看截断版省 token，
                // 人排障要看的往往正是被截掉的那一段。
                fullResult: raw,
                durationMs: elapsed,
                ok: true,
                turn: turnsUsed,
                isWrite: isWrite,
              ),
            );
          } on TimeoutException {
            errorCache[key] = failures + 1;
            final secs = deadline.inSeconds;
            final msg = '执行超时：等了 $secs 秒还没返回，已经放弃等待。'
                '${isWrite ? '注意这是写操作，它可能已经生效了一半——先查一下当前状态再决定要不要重做。' : ''}'
                '别原样重试同一条（大概率还是卡住）：缩小范围（少读几行、加过滤条件）、'
                '换个工具，或者直接告诉用户这一步卡在哪。';
            toolMessages.add(_toolReply(call, msg));
            records.add(
              ToolCallRecord(
                toolName: call.name,
                args: call.arguments,
                status: 'timeout',
                result: msg,
                durationMs: DateTime.now().difference(startedAt).inMilliseconds,
                createdAt: startedAt,
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.toolEnd,
                message: '工具超时（$secs 秒）：${call.name}',
                toolName: call.name,
                args: call.arguments,
                result: msg,
                durationMs: DateTime.now().difference(startedAt).inMilliseconds,
                ok: false,
                turn: turnsUsed,
                isWrite: isWrite,
              ),
            );
          } catch (e) {
            errorCache[key] = failures + 1;
            final message = _errorText(e);
            toolMessages.add(
              _toolReply(call, '执行失败：$message\n请分析原因并换一种方式，不要原样重试。'),
            );
            records.add(
              ToolCallRecord(
                toolName: call.name,
                args: call.arguments,
                status: 'error',
                result: message,
                durationMs: DateTime.now().difference(startedAt).inMilliseconds,
                createdAt: startedAt,
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.toolEnd,
                message: '工具失败：${call.name}',
                toolName: call.name,
                args: call.arguments,
                result: message,
                // 失败时把异常原文也留着：ApiException 的 message 常常被
                // 精简过，原始 toString 里才有状态码和响应体。
                fullResult: '$e',
                durationMs: DateTime.now().difference(startedAt).inMilliseconds,
                ok: false,
                turn: turnsUsed,
                isWrite: isWrite,
              ),
            );
          }
        }

        // 任何写操作之后，之前的只读快照都可能过期，全部作废。
        if (mutated) {
          readCache.clear();
          readCacheAt.clear();
          // 失败记录也一起清。写操作很可能正是"把失败的原因修掉了"
          // （建了缺的文件、装了缺的依赖），这时候还拦着不让重试，
          // 模型就只能放弃一条本来能走通的路。
          errorCache.clear();
        }

        // 这一轮的活干完了，现在才挂起提问。
        if (askedQuestion != null && askedCall != null) {
          if (pending.isEmpty) {
            records.add(
              ToolCallRecord(
                toolName: askedCall.name,
                args: askedCall.arguments,
                status: 'awaiting_input',
                result: askedQuestion.question,
                durationMs: 0,
                createdAt: DateTime.now(),
              ),
            );
            emit(
              AgentEvent(
                kind: AgentEventKind.question,
                message: askedQuestion.question,
                toolName: askedCall.name,
                args: askedCall.arguments,
                result: [
                  askedQuestion.question,
                  if (askedQuestion.context.isNotEmpty)
                    '说明：${askedQuestion.context}',
                  if (askedQuestion.options.isNotEmpty)
                    '候选：${askedQuestion.options.join(' / ')}',
                ].join('\n'),
                turn: turnsUsed,
              ),
            );
            return AgentResult(
              content: content,
              toolRecords: records,
              pendingActions: pending,
              outcome: AgentOutcome.awaitingInput,
              usage: usage,
              turns: turnsUsed,
              question: askedQuestion,
              lastPromptTokens: lastPromptTokens,
              lastCacheHitTokens: lastCacheHitTokens,
              taskPlan: plan,
              canvases: canvases,
            );
          }
          // 提问和"等用户确认写操作"撞一起：确认优先（它挡着一个真实写操作）。
          // 问题不能就这么消失，给模型一条明确回复，让它确认完再问一次。
          toolMessages.add(
            _toolReply(
              askedCall,
              '这一轮有写操作正在等用户点确认，你的问题还没弹给用户。'
              '等确认结果回来后如果还需要问，再调一次 ask_user。',
            ),
          );
        }

        messages.add(
          LlmMessage(
            role: 'assistant',
            content: response.content,
            // ask_user 不再过滤：参数残缺那条会有一条 tool 回复配对，
            // 抹掉 tool_call 反而会让服务端看到"孤立的 tool 消息"直接报错。
            toolCalls: response.toolCalls
                .where((c) => c.name != _taskCompleteSpec.name)
                .toList(),
          ),
        );
        messages.addAll(toolMessages);
        // 老的工具结果压成摘要：省下的是"每轮都重发"的钱，不是一次性的钱。
        _ageToolResults(messages, toolMessages);

        if (pending.isNotEmpty) {
          outcome = AgentOutcome.awaitingConfirm;
          break;
        }

        // 同一个只读工具反复调：大概率在"列全部再一个个读"，提醒收窄。
        //
        // 只对只读的查询类工具做，写操作反复调是另一类问题（不该在这拦）。
        for (final record in records) {
          callCounts[record.toolName] = (callCounts[record.toolName] ?? 0) + 1;
        }
        final hot = callCounts.entries
            .where((e) =>
                e.value >= _repeatNudgeCalls &&
                !repeatNudged.contains(e.key) &&
                _isQueryTool(e.key))
            .toList();
        if (hot.isNotEmpty && maxTurns - turnsUsed > 3) {
          final worst = hot.reduce((a, b) => a.value >= b.value ? a : b);
          repeatNudged.add(worst.key);
          messages.add(
            LlmMessage(
              role: 'user',
              content: '提醒一下：你已经调了 ${worst.value} 次 ${worst.key}。'
                  '这不是不让你调——**每次都在推进（对象不同、信息在积累）就继续**。'
                  '但如果这几次都没让你更接近答案，那就是筛选条件不对：'
                  '把用户点名的那个对象（脚本名/任务名/文件名/域名）当成过滤条件'
                  '重新查一次，或者直接说"按现有信息定位不到，需要你提供什么"。'
                  '和这个问题无关的日志、脚本、接口不要读。',
            ),
          );
          emit(
            AgentEvent(
              kind: AgentEventKind.thinking,
              message: '${worst.key} 已调用 ${worst.value} 次，提醒自查是否在推进',
              result: '${worst.key} 已调用 ${worst.value} 次，提醒自查是否在推进',
              turn: turnsUsed,
            ),
          );
        }
        callCounts.clear();

        // 一直在埋头调工具却没有清单：提醒它这是个多步任务，该拆了。
        //
        // 提示词里写了"3 个以上工具调用就先 task_plan"，但模型经常一头扎进
        // 细节里忘了拆——用户的原话是"工具和技能不是摆设"。这里只推一次，
        // 而且是在它已经证明"这活确实不止一步"之后推，不会去烦一问一答。
        if (!planNudged &&
            plan.isEmpty &&
            records.length >= _planNudgeToolCalls &&
            turnsUsed >= 2 &&
            maxTurns - turnsUsed > 6) {
          planNudged = true;
          messages.add(
            LlmMessage(
              role: 'user',
              content: '你已经调了 ${records.length} 次工具，说明这不是一步能完的事，'
                  '但到现在还没有任务清单——用户看不到你打算做几步、做到哪了。'
                  '现在用 task_plan 把剩下的活拆成 2-8 个可验证的步骤（已经做完的直接标 done），'
                  '然后继续做，每做完一步用 task_step 更新。'
                  '如果剩下的活确实只有一步，就直接做完给结论，不用拆。',
            ),
          );
          emit(
            AgentEvent(
              kind: AgentEventKind.thinking,
              message: '已调用 ${records.length} 次工具仍无任务清单，提醒模型拆分任务',
              result: '已调用 ${records.length} 次工具仍无任务清单，提醒模型拆分任务',
              turn: turnsUsed,
            ),
          );
        }

        // 轮次快用完时提醒模型收尾，避免直接被截断。
        if (maxTurns - turnsUsed == 3) {
          messages.add(
            const LlmMessage(
              role: 'user',
              content: '还剩 3 轮工具调用额度，请优先把手上的事收干净并给出结论。',
            ),
          );
        }
      }
    } on AgentCancelledException {
      emit(
        AgentEvent(
          kind: AgentEventKind.error,
          message: '已中断本次任务',
          turn: turnsUsed,
        ),
      );
      return AgentResult(
        content: content.isEmpty ? '任务已中断。' : content,
        toolRecords: records,
        pendingActions: pending,
        outcome: AgentOutcome.cancelled,
        usage: usage,
        turns: turnsUsed,
        lastPromptTokens: lastPromptTokens,
        lastCacheHitTokens: lastCacheHitTokens,
        taskPlan: plan,
        canvases: canvases,
      );
    }

    emit(
      AgentEvent(
        kind: outcome == AgentOutcome.awaitingConfirm
            ? AgentEventKind.planPending
            : AgentEventKind.done,
        message: switch (outcome) {
          AgentOutcome.awaitingInput => '等待用户回答',
          AgentOutcome.awaitingConfirm => '等待用户确认写操作',
          AgentOutcome.exhausted => '达到 $maxTurns 轮上限，任务未确认完成',
          // 没动过工具就是一次普通对话，别把它说成"任务完成"。
          _ => records.isEmpty ? '已回答' : '已完成',
        },
        result: content,
        ok: outcome != AgentOutcome.exhausted,
        turn: turnsUsed,
      ),
    );

    if (outcome == AgentOutcome.exhausted && content.isEmpty) {
      content = '任务未能在 $maxTurns 轮内完成，请补充信息或缩小范围后重试。';
    }

    return AgentResult(
      content: content,
      toolRecords: records,
      pendingActions: pending,
      outcome: outcome,
      usage: usage,
      turns: turnsUsed,
      lastPromptTokens: lastPromptTokens,
      lastCacheHitTokens: lastCacheHitTokens,
      taskPlan: plan,
      canvases: canvases,
    );
  }

  /// 把较早轮次的工具结果就地压成摘要。
  ///
  /// 只动 role == 'tool' 的消息，保留 tool_call_id 与前后结构，
  /// 因此协议依然合法；模型看到的是"已压缩"提示，需要细节可以再查一次。
  void _ageToolResults(List<LlmMessage> messages, List<LlmMessage> fresh) {
    final freshIds = <String>{
      for (final m in fresh)
        if (m.toolCallId != null) m.toolCallId!,
    };
    // 倒着数，保留最近 _toolResultFreshTurns 批工具消息的全文。
    var keptBatches = 0;
    String? lastBatchMarker;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role != 'tool') continue;
      if (freshIds.contains(m.toolCallId)) continue;
      // 用 assistant 消息作为"批次"分隔：每遇到一个新批次计数 +1。
      final marker = m.toolCallId ?? '';
      if (lastBatchMarker == null || marker != lastBatchMarker) {
        lastBatchMarker = marker;
      }
      if (keptBatches < _toolResultFreshTurns) {
        keptBatches++;
        continue;
      }
      if (m.content.length <= _agedToolResultChars) continue;
      messages[i] = LlmMessage(
        role: 'tool',
        content: '${m.content.substring(0, _agedToolResultChars)}\n'
            '…（这段较早的工具结果已压缩以节省上下文。'
            '若还需要完整内容，用更精确的参数重新查询一次。）',
        toolCallId: m.toolCallId,
        name: m.name,
      );
    }
  }

  ExternalTool? _findExternal(String name) {
    for (final t in externalTools) {
      if (t.name == name) return t;
    }
    return null;
  }

  bool _needsConfirm(bool isWrite, bool isDanger) {
    if (!isWrite) return false;
    return switch (approvalMode) {
      AiApprovalMode.strict => true,
      AiApprovalMode.cautious => isDanger,
      AiApprovalMode.full => false,
    };
  }

  /// 从 ask_user 的参数里把问题挖出来。
  ///
  /// 模型换字段名是常事（question / text / prompt / message / q / 问题），
  /// 只认一个键就会出现"这次提问凭空消失"。这里按优先级依次尝试，
  /// 都取不到时才算真的空。
  static String _askQuestionOf(Map<String, dynamic> args) {
    const keys = [
      'question',
      'text',
      'prompt',
      'message',
      'content',
      'q',
      'ask',
      '问题',
    ];
    for (final k in keys) {
      final v = args[k]?.toString().trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  /// 候选答案。列表、逗号分隔的字符串、{label:…} 对象都接。
  static List<String> _askOptionsOf(Map<String, dynamic> args) {
    final raw = args['options'] ?? args['choices'] ?? args['候选'];
    final out = <String>[];
    if (raw is List) {
      for (final o in raw) {
        if (o is Map) {
          final label = (o['label'] ?? o['title'] ?? o['value'] ?? o['text'])
                  ?.toString()
                  .trim() ??
              '';
          if (label.isNotEmpty) out.add(label);
        } else {
          final label = o.toString().trim();
          if (label.isNotEmpty) out.add(label);
        }
      }
    } else if (raw is String) {
      // 模型偶尔会写成 "A / B / C" 或 "A,B,C"。
      for (final part in raw.split(RegExp(r'[/,、|]'))) {
        final label = part.trim();
        if (label.isNotEmpty) out.add(label);
      }
    }
    return out;
  }

  LlmMessage _toolReply(LlmToolCall call, String content) => LlmMessage(
        role: 'tool',
        content: content,
        toolCallId: call.id.isEmpty ? call.name : call.id,
        name: call.name,
      );

  /// 参数顺序不影响缓存与确认判定。
  static String cacheKeyOf(String name, Map<String, dynamic> args) {
    final keys = args.keys.toList()..sort();
    final normalized = {for (final k in keys) k: args[k]};
    return '$name:${jsonEncode(normalized)}';
  }

  String _truncate(String text) {
    if (text.length <= _maxToolResultChars) return text;
    final headLen = (_maxToolResultChars * 0.7).round();
    final tailLen = (_maxToolResultChars * 0.2).round();
    final head = text.substring(0, headLen);
    final tail = text.substring(text.length - tailLen);
    final omitted = text.length - headLen - tailLen;
    return '$head\n…（已省略 $omitted 字符）…\n$tail';
  }

  String _describeTarget(Map<String, dynamic> args) {
    if (args.isEmpty) return '-';
    return args.entries.map((e) {
      final value = e.value?.toString() ?? '';
      final short = value.length > 200 ? '${value.substring(0, 200)}…' : value;
      return '${e.key}=$short';
    }).join('，');
  }

  String _errorText(Object error) {
    final text = error.toString();
    return text.length > 400 ? '${text.substring(0, 400)}…' : text;
  }
}
