import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/llm/llm_client.dart';
import 'package:qinglong_flutter/features/ai/models/agent_event.dart';
import 'package:qinglong_flutter/features/ai/models/agent_task_plan.dart';
import 'package:qinglong_flutter/features/ai/models/chat_runtime.dart';

void main() {
  test('LlmMessage 能从 toJson 结构还原（含图片和 tool_calls）', () {
    const original = LlmMessage(
      role: 'assistant',
      content: '先看日志',
      toolCalls: [
        LlmToolCall(
          id: 'call_1',
          name: 'shell_exec',
          arguments: {'command': 'ls -la'},
        ),
      ],
    );
    final restored = LlmMessage.fromJson(original.toJson());
    expect(restored.role, 'assistant');
    expect(restored.content, '先看日志');
    expect(restored.toolCalls.single.name, 'shell_exec');
    expect(restored.toolCalls.single.arguments['command'], 'ls -la');
  });

  test('InterruptedRun 能持久化失败请求快照并原样还原', () {
    final plan = AgentTaskPlan(
      goal: '部署到 Vercel',
      items: const [
        AgentSubtask(id: '1', title: '改 publish', status: SubtaskStatus.done),
        AgentSubtask(id: '2', title: '部署', status: SubtaskStatus.running),
      ],
    );
    final run = InterruptedRun(
      sessionId: 's1',
      userInput: '继续',
      events: const [
        AgentEvent(
          kind: AgentEventKind.taskPlan,
          message: '当前任务清单：\n[>] 2. 部署',
        ),
      ],
      startedAt: DateTime.parse('2026-10-21T09:50:07.160716'),
      roundId: '20261021_094625_330h',
      resumeMessages: const [
        LlmMessage(role: 'system', content: 'system prompt'),
        LlmMessage(role: 'user', content: '继续'),
        LlmMessage(role: 'assistant', content: '正在改'),
        LlmMessage(role: 'tool', content: 'ok', toolCallId: 'call_1'),
      ],
      resumeTurnIndex: 7,
      resumePlan: plan,
      resumeContent: '正在改',
    );

    final decoded = InterruptedRun.decode(InterruptedRun.encode(run));
    expect(decoded, isNotNull);
    expect(decoded!.resumeMessages.length, 4);
    expect(decoded.resumeMessages[0].role, 'system');
    expect(decoded.resumeMessages[3].toolCallId, 'call_1');
    expect(decoded.resumeTurnIndex, 7);
    expect(decoded.resumePlan.goal, '部署到 Vercel');
    expect(decoded.resumePlan.items[1].status, SubtaskStatus.running);
    expect(decoded.resumeContent, '正在改');
    expect(decoded.roundId, '20261021_094625_330h');
  });

  test('没有 resumeMessages 的旧快照仍然能解析（向后兼容）', () {
    final old = InterruptedRun(
      sessionId: 's2',
      userInput: '继续',
      events: const [],
      startedAt: DateTime.now(),
    );
    final decoded = InterruptedRun.decode(InterruptedRun.encode(old));
    expect(decoded, isNotNull);
    expect(decoded!.resumeMessages, isEmpty);
    expect(decoded.resumeTurnIndex, 0);
  });
}
