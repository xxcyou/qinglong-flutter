import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/shared/code_editor.dart';
import 'package:qinglong_flutter/shared/code_language.dart';
import 'package:qinglong_flutter/shared/editor_bus.dart';
import 'package:qinglong_flutter/shared/highlighting_code_controller.dart';

/// 可视化编辑的核心不是"controller 里有没有新代码"，而是"屏幕上有没有变"。
/// 这些测试直接读渲染层（EditableText 实际拿到的值），复现设备上出现的
/// "AI 写完 editor_read 能读到，但屏幕还是旧文本"。
void main() {
  const path = '/workspace/visual.js';

  Future<EditorHandle> mount(
    WidgetTester tester,
    String initial,
  ) async {
    final controller = HighlightingCodeController(
      language: languageForPath(path),
      languageName: languageNameForPath(path),
      text: initial,
    );
    final key = GlobalKey<CodeEditorFieldState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeEditorField(
            key: key,
            controller: controller,
            path: path,
          ),
        ),
      ),
    );
    await tester.pump();
    return EditorHandle(
      id: 1,
      kind: EditorKind.shellFile,
      title: 'visual.js',
      path: path,
      controller: controller,
      editorKey: key,
    );
  }

  /// 渲染层真正显示的文本。
  ///
  /// 关键：读的是 `EditableTextState.textEditingValue`（它内部缓存的 `_value`）
  /// 和 `RenderEditable` 真正画出来的字，**不是** controller 里的值。
  /// 设备上的故障正是两者脱节：controller 已经是新代码，屏幕还是旧文本。
  ({String state, String painted}) rendered(WidgetTester tester) {
    for (final element in find.byType(EditableText).evaluate()) {
      final widget = element.widget as EditableText;
      if (widget.controller is! HighlightingCodeController) continue;
      final state = (element as StatefulElement).state as EditableTextState;
      // EditableText 外面还包了一层 _RenderCompositionCallback，
      // findRenderObject 拿到的是它，要往下走才是 RenderEditable。
      RenderEditable? editable;
      void dig(RenderObject node) {
        if (editable != null) return;
        if (node is RenderEditable) {
          editable = node;
          return;
        }
        node.visitChildren(dig);
      }

      dig(element.findRenderObject()!);
      return (
        state: state.textEditingValue.text,
        painted: editable?.text?.toPlainText() ?? '<no RenderEditable>',
      );
    }
    fail('找不到代码编辑域');
  }

  void expectRendered(WidgetTester tester, EditorHandle handle) {
    final view = rendered(tester);
    expect(
      view.state,
      handle.controller.text,
      reason: 'EditableText 缓存值和 controller 脱节：用户下一次打字会盖掉 AI 的改动',
    );
    expect(view.painted, handle.controller.text, reason: '屏幕上画出来的字和 controller 不一致');
  }

  /// 行号栏当前的内容。
  String gutter(WidgetTester tester) {
    final editables = tester.widgetList<EditableText>(find.byType(EditableText));
    for (final e in editables) {
      if (e.controller is! HighlightingCodeController) return e.controller.text;
    }
    return '';
  }

  /// 跑完一次可视化编辑：动画是 Future.delayed 串起来的，
  /// 在 widget 测试里要不停 pump 才会推进。
  Future<String> drain(WidgetTester tester, Future<String> future) async {
    String? result;
    Object? error;
    future.then((v) => result = v, onError: (Object e) => error = e);
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      if (result != null || error != null) break;
    }
    if (error != null) fail('可视化编辑抛异常：$error');
    return result ?? '<未完成>';
  }

  testWidgets('editor_insert：插入的代码要出现在屏幕上', (tester) async {
    final handle = await mount(tester, 'const A = 1;\n');
    await drain(
      tester,
      EditorBus.instance.insertAtLine(handle, line: 1, text: '// hello'),
    );
    expect(handle.controller.text, contains('// hello'));
    expectRendered(tester, handle);
  });

  testWidgets('editor_write：整篇重写后屏幕要跟上', (tester) async {
    final handle = await mount(tester, 'const OLD = 1;\nconsole.log(OLD);\n');
    await drain(
      tester,
      EditorBus.instance.replaceAll(handle, 'const NEW = 2;\nconsole.log(NEW);\n'),
    );
    expect(handle.controller.text, 'const NEW = 2;\nconsole.log(NEW);\n');
    expectRendered(tester, handle);
    expect(gutter(tester), '1\n2\n3');
  });

  testWidgets('editor_patch：替换后屏幕要跟上', (tester) async {
    final handle = await mount(tester, 'function hi(n) {\n  return "hi " + n;\n}\n');
    await drain(
      tester,
      EditorBus.instance.patch(
        handle,
        oldText: 'return "hi " + n;',
        newText: 'return `hi \${n}!`;',
      ),
    );
    expect(handle.controller.text, contains(r'return `hi ${n}!`;'));
    expectRendered(tester, handle);
  });

  testWidgets('editor_delete：删行后屏幕要跟上', (tester) async {
    final handle = await mount(tester, 'a\nb\nc\nd\n');
    await drain(
      tester,
      EditorBus.instance.deleteLines(handle, from: 2, to: 3),
    );
    expect(handle.controller.text, 'a\nd\n');
    expectRendered(tester, handle);
  });

  testWidgets('空文档里写代码：不能被自动补全修饰器改坏', (tester) async {
    final handle = await mount(tester, '');
    const code = 'function f() {\n  return [1, 2];\n}\n';
    await drain(tester, EditorBus.instance.replaceAll(handle, code));
    expect(handle.controller.text, code);
    expectRendered(tester, handle);
  });

  testWidgets('editor_patch 按行号替换：前缀冲突的行也能改', (tester) async {
    // `// line 20` 同时也是 `// line 200` 的前缀：按原文匹配必然
    // 报"匹配到多处"，模型换几个写法都过不去，只能按行号。
    final src = List.generate(200, (i) => '// line ${i + 1}').join('\n');
    final handle = await mount(tester, '$src\n');
    final message = await drain(
      tester,
      EditorBus.instance.replaceLines(
        handle,
        from: 20,
        to: 20,
        text: '// TARGET-20',
      ),
    );
    final lines = handle.controller.text.split('\n');
    expect(lines[19], '// TARGET-20');
    expect(lines[18], '// line 19', reason: '上一行不能被动到');
    expect(lines[20], '// line 21', reason: '下一行不能被动到');
    expect(lines.length, 201, reason: '总行数不变（末尾空行算一行）');
    expect(message, contains('第 20'));
    expectRendered(tester, handle);
  });

  testWidgets('editor_patch 按原文匹配到多处时必须报错而不是乱改', (tester) async {
    final handle = await mount(tester, '// line 20\n// line 200\n');
    await expectLater(
      EditorBus.instance.patch(
        handle,
        oldText: '// line 20',
        newText: '// TARGET',
      ),
      throwsA(isA<EditorBusException>()),
    );
  });

  testWidgets('替换末行不多补换行', (tester) async {
    final handle = await mount(tester, 'a\nb\nc');
    await drain(
      tester,
      EditorBus.instance.replaceLines(handle, from: 3, to: 3, text: 'z'),
    );
    expect(handle.controller.text, 'a\nb\nz');
    expectRendered(tester, handle);
  });

  testWidgets('改远处的行要把视野滚过去', (tester) async {
    // 设备上的故障：AI 改第 180 行，用户屏幕还停在第 1 行。
    // revealCursor() 之前往下找 EditableText（其实在上面），
    // 永远找不到 → 整个方法空转。这条测试盯住"滚动位置真的动了"。
    final src = List.generate(200, (i) => '// line ${i + 1}').join('\n');
    final handle = await mount(tester, '$src\n');
    ScrollPosition? vertical;
    for (final element in find.byType(Scrollable).evaluate()) {
      final state = (element as StatefulElement).state as ScrollableState;
      if (state.position.axis == Axis.vertical &&
          state.position.maxScrollExtent > 0) {
        vertical = state.position;
      }
    }
    expect(vertical, isNotNull, reason: '200 行应该撑出竖向滚动');
    expect(vertical!.pixels, 0, reason: '初始停在顶部');
    await drain(
      tester,
      EditorBus.instance.replaceLines(
        handle,
        from: 180,
        to: 180,
        text: '// TARGET-180',
      ),
    );
    await tester.pumpAndSettle();
    expect(vertical.pixels, greaterThan(0), reason: '视野必须跟着光标走');
    expect(handle.controller.text.split('\n')[179], '// TARGET-180');
  });

  testWidgets('一段 AI 改动只占一次撤销', (tester) async {
    final handle = await mount(tester, 'const A = 1;\n');
    await drain(
      tester,
      EditorBus.instance.replaceAll(handle, 'const B = 2;\nconst C = 3;\n'),
    );
    final state = handle.editorKey.currentState!;
    expect(state.canUndo, isTrue);
    state.undo();
    await tester.pump();
    expect(handle.controller.text, 'const A = 1;\n');
    expect(state.canUndo, isFalse, reason: '整段动画应该只入栈一次');
  });
}
