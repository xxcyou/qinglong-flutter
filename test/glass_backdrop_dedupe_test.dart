import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/theme/glass.dart';

/// 背景层去重。
///
/// 真机上这里造成过整个 APP"点了没反应 / 菜单一闪一闪"：外壳一层
/// GlassBackdrop，IndexedStack 里六个标签页的 GlassScaffold 又各一层，
/// 一共 7 层背景 + 21 个径向渐变。IndexedStack 用 Visibility.maintain
/// 保活，离屏页照样 build/layout，于是光斑每跳一格（50ms）就把 7 层背景
/// 全重建一遍——实测单帧 build 146ms，交互时只有 ~7fps。
void main() {
  testWidgets('嵌套的 GlassBackdrop 只画一层背景', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: GlassBackdrop(
          child: GlassBackdrop(
            child: GlassBackdrop(child: Text('内容')),
          ),
        ),
      ),
    );
    // 三层 GlassBackdrop widget 都在树上（透传的那两层直接返回 child）……
    expect(find.byType(GlassBackdrop), findsNWidgets(3));
    // ……但只有最外层真的建出背景栈：内层只剩一个 child。
    // 用光斑层的数量来数：每层真背景恰好一个 RepaintBoundary + IgnorePointer 组合。
    final backdrops = tester.widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(GlassBackdrop).first,
        matching: find.byType(DecoratedBox),
      ),
    );
    // 一层背景 = 1 个渐变 DecoratedBox。多层就会有多个。
    expect(
      backdrops.where((d) {
        final deco = d.decoration;
        return deco is BoxDecoration && deco.gradient is LinearGradient;
      }).length,
      1,
      reason: '嵌套 GlassBackdrop 必须只留最外层那一份渐变背景',
    );
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('单独使用时正常画背景', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: GlassBackdrop(child: Text('内容'))),
    );
    final grads = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where((d) {
      final deco = d.decoration;
      return deco is BoxDecoration && deco.gradient is LinearGradient;
    });
    expect(grads.length, 1);
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('离屏页（TickerMode false）不订阅光斑相位', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TickerMode(
          enabled: false,
          child: GlassBackdrop(child: Text('离屏')),
        ),
      ),
    );
    // 光斑靠 ValueListenableBuilder 订阅 GlassFlow.phase；
    // 离屏时必须一个都不建，否则六个离屏页会跟着每 50ms 重建一次。
    expect(
      find.byType(ValueListenableBuilder<double>),
      findsNothing,
      reason: 'TickerMode 关闭时光斑不该订阅相位',
    );
  });
}
