import 'dart:async';

import '../../../core/llm/llm_client.dart';
import '../models/agent_event.dart';
import 'agent_loop.dart';
import 'external_tool.dart';

/// 任务代理组：把一件大事拆给若干个"工人代理"去做，可以串行也可以并行。
///
/// ## 为什么需要它
///
/// 单个 agent 循环有两个硬限制：轮次预算（默认 200 轮，可调大）和上下文长度。一个真正复杂的
/// 任务（"把这十个脚本都体检一遍并给出修复建议"）在一个循环里跑，会出现
/// 后半程把前半程的细节忘干净、或者轮次用完只做了一半。拆成子代理之后：
/// 每个子代理只带**自己那一小块**的上下文，做完只回一段结论给主代理——
/// 主代理的上下文里只留结论，不留过程。
///
/// ## 并行会不会打架
///
/// 会，所以这里不靠"祈祷"，靠三条硬约束：
///
/// 1. **单例资源全部排队**（[ShellLock]）：终端 exec、浏览器内核各有一把锁，
///    两个子代理同时用只会一前一后，不会交叉。这是"多个 agent 同时操作终端
///    会不会卡住"的答案——不会卡死，会排队，等太久会明确报错而不是无限挂着。
/// 2. **子代理不能再开子代理**：工具清单里剔掉了自己，避免无限分裂。
/// 3. **并行度有上限**：默认 3，最多 4。手机上再多就是自己抢 CPU 和网络带宽。
///
/// 剩下一类冲突软件层面挡不住：两个子代理被派去改同一个文件。所以拆任务时
/// 必须按"互不重叠的目标"来拆，工具描述里对模型明确说了这一条。
class AgentTeamTools {
  AgentTeamTools._();

  /// 子代理的默认轮次预算。比主代理小很多：它只该做一件小事，
  /// 二十轮还没做完说明任务拆得不对，那时候如实汇报比硬撑更有用。
  /// 用户可以在设置里调（SubAgentPlan.maxTurns）。
  static const subMaxTurns = 16;

  /// 并行度的硬上限。以前写死 4，现在放到 8——挡的是"手机 CPU + 一条网络"，
  /// 但有人把 Base URL 指到桌面上的转发服务，那边扛得住更多。
  /// 真正生效的上限是用户在设置里定的那个数，这里只兜住手滑输入。
  static const maxParallel = 8;
  static const defaultParallel = 3;

