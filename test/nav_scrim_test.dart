import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 菜单展开时铺的那层"幕"不能吃掉下面页面的操作。
///
/// 线上现象：菜单一拉出来，整个 APP 就失灵——列表滑不动、卡片点不了、
/// ⋮ 菜单弹不出来，必须先瞎点一下把菜单关掉。根因是那层幕用了
/// GestureDetector(behavior: opaque)，命中它之后事件就到不了下面。
void main() {
  late ScrollController scroll;

  Widget host({required bool opaqueScrim, required VoidCallback onScrim}) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: ListView.builder(
                controller: scroll,
                itemCount: 40,
                itemBuilder: (_, i) => SizedBox(height: 80, child: Text('行 $i')),
              ),
            ),
            Positioned.fill(
              child: opaqueScrim
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onScrim,
                      child: const SizedBox.expand(),
                    )
                  : Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) => onScrim(),
                      child: const SizedBox.expand(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  setUp(() => scroll = ScrollController());
  tearDown(() => scroll.dispose());

  testWidgets('translucent 幕：滚动照旧生效，同时能收起菜单', (tester) async {
    var closed = 0;
    await tester.pumpWidget(host(opaqueScrim: false, onScrim: () => closed++));
    expect(scroll.offset, 0);
    await tester.drag(find.text('行 1'), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(100), reason: '幕不该拦住滚动');
    expect(closed, greaterThan(0), reason: '碰到内容区仍要收起菜单');
  });

  testWidgets('对照：opaque 幕把滚动整个吃掉（这就是线上那个 bug）', (tester) async {
    var closed = 0;
    await tester.pumpWidget(host(opaqueScrim: true, onScrim: () => closed++));
    // warnIfMissed: false —— "打不中列表"正是要证明的事。
    await tester.drag(
      find.text('行 1'),
      const Offset(0, -240),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(closed, 0, reason: 'drag 不是 tap，opaque 幕连收起都做不到');
  });
}
