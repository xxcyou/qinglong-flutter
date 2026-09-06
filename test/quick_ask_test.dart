import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/floating/ai_dock_provider.dart';
import 'package:qinglong_flutter/features/ai/models/agent_task_plan.dart';
import 'package:qinglong_flutter/features/ai/models/quick_ask.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 悬浮球快问：长按伸出输入条，问一句，结果弹无边小窗。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer boot() {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  group('输入条', () {
    test('长按开、再长按关', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      expect(c.read(aiDockProvider).quickOpen, isFalse);
      n.toggleQuickAsk();
      expect(c.read(aiDockProvider).quickOpen, isTrue);
      n.toggleQuickAsk();
      expect(c.read(aiDockProvider).quickOpen, isFalse);
    });

    test('草稿留着：转屏、悬浮层重建都不该吃掉打了一半的问题', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      n.setQuickDraft('看看磁盘');
      expect(c.read(aiDockProvider).quickDraft, '看看磁盘');
    });

    test('隐藏悬浮球时输入条一起收（它是挂在球身上的）', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      n.toggleQuickAsk();
      n.hide();
      expect(c.read(aiDockProvider).quickOpen, isFalse);
      expect(c.read(aiDockProvider).visible, isFalse);
    });

    test('展开完整聊天窗时输入条也收起来，不叠两个入口', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      n.toggleQuickAsk();
      n.open();
      expect(c.read(aiDockProvider).quickOpen, isFalse);
      expect(c.read(aiDockProvider).expanded, isTrue);
    });
  });

  group('附件行', () {
    test('箭头只展开/收起附件行，不动输入条', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      n.toggleQuickAsk();
      expect(c.read(aiDockProvider).quickExpand, isFalse);
      n.toggleQuickExpand();
      expect(c.read(aiDockProvider).quickExpand, isTrue);
      expect(c.read(aiDockProvider).quickOpen, isTrue);
      n.toggleQuickExpand();
      expect(c.read(aiDockProvider).quickExpand, isFalse);
      expect(c.read(aiDockProvider).quickOpen, isTrue);
    });

    test('附件只存路径，多个可去重、可单个移除', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      n.addQuickFile(path: '/workspace/a.log', name: 'a.log');
      n.addQuickFile(path: '/workspace/b.log', name: 'b.log');
      n.addQuickFile(path: '/workspace/a.log', name: 'a.log');
      expect(c.read(aiDockProvider).quickFiles, hasLength(2));
      expect(c.read(aiDockProvider).quickFiles.first.path, '/workspace/a.log');
      n.removeQuickFile('/workspace/a.log');
      expect(c.read(aiDockProvider).quickFiles.single.name, 'b.log');
      n.clearQuickFiles();
      expect(c.read(aiDockProvider).quickFiles, isEmpty);
    });

    test('打开完整聊天窗 / 隐藏球时，附件行一起收掉', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      n.toggleQuickAsk();
      n.toggleQuickExpand();
      n.open();
      expect(c.read(aiDockProvider).quickExpand, isFalse);
      n.toggleQuickAsk();
      n.toggleQuickExpand();
      n.hide();
      expect(c.read(aiDockProvider).quickExpand, isFalse);
    });
  });

  group('结果窗', () {
    test('弹出来带着问题回显，可以同时开好几个', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      n.pushQuickResult(question: '磁盘还剩多少', answer: '还剩 12G');
      n.pushQuickResult(question: '有没有失败任务', answer: '有 2 个');
      final list = c.read(aiDockProvider).quickResults;
      expect(list, hasLength(2));
      expect(list.first.question, '磁盘还剩多少');
      expect(list.last.answer, '有 2 个');
      // 层叠错开，别正好压住上一个的关闭按钮。
      expect(list.last.x, greaterThan(list.first.x));
    });

    test('连着弹两个不会撞 id（撞了就变成关一个关掉两个）', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      final ids = <String>{};
      for (var i = 0; i < 20; i++) {
        ids.add(n.pushQuickResult(question: 'q$i', answer: 'a$i'));
      }
      expect(ids, hasLength(20));
      expect(c.read(aiDockProvider).quickResults, hasLength(20));
    });

    test('球被隐藏也照样弹：答案不该被顺手关个球弄没', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      n.hide();
      n.pushQuickResult(question: 'q', answer: 'a');
      expect(c.read(aiDockProvider).quickResults, hasLength(1));
      expect(c.read(aiDockProvider).visible, isTrue);
    });

    test('x 掉一个不影响另一个', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      final a = n.pushQuickResult(question: 'a', answer: '1');
      final b = n.pushQuickResult(question: 'b', answer: '2');
      n.closeQuickResult(a);
      final list = c.read(aiDockProvider).quickResults;
      expect(list, hasLength(1));
      expect(list.single.id, b);
    });

    test('正文窗：有就原位更新，没有才新建', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      final id = n.pushQuickResult(question: 'q', answer: '开头');
      expect(n.hasQuickResult(id), isTrue);

      // 流式中间：原窗更新，不新增。
      final same = n.upsertQuickResult(
        id: id,
        question: 'q',
        answer: '开头继续',
      );
      expect(same, id);
      var list = c.read(aiDockProvider).quickResults;
      expect(list, hasLength(1));
      expect(list.single.answer, '开头继续');

      // 收尾：更新成最终结果。
      n.updateQuickResult(id, answer: '完整答案');
      list = c.read(aiDockProvider).quickResults;
      expect(list.single.answer, '完整答案');

      // 没弹过实时窗时，upsert 走新建。
      final newId = n.upsertQuickResult(
        id: '不存在的id',
        question: 'q2',
        answer: 'a2',
      );
      expect(newId, isNot(id));
      expect(c.read(aiDockProvider).quickResults, hasLength(2));
    });

    test('拖动是增量，且不许拖出屏幕', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      final id = n.pushQuickResult(question: 'q', answer: 'a');
      final before = c.read(aiDockProvider).quickResults.single;
      // 默认窗宽 0.86，右边只剩 0.14 的行程，所以这里挪一小步。
      n.moveQuickResultBy(id, 0.05, 0.05);
      var win = c.read(aiDockProvider).quickResults.single;
      expect(win.x, closeTo(before.x + 0.05, 1e-9));
      expect(win.y, closeTo(before.y + 0.05, 1e-9));
      // 一路往右下拖：贴边就停，不会有一半跑到屏幕外。
      n.moveQuickResultBy(id, 5, 5);
      win = c.read(aiDockProvider).quickResults.single;
      expect(win.x + win.w, lessThanOrEqualTo(1.0000001));
      expect(win.y + win.h, lessThanOrEqualTo(1.0000001));
    });

    test('缩放到最小就停住，不会翻面', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      final id = n.pushQuickResult(question: 'q', answer: 'a');
      n.resizeQuickResult(id, dRight: -5);
      final win = c.read(aiDockProvider).quickResults.single;
      expect(win.w, greaterThanOrEqualTo(QuickResultWindow.minW - 1e-9));
    });

    test('点哪个哪个抬到最上面', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      final a = n.pushQuickResult(question: 'a', answer: '1');
      n.pushQuickResult(question: 'b', answer: '2');
      n.raiseQuickResult(a);
      expect(c.read(aiDockProvider).quickResults.last.id, a);
    });

    test('失败也弹窗：悄悄失败会让人等一个永远不来的结果', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      n.pushQuickResult(question: 'q', answer: '网络不通', failed: true);
      expect(c.read(aiDockProvider).quickResults.single.failed, isTrue);
    });

    test('快问下 ui_c 画布开浮动窗但不展开完整悬浮窗', () {
      final c = boot();
      final n = c.read(aiDockProvider.notifier);
      n.toggleQuickAsk();
      n.showCanvas(const AiCanvas(
        id: 'c1',
        title: '游戏',
        html: '<h1>x</h1>',
        window: 'game',
      ));
      var dock = c.read(aiDockProvider);
      expect(dock.expanded, isFalse);
      expect(dock.quickOpen, isTrue);
      expect(dock.canvasWindows, hasLength(1));

      // 同名更新不叠窗口，多个不同名才多开。
      n.showCanvas(const AiCanvas(
        id: 'c2',
        title: '成绩',
        html: '<h1>y</h1>',
        window: 'score',
      ));
      dock = c.read(aiDockProvider);
      expect(dock.canvasWindows, hasLength(2));

      n.closeCanvas('game');
      dock = c.read(aiDockProvider);
      expect(dock.canvasWindows, hasLength(1));
      expect(dock.quickOpen, isTrue);
    });
  });
}
