import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/models/agent_event.dart';
import 'package:qinglong_flutter/features/ai/widgets/agent_process_card.dart';

List<AgentEvent> _mixedEvents(int count) => [
  for (var i = 0; i < count; i++)
    AgentEvent(
      kind: i % 3 == 0
          ? AgentEventKind.toolEnd
          : i % 3 == 1
              ? AgentEventKind.thinking
              : AgentEventKind.workflowStep,
      message: 'step $i',
      toolName: i % 3 == 2 ? 'condition_exec' : 'shell_exec',
      result: 'result $i',
      turn: i ~/ 10,
      isWrite: i % 30 == 0,
    ),
];

void main() {
  testWidgets('超长过程卡内联只画末尾一批，完整过程页懒加载', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentProcessCard(events: _mixedEvents(1200)),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('已折叠'), findsWidgets);

    await tester.tap(find.text('查看完整过程').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('完整执行过程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('连续 condition_exec 步骤内联只保留最后 N 步', (tester) async {
    final events = [
      for (var i = 0; i < 1000; i++)
        AgentEvent(
          kind: AgentEventKind.workflowStep,
          message: '条件执行 · step $i',
          toolName: 'condition_exec',
          result: 'ok $i',
          args: {'_depth': i % 3},
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentProcessCard(events: events),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('执行过程'));
    await tester.pumpAndSettle();
    expect(find.textContaining('前面还有'), findsOneWidget);
    expect(find.text('查看完整过程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
