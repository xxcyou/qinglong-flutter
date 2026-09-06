import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/agent/agent_loop.dart';

void main() {
  const known = ['shell_exec', 'cron_list', 'script_read', 'log_read'];

  group('fakeToolClaim：抓"没调用却说调用完了"', () {
    test('点名了没跑过的工具 → 判定为编造', () {
      final ghost = AgentLoop.fakeToolClaim(
        content: '我已经执行了 shell_exec，输出如下：\nNo such file',
        ranTools: const [],
        knownTools: known,
      );
      expect(ghost, 'shell_exec');
    });

    test('真的跑过那个工具 → 放行', () {
      final ghost = AgentLoop.fakeToolClaim(
        content: '我已经执行了 shell_exec，输出如下：\nNo such file',
        ranTools: const ['shell_exec'],
        knownTools: known,
      );
      expect(ghost, isEmpty);
    });

    test('跑了 A 却声称跑了 B → 只报 B', () {
      final ghost = AgentLoop.fakeToolClaim(
        content: '我调用了 cron_list 和 log_read，结果显示任务正常。',
        ranTools: const ['cron_list'],
        knownTools: known,
      );
      expect(ghost, 'log_read');
    });

    test('一次工具都没跑，却摆出"结果如下" → 判定为编造', () {
      final ghost = AgentLoop.fakeToolClaim(
        content: '已经执行了命令，返回如下：\n总共 3 个任务。',
        ranTools: const [],
        knownTools: known,
      );
      expect(ghost, isNotEmpty);
    });

    test('引用以前那轮的结果 → 放行（历史里确实做过）', () {
      final ghost = AgentLoop.fakeToolClaim(
        content: '之前已经查过 cron_list 了，结果显示有 3 个任务，不用再查。',
        ranTools: const [],
        knownTools: known,
      );
      expect(ghost, isEmpty);
    });

    test('普通对话不误伤', () {
      expect(
        AgentLoop.fakeToolClaim(
          content: '青龙的 cron_list 接口可以列出任务，你要我查一下吗？',
          ranTools: const [],
          knownTools: known,
        ),
        isEmpty,
      );
      expect(
        AgentLoop.fakeToolClaim(
          content: '好的，我这就去看看。',
          ranTools: const [],
          knownTools: known,
        ),
        isEmpty,
      );
    });

    test('跑过工具后正常总结不误伤', () {
      expect(
        AgentLoop.fakeToolClaim(
          content: '查询结果是：3 个任务，其中 1 个在跑。',
          ranTools: const ['cron_list'],
          knownTools: known,
        ),
        isEmpty,
      );
    });

    test('空正文 → 放行', () {
      expect(
        AgentLoop.fakeToolClaim(
          content: '   ',
          ranTools: const [],
          knownTools: known,
        ),
        isEmpty,
      );
    });
  });

  group('mentionedTools', () {
    test('只认真实工具名，短名不参与', () {
      expect(
        AgentLoop.mentionedTools('调 shell_exec 和 abc', ['shell_exec', 'abc']),
        ['shell_exec'],
      );
    });
  });
}
