import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/widgets/agent_stream_card.dart';

/// 流式卡里那块"思考窗口"的三条行为，都是用户点名要的：
/// 1. 底边把手能把窗口拉长拉短；
/// 2. 往上翻就停止自动跟随，位置钉住，方便回看前面的思考；
/// 3. 回到最新一行附近（或点"回到最新"）自动恢复跟随。
void main() {
  const scrollKey = ValueKey('stream-scroll-think');
  const handleKey = ValueKey('stream-handle-think');

  setUp(AgentStreamCard.resetStreamHeights);

  /// 够长的思考文本：必须超出窗口高度，不然没有可滚的余量。
  String think(int lines) =>
      [for (var i = 0; i < lines; i++) '第 $i 行思考内容，模型正在推理'].join('\n');

  /// 不能用 pumpAndSettle：卡头有个 CircularProgressIndicator 一直在转，
  /// 永远settle不了。手动推几帧就够——跟随跳转是帧后回调，一帧即生效。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> pump(WidgetTester tester, String reasoning) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentStreamCard(
              reasoning: reasoning,
              content: '',
              tool: '',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  ScrollController controllerOf(WidgetTester tester) =>
      tester.widget<SingleChildScrollView>(find.byKey(scrollKey)).controller!;

  testWidgets('底边把手往下拖 → 思考窗口变高', (tester) async {
    await pump(tester, think(60));
    final before = tester.getSize(find.byKey(scrollKey)).height;
    expect(before, 132, reason: '非紧凑模式默认 132');

    await tester.drag(find.byKey(handleKey), const Offset(0, 90));
    await tester.pump();
    expect(tester.getSize(find.byKey(scrollKey)).height, before + 90);

    // 往上拖回去也要生效，且不会缩到看不见。
    await tester.drag(find.byKey(handleKey), const Offset(0, -400));
    await tester.pump();
    expect(tester.getSize(find.byKey(scrollKey)).height, 56);
  });

  testWidgets('拖不出上限：最高 520', (tester) async {
    await pump(tester, think(60));
    await tester.drag(find.byKey(handleKey), const Offset(0, 2000));
    await tester.pump();
    expect(tester.getSize(find.byKey(scrollKey)).height, 520);
  });

  testWidgets('新字来了自动贴住最新一行', (tester) async {
    await pump(tester, think(40));
    await settle(tester);
    final c = controllerOf(tester);
    expect(c.offset, c.position.maxScrollExtent);

    await pump(tester, think(80));
    await settle(tester);
    expect(controllerOf(tester).offset,
        controllerOf(tester).position.maxScrollExtent);
  });

  testWidgets('往上翻 → 停止跟随，新字不再抢位置，并给出回程入口', (tester) async {
    await pump(tester, think(40));
    await settle(tester);

    // 手指把内容往下拽 = 往上翻页。
    await tester.drag(find.byKey(scrollKey), const Offset(0, 200));
    await settle(tester);
    final parked = controllerOf(tester).offset;
    expect(parked, lessThan(controllerOf(tester).position.maxScrollExtent));
    expect(find.text('回到最新'), findsOneWidget);

    // 关键：这时候又来了一堆新字，读的位置必须一动不动。
    await pump(tester, think(90));
    await settle(tester);
    expect(controllerOf(tester).offset, parked);

    // 点回程 → 恢复跟随，回到底部，提示消失。
    await tester.tap(find.text('回到最新'));
    await settle(tester);
    expect(controllerOf(tester).offset,
        controllerOf(tester).position.maxScrollExtent);
    expect(find.text('回到最新'), findsNothing);
  });

  testWidgets('自己划回底部也会恢复跟随', (tester) async {
    await pump(tester, think(40));
    await settle(tester);
    await tester.drag(find.byKey(scrollKey), const Offset(0, 200));
    await settle(tester);
    expect(find.text('回到最新'), findsOneWidget);

    await tester.drag(find.byKey(scrollKey), const Offset(0, -400));
    await settle(tester);
    expect(find.text('回到最新'), findsNothing);

    // 恢复跟随后，新字应该重新把视口带到底。
    await pump(tester, think(90));
    await settle(tester);
    expect(controllerOf(tester).offset,
        controllerOf(tester).position.maxScrollExtent);
  });
}
