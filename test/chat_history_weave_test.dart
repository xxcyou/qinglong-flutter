import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/llm/llm_client.dart';
import 'package:qinglong_flutter/features/ai/providers/chat_provider.dart';

/// 系统簿记（"这一轮执行到的工具：…"、工具结果明细）不能挂在 assistant 消息上。
///
/// 用户原话："提问三个最后一个不调用，显示 这一轮调用过的工具：ask_user。"
/// 那句是我们自己给历史加的记录。它以前拼在 assistant 消息末尾，模型看到
/// "我自己每条回复都这么结尾"，第三问就照着抄——既没调 ask_user，也没回答，
/// 气泡里只剩一句系统内部记录。现在簿记改挂到后面那条 user 消息上。
void main() {
  LlmMessage u(String c) => LlmMessage(role: 'user', content: c);
  LlmMessage a(String c) => LlmMessage(role: 'assistant', content: c);

  test('簿记挪到紧随其后的 user 消息前面，assistant 正文保持干净', () {
    final out = ChatNotifier.weaveHistory(
      [u('帮我建个任务'), a('好，先问一句'), u('用 cron')],
      ['', '（系统记录 · 这一轮执行到的工具：ask_user）', ''],
    );
    expect(out.length, 3);
    expect(out[1].role, 'assistant');
    expect(out[1].content, '好，先问一句', reason: 'assistant 正文里不能夹簿记');
    expect(out[2].role, 'user');
    expect(out[2].content, '（系统记录 · 这一轮执行到的工具：ask_user）\n用 cron');
  });

  test('后面没有 user 消息了 → 簿记作为末尾一条 user 追加', () {
    final out = ChatNotifier.weaveHistory(
      [u('继续'), a('我查了日志')],
      ['', '（系统记录 · 上一轮执行到的工具：log_read）'],
    );
    expect(out.length, 3);
    expect(out.last.role, 'user');
    expect(out.last.content, contains('log_read'));
    expect(out[1].content, '我查了日志');
  });

  test('连着两条 assistant → 两份簿记都不丢，一起挂到下一条 user 上', () {
    final out = ChatNotifier.weaveHistory(
      [a('第一步做完'), a('第二步做完'), u('那继续')],
      ['（记录 A）', '（记录 B）', ''],
    );
    expect(out.length, 3);
    expect(out.last.content, '（记录 A）\n（记录 B）\n那继续');
  });

  /// 提问卡排版不能进历史：模型会照抄它，第二问就不调 ask_user 了。
  group('stripQuestionCard', () {
    const stored = '哈哈丰盛就好，一天都有精神！🍳\n'
        '❓第二个问题：最近天气开始转凉，你晚上一般几点睡？\n'
        '（日常闲聊第二个问题）\n'
        '候选：10点前，养生党 / 11点左右，正常作息';

    test('剥掉 ❓/说明/候选三行，只留模型真说过的话', () {
      expect(
        ChatNotifier.stripQuestionCard(stored),
        '哈哈丰盛就好，一天都有精神！🍳',
      );
    });

    test('被剥掉的问题要能取回来（否则模型不知道自己问过什么，会重复问）', () {
      expect(
        ChatNotifier.questionOfCard(stored),
        '第二个问题：最近天气开始转凉，你晚上一般几点睡？',
      );
    });

    test('正文里只有提问卡 → 剥完是空的', () {
      expect(ChatNotifier.stripQuestionCard('❓你选哪个？\n候选：A / B'), isEmpty);
    });

    test('没有提问卡的正文原样不动', () {
      const plain = '任务建好了。\n候选方案我列在下面：A、B。';
      expect(ChatNotifier.stripQuestionCard(plain), plain);
      expect(ChatNotifier.questionOfCard(plain), isEmpty);
    });
  });

  test('没有簿记时原样透传', () {
    final src = [u('你好'), a('你好')];
    final out = ChatNotifier.weaveHistory(src, ['', '']);
    expect(out.map((m) => '${m.role}:${m.content}').toList(),
        ['user:你好', 'assistant:你好']);
  });
}
