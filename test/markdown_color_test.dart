import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/widgets/markdown_message.dart';

List<TextSpan> _textSpans(WidgetTester tester) {
  final out = <TextSpan>[];
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    rich.text.visitChildren((span) {
      if (span is TextSpan) out.add(span);
      return true;
    });
  }
  return out;
}

TextSpan _spanWith(WidgetTester tester, String text) =>
    _textSpans(tester).firstWhere(
      (span) => span.text?.contains(text) ?? false,
      orElse: () => const TextSpan(),
    );

void main() {
  testWidgets('gold 颜色标签能渲染，并且支持外层加粗', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownMessage(text: '**{c:gold}重要结论 42{/c}**', selectable: false),
      ),
    ));
    final span = _spanWith(tester, '重要结论');
    expect(span.style?.color, const Color(0xFFFFD700));
    expect(span.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('cyan 时间节点颜色标签能渲染', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownMessage(text: '下次执行：{c:cyan}2026-01-01 08:00{/c}', selectable: false),
      ),
    ));
    final span = _spanWith(tester, '2026-01-01');
    expect(span.style?.color, const Color(0xFF80DEEA));
  });

  testWidgets('未知颜色名不崩溃，文字照常显示', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownMessage(text: '{c:notacolor}兜底文字{/c}', selectable: false),
      ),
    ));
    expect(_spanWith(tester, '兜底文字').text, '兜底文字');
    expect(tester.takeException(), isNull);
  });
}
