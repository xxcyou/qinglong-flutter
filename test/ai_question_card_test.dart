import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/agent/agent_loop.dart';
import 'package:qinglong_flutter/features/ai/widgets/ai_question_card.dart';

/// 提问卡：答完必须留下痕迹，换问题必须解锁。
///
/// 这两条都是"问了一次之后就卡住了"这个报告的直接成因：
/// 答完后按钮全灰、界面毫无变化，用户分不清是发出去了还是点空了。
void main() {
  Widget host(AgentQuestion q, ValueChanged<String> onAnswer) => MaterialApp(
        home: Scaffold(
          body: AiQuestionCard(question: q, onAnswer: onAnswer),
        ),
      );

  testWidgets('点候选后显示"答案已送回"，并且只回调一次', (tester) async {
    final answers = <String>[];
    final q = AgentQuestion(
      question: '这个任务叫什么名字？',
      options: const ['甲测试', '乙测试'],
    );
    await tester.pumpWidget(host(q, answers.add));

    expect(find.textContaining('答案已送回'), findsNothing);

    await tester.tap(find.text('甲测试'));
    await tester.pump();

    expect(answers, ['甲测试']);
    expect(find.textContaining('答案已送回'), findsOneWidget);

    // 防连点：卡片锁住之后再点第二个候选不能再发一轮。
    await tester.tap(find.text('乙测试'));
    await tester.pump();
    expect(answers, ['甲测试']);
  });

  testWidgets('换成下一个问题时解锁：提示消失、候选可点', (tester) async {
    final answers = <String>[];
    final first = AgentQuestion(question: '第一个问题？', options: const ['答一']);
    await tester.pumpWidget(host(first, answers.add));
    await tester.tap(find.text('答一'));
    await tester.pump();
    expect(find.textContaining('答案已送回'), findsOneWidget);

    final second = AgentQuestion(question: '第二个问题？', options: const ['答二']);
    await tester.pumpWidget(host(second, answers.add));
    await tester.pump();

    expect(find.textContaining('答案已送回'), findsNothing);
    await tester.tap(find.text('答二'));
    await tester.pump();
    expect(answers, ['答一', '答二']);
  });

  testWidgets('没有候选时直接给输入框，回车即答', (tester) async {
    final answers = <String>[];
    final q = AgentQuestion(question: '要跑的命令是什么？');
    await tester.pumpWidget(host(q, answers.add));

    await tester.enterText(find.byType(TextField), 'task a.js');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(answers, ['task a.js']);
    expect(find.textContaining('答案已送回'), findsOneWidget);
  });
}