  static List<ExternalTool> build({
    /// 造一个干净的子代理。传进来的是"不含本组工具"的工具集。
    required AgentLoop Function() spawn,

    /// 子代理的起始消息：系统提示 + 任务描述。
    required List<LlmMessage> Function(String task) seed,

    /// 把子代理的过程事件透给主界面，用户能看到"工人在干什么"。
    void Function(AgentEvent event)? onEvent,

    /// 把子代理的流式增量（思考/正文/工具名）也透给主界面，
    /// 让流程卡里子代理不展开也能实时看到正在想什么/正在调什么工具。
    void Function(AgentDelta delta)? onDelta,

    /// 用户设的并行度：`parallel_agents` 的默认值，同时也是它的上限。
    int parallel = defaultParallel,

    /// 子代理用的是哪家哪个模型，只在工具描述里点一句——
    /// 让模型知道派出去的工人可能比自己弱，好决定任务拆多细。
    String workerModel = '',

    /// 后台子代理完成结果的自动汇入槽；不传则子代理照常后台跑，
    /// 只是不自动并入主代理上下文（仍可 subagent_wait 取）。
    AgentSubagentSink? subagentSink,
  }) {
    final limitCeiling = parallel.clamp(1, maxParallel);
    Map<String, dynamic> obj(
      List<String> required,
      Map<String, dynamic> props,
    ) =>
        {'type': 'object', 'properties': props, 'required': required};

    final coordinator = _SubagentCoordinator(
      spawn: spawn,
      seed: seed,
      onEvent: onEvent,
      onDelta: onDelta,
      sink: subagentSink,
      maxParallel: limitCeiling,
    );

    return [
      ExternalTool(
        name: 'task_worker',
        description: '把一个**独立的子任务**后台交给一个子代理去做，**不阻塞主代理**。'
            '适合：需要好几步工具调用、但结论只有几句话的活'
            '（体检一个脚本、查清一个接口、把一个目录整理干净）。'
            '返回任务 id，主代理可以继续做别的事；'
            '子代理完成时结果会自动并入上下文，'
            '只有下一步真的必须拿到结果时才调 subagent_wait(id) 等它。'
            '注意：子代理看不到你和用户的对话，所以 task 里要把背景、路径、'
            '判定标准一次写清楚，别让它猜。它也不能反过来问用户。'
            '${workerModel.isEmpty ? '' : '子代理用的模型是 $workerModel。'}',
        parameters: obj([
          'task'
        ], {
          'title': {
            'type': 'string',
            'description': '子任务名（给用户看，如"体检 jd_cash.js"）'
          },
          'task': {
            'type': 'string',
            'description': '完整的任务说明：目标、涉及的文件/接口、做到什么程度算完成。'
                '要自包含，子代理只能看到这段文字',
          },
        }),
        isWrite: true,
        origin: '任务代理',
        invoke: (args) async {
          final task = args['task']?.toString().trim() ?? '';
          if (task.isEmpty) return 'task 是空的，没有可派发的子任务。';
          final title = args['title']?.toString().trim() ?? '';
          final id = coordinator.start(title.isEmpty ? '' : title, task);
          return '已后台启动子代理${id.isEmpty ? '' : '「$id"'}\n主代理可以继续做自己的事；'
              '需要它结果时调用 subagent_wait(id)，不调也会在完成后自动并入上下文。';
        },
      ),
      ExternalTool(
        name: 'parallel_agents',
        description: '把多个**互不相干**的子任务后台同时派给多个子代理，**不阻塞主代理**。'
            '适合：十个脚本各查一遍、三个网站各抓一份、多份日志各自分析——'
            '这类彼此没有先后依赖的活。\n'
            '硬约束（不遵守就会拿到互相冲突的结果）：\n'
            '1) 子任务之间不能有依赖（B 需要 A 的结果就别放一批，改成先后两次调用）；\n'
            '2) 不同子任务不要改同一个文件；\n'
            '3) 终端和浏览器是全机唯一的，多个子代理用会自动排队——'
            '所以一批里塞五个"都要长时间占着终端"的任务并不会更快。\n'
            '本工具返回后主代理继续跑，不等待；'
            '需要汇总时调 subagent_wait()（不带 id = 等全部），'
            '或者等它们一个个完成自动并入上下文。\n'
            '并行度上限 $limitCeiling 个（用户在设置里定的），默认就用这个数。',
        parameters: obj([
          'tasks'
        ], {
          'tasks': {
            'type': 'array',
            'description': '子任务清单，每项 {title, task}',
            'items': {
              'type': 'object',
              'properties': {
                'title': {'type': 'string'},
                'task': {'type': 'string'},
              },
              'required': ['task'],
            },
          },
          'max_parallel': {
            'type': 'integer',
            'description': '同时最多跑几个，1-$limitCeiling，默认 $limitCeiling',
          },
        }),
        isWrite: true,
        origin: '任务代理',
        invoke: (args) async {
          final raw = args['tasks'];
          if (raw is! List || raw.isEmpty) {
            return 'tasks 是空的，没有任何子任务可派。';
          }
          final items = <({String title, String task})>[];
          for (final item in raw) {
            if (item is Map) {
              final task = item['task']?.toString().trim() ?? '';
              if (task.isEmpty) continue;
              items.add((title: item['title']?.toString() ?? '', task: task));
            } else {
              final task = item.toString().trim();
              if (task.isNotEmpty) items.add((title: '', task: task));
            }
          }
          if (items.isEmpty) return 'tasks 里没有有效的 task 字段。';
          final ids = coordinator.startMany(items);
          return '已后台启动 ${items.length} 个子代理（并行上限 $limitCeiling）：'
              '${ids.join('、')}\n主代理可以继续做自己的事；'
              '需要汇总时调 subagent_wait()，不调也会在完成时自动并入上下文。';
        },
      ),
      ExternalTool(
        name: 'subagent_status',
        description: '查看当前已启动的子代理状态（运行中/已完成），不等待。',
        parameters: obj([], {}),
        isWrite: false,
        origin: '任务代理',
        invoke: (_) async => coordinator.status(),
      ),
      ExternalTool(
        name: 'subagent_wait',
        description: '等待一个或全部子代理完成并返回汇总。'
            '**只有下一步真的必须用到子代理结果时才调用**；'
            '不调用的话，子代理完成时结果也会自动并入上下文。',
        parameters: obj([], {
          'id': {
            'type': 'string',
            'description': '可选。传单个子代理 id 只等它；不传则等全部已启动子代理。'
          },
        }),
        isWrite: false,
        origin: '任务代理',
        invoke: (args) => coordinator.wait(
          args['id']?.toString().trim().isNotEmpty == true
              ? args['id']!.toString().trim()
              : null,
        ),
      ),
    ];
  }

