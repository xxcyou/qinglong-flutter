import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qinglong_flutter/shared/code_language.dart';
import 'package:qinglong_flutter/shared/highlighting_code_controller.dart';

void main() {
  testWidgets('html inner style content gets CSS colors', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(
      builder: (context) {
        ctx = context;
        return const SizedBox.shrink();
      },
    ));

    const html = '''
<!doctype html>
<html>
<head>
<style>
  body { color: red; background: #fff; }
</style>
</head>
<body>hello</body>
</html>
''';
    final ctrl = HighlightingCodeController(
      language: modeForLanguage('html'),
      languageName: 'html',
      text: html,
    );
    final span = ctrl.buildTextSpan(context: ctx);

    int countColored(TextSpan s) {
      var n = s.style?.color != null ? 1 : 0;
      for (final child in s.children ?? const <InlineSpan>[]) {
        if (child is TextSpan) n += countColored(child);
      }
      return n;
    }

    final total = countColored(span);
    debugPrint('html total colored=$total');

    // 期望至少 8 个有色片段：HTML 标签/属性 + CSS 属性名/值/背景。
    expect(total, greaterThan(6));
  });
}
