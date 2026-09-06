import '../../../core/llm/llm_client.dart';
import '../models/agent_event.dart';
import 'agent_loop.dart';
import 'external_tool.dart';

/// 任务代理组：把一件大事拆给若干个"工人代理"去做，可以串行也可以并行。
///
/// ## 为什么需要它
///
/// 单个 agent 循环有两个硬限制：轮次预算（40 轮）和上下文长度。一个真正复杂的
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

    /// 用户设的并行度：`parallel_agents` 的默认值，同时也是它的上限。
    int parallel = defaultParallel,

    /// 子代理用的是哪家哪个模型，只在工具描述里点一句——
    /// 让模型知道派出去的工人可能比自己弱，好决定任务拆多细。
    String workerModel = '',
  }) {
    final limitCeiling = parallel.clamp(1, maxParallel);
    Map<String, dynamic> obj(
      List<String> required,
      Map<String, dynamic> props,
    ) =>
        {'type': 'object', 'properties': props, 'required': required};

    Future<String> runWorker(String title, String task, int index) async {
      final label = title.trim().isEmpty ? '子任务${index + 1}' : title.trim();
      onEvent?.call(
        AgentEvent(
          kind: AgentEventKind.thinking,
          message: '派工：$label\n$task',
          result: task,
        ),
      );
      try {
        final result = await spawn().run(
          history: seed(task),
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
            ),
          ),
        );
        return _describe(label, result);
      } catch (e) {
        return '### $label\n执行出错：$e';
      }
    }

    return [
      ExternalTool(
        name: 'task_worker',
        description: '把一个**独立的子任务**交给一个子代理去做完，拿回它的结论。'
            '适合：需要好几步工具调用、但结论只有几句话的活'
            '（体检一个脚本、查清一个接口、把一个目录整理干净）。'
            '好处是过程不占你的上下文——子代理自己查自己试，只把结论交给你。'
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
        invoke: (args) => runWorker(
          args['title']?.toString() ?? '',
          args['task']?.toString() ?? '',
          0,
        ),
      ),
      ExternalTool(
        name: 'parallel_agents',
        description: '把几个**互不相干**的子任务同时派给多个子代理，一起等结果。'
            '适合：十个脚本各查一遍、三个网站各抓一份、多份日志各自分析——'
            '这类彼此没有先后依赖的活。总耗时接近最慢的那一个，而不是加起来。\n'
            '硬约束（不遵守就会拿到互相冲突的结果）：\n'
            '1) 子任务之间不能有依赖（B 需要 A 的结果就别放一批，改成先后两次调用）；\n'
            '2) 不同子任务不要改同一个文件；\n'
            '3) 终端和浏览器是全机唯一的，多个子代理用会自动排队——'
            '所以一批里塞五个"都要长时间占着终端"的任务并不会更快。\n'
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
          // 用户设的那个数既是默认值也是天花板：他把并行调到 2 就是不想让
          // 手机同时跑三个，模型不该有权把它加回去。
          final limit =
              ((args['max_parallel'] as num?)?.toInt() ?? limitCeiling)
                  .clamp(1, limitCeiling);

          final outputs = List<String>.filled(items.length, '');
          var cursor = 0;
          // 手写一个并发闸门：Future.wait 全放出去会把 N 个子代理一起塞进
          // 同一条网络，反而更慢，而且抢锁的等待时间也会一起变长。
          Future<void> worker() async {
            while (true) {
              final index = cursor;
              if (index >= items.length) return;
              cursor = index + 1;
              final item = items[index];
              outputs[index] = await runWorker(item.title, item.task, index);
            }
          }

          await Future.wait([
            for (var i = 0; i < limit && i < items.length; i++) worker(),
          ]);
          return [
            '${items.length} 个子任务全部结束（并行度 $limit）。',
            ...outputs,
          ].join('\n\n');
        },
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