  /// 把子代理的运行结果压成一段主代理能直接用的汇报。
  ///
  /// 只留结论 + 关键异常：过程细节留在子代理那边，搬到主代理这里就等于
  /// 白拆一次任务。
  static String _describe(String label, AgentResult result) {
    final parts = <String>['### $label'];
    final content = result.content.trim();
    parts.add(content.isEmpty ? '（子代理没有给出结论）' : content);

    final failed = result.toolRecords
        .where((r) => r.status == 'failed')
        .map((r) => r.toolName)
        .toSet();
    if (failed.isNotEmpty) parts.add('失败的工具：${failed.join('、')}');

    // 子代理没有界面，问不了用户：把问题原样上交，由主代理决定要不要问。
    final question = result.question;
    if (question != null) {
      parts.add('子代理卡在一个需要用户拍板的问题上：${question.question}'
          '${question.options.isEmpty ? '' : '（候选：${question.options.join(' / ')}）'}'
          ' —— 它没有提问权限，需要你自己用 ask_user 问，或者换个不需要拍板的做法。');
    }
    // 严格/仅危险策略下，子代理的写操作只会变成待确认动作，不会真的执行。
    if (result.pendingActions.isNotEmpty) {
      parts.add('有 ${result.pendingActions.length} 个写操作因为需要确认没有执行：'
          '${result.pendingActions.map((a) => a.target).join('、')}。'
          '要做的话由你来发起，用户确认后才会执行。');
    }
    if (result.outcome == AgentOutcome.exhausted) {
      parts.add('（子代理把 $subMaxTurns 轮预算用完了，任务可能只做了一部分——'
          '这通常说明这个子任务还该再拆细一点。）');
    }
    return parts.join('\n');
  }
}

/// 一个后台子代理任务。
class _Subtask {
  _Subtask({
    required this.id,
    required this.label,
    required this.task,
  });

  final String id;
  final String label;
  final String task;
  final Completer<void> completer = Completer<void>();
  String summary = '';
  bool done = false;
}

/// 子代理后台调度器：只负责“派出去、跑完收结果”。
///
/// - `start` 立刻返回任务 id，主代理不等待；
/// - 内部按 `maxParallel` 限制同时真正在跑的子代理数；
/// - 每个子代理完成后把摘要放进 `AgentSubagentSink`，由主 AgentLoop 自动并入上下文。
class _SubagentCoordinator {
  _SubagentCoordinator({
    required this.spawn,
    required this.seed,
    required this.onEvent,
    required this.onDelta,
    required this.sink,
    required this.maxParallel,
  }) {
    sink?.onWaitAll = waitAll;
  }

