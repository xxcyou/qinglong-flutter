import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/floating/ai_dock_provider.dart';

/// 悬浮窗附件的行为约定：
/// 页面自动挂上来的附件（sticky + readOnly）不能抢焦点、发送后要留着、
/// 用户 X 掉之后不能被下一次轮询刷回来。
void main() {
  ProviderContainer makeContainer() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  AiContextChip liveChip(String content) => AiContextChip(
        key: 'log:a.log',
        label: '日志 · a.log',
        content: content,
        source: '日志中心（用户正在看）',
        readOnly: true,
        sticky: true,
        live: () => content,
      );

  test('attach 不展开悬浮窗', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    n.attach(liveChip('line1'));
    final s = c.read(aiDockProvider);
    expect(s.chips.length, 1);
    expect(s.expanded, isFalse);
    expect(s.chips.first.readOnly, isTrue);
  });

  test('push 会展开悬浮窗（手动「发给 AI」）', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    n.push(const AiContextChip(label: '脚本', content: 'x'));
    expect(c.read(aiDockProvider).expanded, isTrue);
  });

  test('同 key 重复 attach 不重复挂，也不会因内容变化重建', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    n.attach(liveChip('line1'));
    final first = c.read(aiDockProvider).chips.first;
    n.attach(liveChip('line1\nline2'));
    final after = c.read(aiDockProvider);
    expect(after.chips.length, 1);
    // live 附件发送时才取内容，所以这里不该换对象（避免轮询刷新抖动）。
    expect(identical(after.chips.first, first), isTrue);
  });

  test('X 掉之后轮询再 attach 不会复活', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    n.attach(liveChip('line1'));
    n.removeChip(0);
    expect(c.read(aiDockProvider).chips, isEmpty);
    n.attach(liveChip('line1\nline2'));
    expect(c.read(aiDockProvider).chips, isEmpty);
  });

  test('离开页面后重新进入，取消记录被清掉', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    n.attach(liveChip('line1'));
    n.removeChip(0);
    n.detach('log:a.log'); // 页面 dispose
    n.attach(liveChip('line1')); // 重新进页面
    expect(c.read(aiDockProvider).chips.length, 1);
  });

  test('手动「发给 AI」能撤销之前的取消', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    n.attach(liveChip('line1'));
    n.removeChip(0);
    n.push(liveChip('line1'));
    expect(c.read(aiDockProvider).chips.length, 1);
    n.attach(liveChip('line1'));
    expect(c.read(aiDockProvider).chips.length, 1);
  });

  test('consumeChips 留下 sticky、清掉手动片段', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    n.attach(liveChip('line1'));
    n.push(const AiContextChip(label: '脚本', content: 'x'), open: false);
    expect(c.read(aiDockProvider).chips.length, 2);
    n.consumeChips();
    final chips = c.read(aiDockProvider).chips;
    expect(chips.length, 1);
    expect(chips.first.sticky, isTrue);
  });

  test('只读附件的提示词里带只读说明，且用 live 取当下内容', () {
    var content = 'v1';
    final chip = AiContextChip(
      key: 'log:a.log',
      label: '日志 · a.log',
      content: 'v1',
      source: '日志中心（用户正在看）',
      readOnly: true,
      sticky: true,
      live: () => content,
    );
    content = 'v2';
    final block = chip.toPromptBlock();
    expect(block, contains('只读'));
    expect(block, contains('v2'));
    expect(block, isNot(contains('v1')));
  });

  test('live 抛异常时回落到快照内容', () {
    final chip = AiContextChip(
      label: '日志',
      content: 'snapshot',
      live: () => throw StateError('gone'),
    );
    expect(chip.effectiveContent, 'snapshot');
  });

  test('pushFile 挂成普通附件：可写、非 sticky、发送后掉', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    final label = n.pushFile(
      path: '/workspace/a.js',
      name: 'a.js',
      content: 'console.log(1)',
      language: 'javascript',
    );
    expect(label, 'a.js');
    var s = c.read(aiDockProvider);
    expect(s.chips.length, 1);
    expect(s.chips.first.readOnly, isFalse);
    expect(s.chips.first.sticky, isFalse);
    // 用户主动加的附件应该把窗口带出来。
    expect(s.expanded, isTrue);
    n.consumeChips();
    s = c.read(aiDockProvider);
    expect(s.chips, isEmpty);
  });

  test('pushFile open:false 不展开悬浮窗（AI 页里用）', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    n.pushFile(
      path: '/workspace/a.js',
      name: 'a.js',
      content: 'x',
      open: false,
    );
    final s = c.read(aiDockProvider);
    expect(s.chips.length, 1);
    expect(s.expanded, isFalse);
  });

  test('同一个文件再挂一次只留一份（按路径去重）', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    n.pushFile(path: '/workspace/a.js', name: 'a.js', content: 'v1');
    n.pushFile(path: '/workspace/a.js', name: 'a.js', content: 'v2');
    final s = c.read(aiDockProvider);
    expect(s.chips.length, 1);
    expect(s.chips.first.content, 'v2');
  });

  test('截断的文件在标签上说明，正文进提示词', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    final label = n.pushFile(
      path: '/workspace/big.log',
      name: 'big.log',
      content: 'head',
      truncated: true,
    );
    expect(label, contains('已截断'));
    final block = c.read(aiDockProvider).chips.first.toPromptBlock();
    expect(block, contains('big.log'));
    expect(block, contains('本地文件 /workspace/big.log'));
    expect(block, contains('head'));
  });

  test('文件附件与只读日志附件能共存，各自独立 X 掉', () {
    final c = makeContainer();
    final n = c.read(aiDockProvider.notifier);
    n.attach(liveChip('line1'));
    n.pushFile(path: '/workspace/a.js', name: 'a.js', content: 'x');
    expect(c.read(aiDockProvider).chips.length, 2);
    final fileIndex = c
        .read(aiDockProvider)
        .chips
        .indexWhere((ch) => ch.key == 'file:/workspace/a.js');
    n.removeChip(fileIndex);
    final s = c.read(aiDockProvider);
    expect(s.chips.length, 1);
    expect(s.chips.first.key, 'log:a.log');
  });
}
