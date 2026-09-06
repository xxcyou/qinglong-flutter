import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/llm/llm_client.dart';

/// 造一行 SSE 数据。
String sse(Map<String, dynamic> delta, {String? finish}) =>
    'data: ${jsonEncode({
          'choices': [
            {
              'index': 0,
              'delta': delta,
              if (finish != null) 'finish_reason': finish,
            },
          ],
        })}';

void main() {
  group('LlmStreamAssembler', () {
    test('思考与正文分别累积，并按片回调', () {
      final deltas = <LlmDelta>[];
      final a = LlmStreamAssembler(onDelta: deltas.add);

      expect(a.addLine(sse({'role': 'assistant', 'content': ''})), isTrue);
      a.addLine(sse({'reasoning_content': '先看'}));
      a.addLine(sse({'reasoning_content': '一眼日志'}));
      a.addLine(sse({'content': '结论是'}));
      a.addLine(
          sse({'content': '脚本挂了', 'reasoning_content': ''}, finish: 'stop'));
      expect(a.addLine('data: [DONE]'), isTrue);

      expect(a.reasoning, '先看一眼日志');
      expect(a.content, '结论是脚本挂了');
      expect(a.finishReason, 'stop');
      expect(a.done, isTrue);
      expect(a.sawData, isTrue);
      // 空 delta（只有 role）不该回调，否则界面每片都白重建一次。
      expect(deltas.length, 4);
      expect(deltas.first.reasoning, '先看');
      expect(deltas.last.content, '脚本挂了');
    });

    test('工具调用分片按 index 归堆，参数拼回完整 JSON', () {
      final deltas = <LlmDelta>[];
      final a = LlmStreamAssembler(onDelta: deltas.add);

      a.addLine(sse({
        'tool_calls': [
          {
            'index': 0,
            'id': 'call_1',
            'function': {'name': 'ql_task_list', 'arguments': ''},
          },
        ],
      }));
      a.addLine(sse({
        'tool_calls': [
          {
            'index': 0,
            'function': {'arguments': '{"sea'},
          },
        ],
      }));
      a.addLine(sse({
        'tool_calls': [
          {
            'index': 0,
            'function': {'arguments': 'rch":"抽奖"}'},
          },
        ],
      }));

      final calls = a.toolCalls;
      expect(calls, hasLength(1));
      expect(calls.single.id, 'call_1');
      expect(calls.single.name, 'ql_task_list');
      expect(calls.single.arguments, {'search': '抽奖'});
      // 工具名一出来就得报出去：界面靠它显示"准备调用 xxx"。
      expect(deltas.where((d) => d.toolName == 'ql_task_list'), hasLength(1));
    });

    test('多个工具调用按 index 排序，缺 index 时按出现顺序兜底', () {
      final a = LlmStreamAssembler();
      a.addLine(sse({
        'tool_calls': [
          {
            'index': 1,
            'id': 'b',
            'function': {'name': 'second', 'arguments': '{}'},
          },
          {
            'index': 0,
            'id': 'a',
            'function': {'name': 'first', 'arguments': '{}'},
          },
        ],
      }));
      expect([for (final c in a.toolCalls) c.name], ['first', 'second']);

      final b = LlmStreamAssembler();
      b.addLine(sse({
        'tool_calls': [
          {
            'id': 'x',
            'function': {'name': 'only', 'arguments': '{}'},
          },
        ],
      }));
      expect([for (final c in b.toolCalls) c.name], ['only']);
    });

    test('坏掉的 data 行不影响整轮，非 data 行不算 SSE', () {
      final a = LlmStreamAssembler();
      expect(a.addLine('data: {不是 json'), isTrue);
      expect(a.addLine(': keep-alive'), isTrue);
      expect(a.addLine('{"choices":[]}'), isFalse);
      expect(a.addLine(''), isFalse);
      a.addLine(sse({'content': '还活着'}));
      expect(a.content, '还活着');
    });

    test('usage 从末片取出；只有 message 的末片也能吃下', () {
      final a = LlmStreamAssembler();
      a.addLine(sse({'content': 'hi'}));
      a.addLine('data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'message': {'content': '!'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 120,
              'completion_tokens': 30,
              'total_tokens': 150,
              'prompt_tokens_details': {'cached_tokens': 100},
            },
          })}');
      expect(a.content, 'hi!');
      expect(a.usage.totalTokens, 150);
      expect(a.usage.cacheHitTokens, 100);
      // 空 usage 不能把已经拿到的那份覆盖掉。
      a.addLine('data: ${jsonEncode({
            'choices': [
              {'index': 0, 'delta': <String, dynamic>{}},
            ],
            'usage': {'prompt_tokens': 0, 'total_tokens': 0},
          })}');
      expect(a.usage.totalTokens, 150);
    });

    test('reasoning / thinking 别名都认，多模态 content 数组也认', () {
      final a = LlmStreamAssembler();
      a.addLine(sse({'reasoning': '别名一'}));
      a.addLine(sse({'thinking': '别名二'}));
      a.addLine(sse({
        'content': [
          {'type': 'text', 'text': '数组正文'},
        ],
      }));
      expect(a.reasoning, '别名一别名二');
      expect(a.content, '数组正文');
    });
  });

  group('decodeToolArguments', () {
    test('正常 JSON 直接解析', () {
      expect(LlmClient.decodeToolArguments('{"a":1}'), {'a': 1});
    });

    test('空串给空 map', () {
      expect(LlmClient.decodeToolArguments('   '), isEmpty);
    });

    test('坏 JSON 保留原文到 _raw，不能静默变成空参数', () {
      expect(LlmClient.decodeToolArguments('{"a":'), {'_raw': '{"a":'});
    });
  });

  group('parseToolCalls', () {
    test('非流式结构化 tool_calls', () {
      final calls = LlmClient.parseToolCalls([
        {
          'id': 'c1',
          'function': {'name': 'foo', 'arguments': '{"x":true}'},
        },
        {'id': 'bad'},
      ]);
      expect(calls, hasLength(1));
      expect(calls.single.name, 'foo');
      expect(calls.single.arguments, {'x': true});
    });

    test('不是列表时给空', () {
      expect(LlmClient.parseToolCalls(null), isEmpty);
      expect(LlmClient.parseToolCalls('nope'), isEmpty);
    });
  });
}
