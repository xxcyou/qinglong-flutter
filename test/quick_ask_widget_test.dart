import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/floating/ai_dock_overlay.dart';
import 'package:qinglong_flutter/features/ai/floating/ai_dock_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 长按悬浮球 → 旁边伸出输入框、球变成发送键；再长按 → 收回去。
///
/// 这一层单独测，是因为悬浮层最容易出的事故是**布局崩**：
/// `Positioned` 只钉一侧时那条轴是无界的，里面塞会撑满的东西就抛
/// "infinite size"，整棵子树 hitTest 直接失效——表现就是"整屏点不动"。
void main() {
  Widget host() {
    SharedPreferences.setMockInitialValues({});
    return const ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Stack(children: [AiBubbleLayer()]),
        ),
      ),
    );
  }

  testWidgets('长按伸出输入框，球换成发送图标', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.longPress(find.byIcon(Icons.auto_awesome));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(TextField), findsOneWidget);
    // 球现在是发送键：图标必须跟着换，否则用户不敢点。
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
  });

  testWidgets('球在左边时，箭头也始终在（视觉朝球，旋转由动画完成）', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 50));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AiBubbleLayer)),
    );
    container.read(aiDockProvider.notifier).moveTo(0, 0.5);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.longPress(find.byIcon(Icons.auto_awesome));
    await tester.pump(const Duration(milliseconds: 50));

    // 箭头是同一个基础图标，靠 AnimatedRotation 转出朝向/向上的动画。
    expect(find.byIcon(Icons.keyboard_arrow_right), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_left), findsNothing);
  });

  testWidgets('点箭头展开附件行：输入框还在，加文件可 X 掉', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.longPress(find.byIcon(Icons.auto_awesome));
    await tester.pump(const Duration(milliseconds: 50));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AiBubbleLayer)),
    );
    final notifier = container.read(aiDockProvider.notifier);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_right));
    await tester.pump(const Duration(milliseconds: 50));

    expect(container.read(aiDockProvider).quickExpand, isTrue);
    // 展开的是输入框上面的附件行，不是把输入框收起来。
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.attach_file), findsOneWidget);

    notifier.addQuickFile(path: '/workspace/a.log', name: 'a.log');
    notifier.addQuickFile(path: '/workspace/b.log', name: 'b.log');
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('a.log'), findsOneWidget);
    expect(find.text('b.log'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNWidgets(2));

    notifier.removeQuickFile('/workspace/a.log');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('a.log'), findsNothing);
    expect(find.text('b.log'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_right));
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.read(aiDockProvider).quickExpand, isFalse);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('再长按收回去，草稿留着', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.longPress(find.byIcon(Icons.auto_awesome));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField), '磁盘还剩多少');
    await tester.pump();

    await tester.longPress(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(TextField), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AiBubbleLayer)),
    );
    // 收回去不等于扔掉：打了一半的问题下次长按还在。
    expect(container.read(aiDockProvider).quickDraft, '磁盘还剩多少');
  });

  testWidgets('长按不再隐藏悬浮球（隐藏只在设置里）', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.longPress(find.byIcon(Icons.auto_awesome));
    await tester.pump(const Duration(milliseconds: 50));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AiBubbleLayer)),
    );
    expect(container.read(aiDockProvider).visible, isTrue);
  });

  testWidgets('结果窗：可关、内容显示出来', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 50));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AiBubbleLayer)),
    );
    container.read(aiDockProvider.notifier).pushQuickResult(
          question: '磁盘还剩多少',
          answer: '还剩 12G',
        );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('磁盘还剩多少'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.read(aiDockProvider).quickResults, isEmpty);
    expect(find.text('磁盘还剩多少'), findsNothing);
  });

  testWidgets('悬浮球隐藏了，已经弹出来的结果窗还留着', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 50));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AiBubbleLayer)),
    );
    container.read(aiDockProvider.notifier).pushQuickResult(
          question: 'q',
          answer: 'a',
        );
    await tester.pump(const Duration(milliseconds: 50));
    container.read(aiDockProvider.notifier).hide();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('q'), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
  });
}
