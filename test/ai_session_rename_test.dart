import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qinglong_flutter/features/ai/providers/chat_provider.dart';

void main() {
  // 会话每次变动都会落盘，不给 mock 的话每条断言都会刷一屏 persist 失败。
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  test('renameSession 改名后标题跟着变，空名字不动它', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatProvider.notifier);
    notifier.createSession();
    final id = container.read(chatProvider).currentSessionId;

    notifier.renameSession(id, '  抓包调试  ');
    expect(
      container.read(chatProvider).sessions.firstWhere((s) => s.id == id).title,
      '抓包调试',
    );

    notifier.renameSession(id, '   ');
    expect(
      container.read(chatProvider).sessions.firstWhere((s) => s.id == id).title,
      '抓包调试',
      reason: '空名字应该原地忽略，不能把会话标题清空',
    );

    notifier.renameSession('不存在的会话', 'x');
    expect(container.read(chatProvider).sessions.any((s) => s.title == 'x'), false);
  });

  test('createSession / selectSession / deleteSession 三件套自洽', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(chatProvider.notifier);
    final first = container.read(chatProvider).currentSessionId;
    notifier.createSession();
    final second = container.read(chatProvider).currentSessionId;
    expect(second, isNot(first));
    expect(container.read(chatProvider).sessions.length, 2);

    notifier.selectSession(first);
    expect(container.read(chatProvider).currentSessionId, first);

    notifier.deleteSession(second);
    expect(container.read(chatProvider).sessions.length, 1);
    expect(container.read(chatProvider).currentSessionId, first);

    // 只剩一个时删除退化成清空，不能把会话列表删空。
    notifier.deleteSession(first);
    expect(container.read(chatProvider).sessions.length, 1);
  });
}