  final AgentLoop Function() spawn;
  final List<LlmMessage> Function(String task) seed;
  final void Function(AgentEvent event)? onEvent;
  final void Function(AgentDelta delta)? onDelta;
  final AgentSubagentSink? sink;
  final int maxParallel;

  final Map<String, _Subtask> _tasks = {};
  final List<_Subtask> _pending = [];
  int _active = 0;
  int _seq = 0;

  String start(String title, String task) {
    final label =
        title.trim().isEmpty ? '子任务${_tasks.length + 1}' : title.trim();
    final id =
        'sub_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${_seq++}';
    final t = _Subtask(id: id, label: label, task: task);
    _tasks[id] = t;
    sink?.addPending();
    _pending.add(t);
    _pump();
    return id;
  }

  List<String> startMany(List<({String title, String task})> items) {
    final ids = <String>[];
    for (final item in items) {
      ids.add(start(item.title, item.task));
    }
    return ids;
  }

  void _pump() {
    while (_active < maxParallel && _pending.isNotEmpty) {
      final t = _pending.removeAt(0);
      _active++;
      unawaited(_run(t));
    }
  }

  Future<void> _run(_Subtask t) async {
    final label = t.label;
    onEvent?.call(
      AgentEvent(
        kind: AgentEventKind.thinking,
        message: '派工：$label\n${t.task}',
        result: t.task,
        group: label,
      ),
    );
    try {
      final result = await spawn().run(
        history: seed(t.task),
        onEvent: (e) => onEvent?.call(
          AgentEvent(
            kind: e.kind,
            message: '[$label] ${e.message}',
            toolName: e.toolName,
            args: e.args,
            result: e.result,
            fullResult: e.fullResult,
            durationMs: e.durationMs,
            ok: e.ok,
            turn: e.turn,
            group: label,
          ),
        ),
        onDelta: onDelta == null
            ? null
            : (d) => onDelta!(
                  AgentDelta(
                    reasoning: d.reasoning,
                    content: d.content,
                    toolName: d.toolName,
                    reset: d.reset,
                    turn: d.turn,
                    group: label,
                  ),
                ),
      );
      t.summary = AgentTeamTools._describe(label, result);
    } catch (e) {
      t.summary = '### $label\n执行出错：$e';
    } finally {
      t.done = true;
      if (!t.completer.isCompleted) t.completer.complete();
      sink?.completePending();
      if (t.summary.isNotEmpty) {
        sink?.add(
          AgentSubagentResult(
            id: t.id,
            label: label,
            summary: t.summary,
          ),
        );
      }
      _active--;
      _pump();
    }
  }

  /// 等所有已启动但还没结束的子代理跑完。
  Future<void> waitAll() async {
    final all = _tasks.values.toList();
    for (final t in all.where((t) => !t.done)) {
      await t.completer.future;
    }
  }

  Future<String> wait([String? id]) async {
    if (id != null) {
      final t = _tasks[id];
      if (t == null) return '没有找到子代理 id：$id（用 subagent_status 查看）。';
      await t.completer.future;
      // 已经主动取走结果，就不再让 AgentLoop 下次再自动并入一遍。
      sink?.removeById(id);
      return t.summary;
    }
    final all = _tasks.values.toList();
    for (final t in all.where((t) => !t.done)) {
      await t.completer.future;
    }
    if (all.isEmpty) return '当前没有已启动的子代理。';
    for (final t in all) {
      sink?.removeById(t.id);
    }
    return all.map((t) => t.summary).join('\n\n');
  }

  String status() {
    if (_tasks.isEmpty) return '当前没有已启动的子代理。';
    return _tasks.values
        .map(
          (t) =>
              t.done ? '✅ ${t.label}（${t.id}）已完成' : '⏳ ${t.label}（${t.id}）运行中',
        )
        .join('\n');
  }
}
