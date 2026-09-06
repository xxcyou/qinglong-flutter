import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/theme/glass.dart';
import 'package:qinglong_flutter/core/utils/formatter.dart';

/// token 计数的显示规则 + 流动背景的"空闲不画帧"规则。
///
/// 后者是性能红线：常驻 ticker 的版本在真机上空闲吃掉了整个核
/// （满屏 BackdropFilter 每帧都要重新栅格化），所以必须保证
/// 没有交互时 ticker 是停着的。
void main() {
  group('Formatter.tokens 智能单位', () {
    test('千以内原样', () {
      expect(Formatter.tokens(0), '0');
      expect(Formatter.tokens(999), '999');
    });

    test('1k–10k 留一位小数', () {
      expect(Formatter.tokens(1000), '1.0k');
      expect(Formatter.tokens(5900), '5.9k');
      expect(Formatter.tokens(9949), '9.9k');
    });

    test('10k 以上取整 k', () {
      expect(Formatter.tokens(10000), '10k');
      expect(Formatter.tokens(57400), '57k');
      expect(Formatter.tokens(999499), '999k');
    });

    test('百万换 M', () {
      expect(Formatter.tokens(1000000), '1.00M');
      expect(Formatter.tokens(2450000), '2.45M');
      expect(Formatter.tokens(12300000), '12.3M');
    });

    test('负数当 0，不吐出奇怪的字符串', () {
      expect(Formatter.tokens(-5), '0');
    });

    test('次数：上千也换单位', () {
      expect(Formatter.count(101), '101');
      expect(Formatter.count(1273), '1.3k');
      expect(Formatter.count(24000), '24k');
    });
  });

  group('GlassFlow 空闲不画帧', () {

    testWidgets('nudge 之后相位会推进，停手后 ticker 自己停掉', (tester) async {
      final flow = GlassFlow.instance;
      final before = flow.phase.value;

      flow.nudge();
      // 推过节流窗口（50ms）若干帧。
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump(const Duration(milliseconds: 120));
      expect(flow.phase.value, isNot(before), reason: '交互后背景应该开始流动');

      // 超过 coast 时间之后 ticker 必须自己停：再等也不能有新帧。
      await tester.pump(const Duration(milliseconds: 1800));
      await tester.pump(const Duration(milliseconds: 200));
      final parked = flow.phase.value;
      await tester.pump(const Duration(seconds: 3));
      expect(flow.phase.value, parked, reason: '空闲时必须一帧都不画');
      flow.stopForTest();
    });

    testWidgets('GlassFlowDriver 不吞下点击', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: GlassFlowDriver(
            child: Center(
              child: GestureDetector(
                // opaque：空的 SizedBox 自己不参与命中测试，
                // deferToChild 会让这次点击落空（和被吞掉长得一样）。
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox(
                  key: ValueKey('target'),
                  width: 80,
                  height: 40,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('target')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(taps, 1);
      // 点击顺手把 ticker 点起来了，必须在树被销毁前停掉，
      // 否则 flutter_test 判定"动画泄漏"。
      GlassFlow.instance.stopForTest();
    });
  });

  group('GlassPill 标签夹宽', () {
    testWidgets('长模型名不撑破布局，也不出黄黑警告条', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              child: Row(
                children: [
                  GlassPill(
                    icon: Icons.smart_toy_outlined,
                    label: 'deepseek-v4-flash-preview-20260101-long',
                    maxLabelWidth: 104,
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 溢出会以 FlutterError 形式抛出（debug 下就是那条黄黑斜纹）。
      expect(tester.takeException(), isNull);
      final text = tester.renderObject<RenderBox>(
        find.text('deepseek-v4-flash-preview-20260101-long'),
      );
      expect(text.size.width, lessThanOrEqualTo(104.0));
    });

    testWidgets('不给 maxLabelWidth 时保持原样（短标签不受影响）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [GlassPill(icon: Icons.bolt_outlined, label: '强度 高')],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('强度 高'), findsOneWidget);
    });
  });
}
