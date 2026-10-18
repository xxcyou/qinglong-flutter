import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/router.dart';
import 'package:qinglong_flutter/shared/confirm_dialog.dart';
import 'package:qinglong_flutter/shared/text_input_dialog.dart';

/// 悬浮层挂在 Navigator 之上，没有 Navigator 祖先；弹窗必须借根 Navigator。
/// 这个回归保护容器文件管理的“重命名/删除/新建”弹窗不再抛
/// `Null check operator used on a null value`。
void main() {
  testWidgets('悬浮层里 showTextInputDialog 能借根 Navigator 弹出', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigatorKey,
        // builder 里是 Navigator 之上：这个 context 没有 Navigator 祖先。
        builder: (context, child) => Stack(
          children: [
            if (child != null) Positioned.fill(child: child),
            Positioned(
              left: 0,
              top: 0,
              child: Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () async {
                    result = await showTextInputDialog(
                      ctx,
                      title: '重命名',
                      initialValue: 'old.txt',
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ],
        ),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('old.txt'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'new.txt');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, 'new.txt');
  });

  testWidgets('借根 Navigator 的 context 能直接 push 页面', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigatorKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    final nav = Navigator.of(appNavigatorKey.currentContext!);
    nav.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Center(child: Text('pushed page'))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('pushed page'), findsOneWidget);
  });

  testWidgets('悬浮层里 showConfirmDialog 能借根 Navigator 弹出', (tester) async {
    var confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigatorKey,
        builder: (context, child) => Stack(
          children: [
            if (child != null) Positioned.fill(child: child),
            Positioned(
              left: 0,
              top: 0,
              child: Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () async {
                    confirmed = await showConfirmDialog(
                      ctx,
                      title: '删除 file？',
                      message: '不可恢复',
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ],
        ),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('删除 file？'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });
}
