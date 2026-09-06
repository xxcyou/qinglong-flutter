import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 上拉区的布局约束。
///
/// 真机上这里造成过"整个 APP 点不动、把手和菜单条一起消失、只有 AI 悬浮球
/// 还能点"，而且**只在**"上拉出菜单 → 不松手 → 横滑选页 → 松手"这条路径上
/// 出现，点把手拉菜单反而没事。
///
/// 机制：Stack 里的 Positioned 只写 top（bottom/height 都是 null）时，孩子
/// 拿到的竖向约束是无限的，里面又是 SizedBox.expand() →
/// "RenderConstrainedBox object was given an infinite size during layout"。
/// performLayout 抛出后框架吞掉异常，但失败子树自己的 _needsLayout 永远留在
/// true，再也不会被 layout / paint。之后任何一次命中测试走到它就撞
/// 'RenderBox was not laid out' 断言，**整棵树**的命中测试当场中断。
///
/// 为什么横滑那条路径才炸：拖拽收尾时 _navOpen=false 会把拉出区留在树上，
/// 坏掉的 render object 一直挂着；而单纯拉出菜单时 _navOpen=true 让整条
/// 拉出区从树上摘掉，坏节点跟着销毁，树自己愈合了。
void main() {
  testWidgets('拖拽态的拉出区必须有界（top+bottom 都给）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: _Strip(dragging: true)),
    );
    expect(
      tester.takeException(),
      isNull,
      reason: '拖拽态若只给 top，SizedBox.expand 会拿到无限高度直接抛异常',
    );
    // 铺满整屏才对：拖拽时要跟手，手指划到哪都得收得到事件。
    expect(tester.getSize(find.byKey(const Key('strip'))).height, 600);
  });

  testWidgets('非拖拽态是固定 96 高的窄条', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: _Strip(dragging: false)),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('strip'))).height, 96);
  });

  testWidgets('反例：只给 top 会抛无限尺寸异常（这就是当初的 bug）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: _Strip(dragging: true, buggy: true)),
    );
    final err = tester.takeException();
    expect(err, isNotNull);
    expect('$err', contains('infinite size'));
  });

  testWidgets('命中测试不被坏子树带崩：修好后整棵树可命中', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const ColoredBox(color: Color(0xFF000000)),
              ),
            ),
            const Positioned(
              key: Key('strip-host'),
              left: 0,
              right: 0,
              top: 0,
              bottom: 0,
              child: IgnorePointer(child: SizedBox.expand()),
            ),
          ],
        ),
      ),
    );
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    expect(taps, 1, reason: '子树有界时命中测试正常穿透到下面的页面');
  });
}

class _Strip extends StatelessWidget {
  const _Strip({required this.dragging, this.buggy = false});

  final bool dragging;

  /// true = 复刻出问题时的写法（拖拽态只给 top）。
  final bool buggy;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: Color(0xFF102030))),
        Positioned(
          left: 0,
          right: 0,
          top: dragging ? 0 : null,
          bottom: dragging ? (buggy ? null : 0) : 4,
          height: dragging ? null : 96,
          child: const SizedBox.expand(key: Key('strip')),
        ),
      ],
    );
  }
}
