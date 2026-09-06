import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/llm/tool_call_recovery.dart';

void main() {
  group('LlmToolCallRecovery', () {
    test('普通正文不会被误判成工具调用', () {
      const text = '你现在有 3 个任务，其中 1 个是禁用的。';
      final r = LlmToolCallRecovery.scan(text);
      expect(r.calls, isEmpty);
      expect(r.sawMarkup, isFalse);
      expect(r.content, text);
    });

    test('正文里贴的普通 JSON 不算工具调用', () {
      // 用户经常让 AI 解释一段配置，回复里就会有裸 JSON。
      // 这种绝不能被当成调用，否则会凭空执行东西。
      const text = '{"cron": "0 8 * * *", "enabled": true}';
      final r = LlmToolCallRecovery.scan(text);
      expect(r.calls, isEmpty);
    });

    test('DeepSeek DSML 泄漏能捞回来', () {
      const text = '我来看看这个任务。\n'
          '<\uFF5Ctool\u2581call\u2581begin\uFF5C>function'
          '<\uFF5Ctool\u2581sep\uFF5C>cron_log\n'
          '```json\n{"id": 7}\n```'
          '<\uFF5Ctool\u2581call\u2581end\uFF5C>';
      final r = LlmToolCallRecovery.scan(text);
      expect(r.calls.length, 1);
      expect(r.calls.first.name, 'cron_log');
      expect(r.calls.first.arguments['id'], 7);
      // 调用前那句话要留着，标记要清干净。
      expect(r.content, '我来看看这个任务。');
      expect(r.content.contains('tool'), isFalse);
    });

    test('DSML 一轮里多个调用都要捞到', () {
      const text = '<\uFF5Ctool\u2581call\u2581begin\uFF5C>function'
          '<\uFF5Ctool\u2581sep\uFF5C>cron_list\n```json\n{}\n```'
          '<\uFF5Ctool\u2581call\u2581end\uFF5C>'
          '<\uFF5Ctool\u2581call\u2581begin\uFF5C>function'
          '<\uFF5Ctool\u2581sep\uFF5C>env_list\n```json\n{"search":"CK"}\n```'
          '<\uFF5Ctool\u2581call\u2581end\uFF5C>';
      final r = LlmToolCallRecovery.scan(text);
      expect(r.calls.map((c) => c.name).toList(), ['cron_list', 'env_list']);
      expect(r.calls[1].arguments['search'], 'CK');
      expect(r.content.trim(), isEmpty);
    });

    test('Hermes / Qwen 风格的 <tool_call> 也能捞回来', () {
      const text = '好，我查一下。\n'
          '<tool_call>\n{"name": "script_read", "arguments": {"path": "a/b.js"}}\n</tool_call>';
      final r = LlmToolCallRecovery.scan(text);
      expect(r.calls.length, 1);
      expect(r.calls.first.name, 'script_read');
      expect(r.calls.first.arguments['path'], 'a/b.js');
      expect(r.content, '好，我查一下。');
    });

    test('arguments 是字符串形式的 JSON 也能解开', () {
      const text = '<tool_call>{"name":"editor_read","arguments":"{\\"target\\":\\"config\\"}"}</tool_call>';
      final r = LlmToolCallRecovery.scan(text);
      expect(r.calls.length, 1);
      expect(r.calls.first.arguments['target'], 'config');
    });

    test('整段就是 name+arguments 的裸 JSON 当作调用', () {
      const text = '{"name": "cron_list", "arguments": {"search": "签到"}}';
      final r = LlmToolCallRecovery.scan(text);
      expect(r.calls.length, 1);
      expect(r.calls.first.name, 'cron_list');
      expect(r.content, isEmpty);
    });

    test('围栏包起来的裸调用 JSON 同样认', () {
      const text = '```json\n{"name": "system_info", "arguments": {}}\n```';
      final r = LlmToolCallRecovery.scan(text);
      expect(r.calls.length, 1);
      expect(r.calls.first.name, 'system_info');
    });

    test('参数 JSON 坏掉时仍然交出调用，不静默丢弃', () {
      const text = '<\uFF5Ctool\u2581call\u2581begin\uFF5C>function'
          '<\uFF5Ctool\u2581sep\uFF5C>cron_run\n```json\n{id: 7,,}\n```';
      final r = LlmToolCallRecovery.scan(text);
      expect(r.calls.length, 1);
      expect(r.calls.first.name, 'cron_run');
      expect(r.calls.first.arguments.containsKey('_raw'), isTrue);
    });

    test('只剩分隔符的残缺形态也能救', () {
      const text = 'function<\uFF5Ctool\u2581sep\uFF5C>system_info\n```json\n{}\n```';
      final r = LlmToolCallRecovery.scan(text);
      expect(r.calls.length, 1);
      expect(r.calls.first.name, 'system_info');
    });

    test('有标记但完全解析不出来时要报告 sawMarkup', () {
      // 这种轮次绝不能被当成"模型答完了"。
      const text = '<\uFF5Ctool\u2581calls\u2581begin\uFF5C> 我准备调用工具了';
      final r = LlmToolCallRecovery.scan(text);
      expect(r.calls, isEmpty);
      expect(r.sawMarkup, isTrue);
    });
  });
}
