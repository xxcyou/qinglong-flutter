import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/shared/float_stack.dart';

/// 换层级绝不能重建子树。
///
/// 这是这套机制唯一的硬约束：浏览器那一层里挂着常驻 WebView，一旦元素被销毁
/// 重建，页面里的定时器和 Cloudflare 挑战脚本就断了，用户刚过的人机验证白费。
/// 所以 app.dart 里必须给两层带 key，靠 key 复用元素、只换绘制顺序。
class _Probe extends StatefulWidget {
  const _Probe({required this.label, required this.onInit});

  final String label;
  final ValueChanged<String> onInit;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.onInit(widget.label);
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

void main() {
  setUp(() {
    FloatStack.instance.raise(FloatStack.ai);
    FloatStack.instance.raise(FloatStack.browser);
  });

  testWidgets('置前只换顺序，不重建子树（WebView 必须活着）', (tester) async {
    final inits = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: FloatStack.instance,
          builder: (context, _) => Stack(
            children: [
              for (final id in FloatStack.instance.order)
                Positioned.fill(
                  key: ValueKey('float-$id'),
                  child: _Probe(label: id, onInit: inits.add),
                ),
            ],
          ),
        ),
      ),
    );
    expect(inits, [FloatStack.ai, FloatStack.browser]);

    FloatStack.instance.raise(FloatStack.ai);
    await tester.pump();
    // 顺序变了……
    expect(FloatStack.instance.order.last, FloatStack.ai);
    // ……但没有任何一层重新 initState。
    expect(inits, [FloatStack.ai, FloatStack.browser]);

    FloatStack.instance.raise(FloatStack.browser);
    await tester.pump();
    expect(inits, [FloatStack.ai, FloatStack.browser]);
  });

  testWidgets('栈顶的那一层画在最后（后画者在上）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: FloatStack.instance,
          builder: (context, _) => Stack(
            children: [
              for (final id in FloatStack.instance.order)
                Positioned.fill(
                  key: ValueKey('float-$id'),
                  child: Align(alignment: Alignment.topLeft, child: Text(id)),
                ),
            ],
          ),
        ),
      ),
    );

    List<String> painted() => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data!)
        .toList();

    expect(painted().last, FloatStack.browser);
    FloatStack.instance.raise(FloatStack.ai);
    await tester.pump();
    expect(painted().last, FloatStack.ai);
  });

  testWidgets('悬浮层必须撑满屏幕：Positioned.fill 的孩子不能挂在松约束下', (tester) async {
    // 真实事故：把这层 Stack 直接当 Stack 的非定位子节点写，它没有任何
    // 非定位孩子，于是把自己缩成 0×0，AI 悬浮球和浏览器一起从屏幕上消失
    // （编译不报错、analyze 不报错，只有跑起来点不到）。
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFF000000))),
            Positioned.fill(
              child: AnimatedBuilder(
                key: const Key('float-layer'),
                animation: FloatStack.instance,
                builder: (context, _) => Stack(
                  children: [
                    for (final id in FloatStack.instance.order)
                      Positioned.fill(
                        key: ValueKey('float-$id'),
                        child: const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final screen = tester.getSize(find.byType(MaterialApp));
    final layer = tester.getSize(find.byKey(const Key('float-layer')));
    expect(layer, screen);
    expect(layer.width, greaterThan(0));
    expect(layer.height, greaterThan(0));
  });
}
