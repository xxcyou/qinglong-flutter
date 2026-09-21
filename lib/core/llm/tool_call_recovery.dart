import 'dart:convert';

import 'llm_client.dart';

/// 从**正文**里把泄漏出来的工具调用捞回来。
///
/// 为什么必须有这一层：DeepSeek 系模型的工具调用在底层是一串特殊 token
/// （DSML：`<｜tool▁calls▁begin｜>` … `<｜tool▁sep｜>` …），正常情况下服务端会把它
/// 解析成 OpenAI 兼容的 `tool_calls` 字段。但这个解析并不稳定——上游少发一个
/// 起始 token、流式拼接错位、或者模型在长对话里把 DSML 当普通文本吐出来，
/// 服务端就会原样塞进 `content`，`tool_calls` 变成空数组。
///
/// 对我们的循环来说，那一轮就成了"模型不调工具、直接给了正文" → 判定为答完收工。
/// 用户看到的正是"有时候显示调用了工具、有时候没有，还带着编出来的工具输出"
/// ——同一句话时好时坏，像薛定谔的猫。
///
/// 所以这里做一次兜底解析：正文里只要能认出工具调用，就把它当成真的调用，
/// 并把这段标记从正文里剔掉（不然用户会看到一堆乱码）。
///
/// 兼容三种常见泄漏格式：
/// 1. DeepSeek DSML：`<｜tool▁call▁begin｜>function<｜tool▁sep｜>名字\n```json\n{...}\n``` `
/// 2. Hermes / Qwen 风格：`<tool_call>{"name": …, "arguments": {…}}</tool_call>`
/// 3. 裸 JSON 兜底：整段正文就是 `{"name": …, "arguments": {…}}`
class RecoveredToolCalls {
  const RecoveredToolCalls({
    required this.content,
    required this.calls,
    this.sawMarkup = false,
  });

  /// 剔掉标记之后的正文。
  final String content;

  /// 捞回来的工具调用。
  final List<LlmToolCall> calls;

  /// 正文里出现过工具调用标记（哪怕没解析成功）。
  ///
  /// 用来区分"模型确实只想说话"和"模型想调工具但格式坏了"——后者要重试，
  /// 不能当成答完了。
  final bool sawMarkup;

  bool get isEmpty => calls.isEmpty;
}

class LlmToolCallRecovery {
  LlmToolCallRecovery._();

  /// DSML 的特殊字符：全角竖线 U+FF5C、下八分之一块 U+2581。
  /// 归一化成 ASCII 只做**等长替换**，这样下标能直接映射回原文。
  static const _fullWidthBar = '\uFF5C';
  static const _lowerBlock = '\u2581';

  static String _normalize(String text) =>
      text.replaceAll(_fullWidthBar, '|').replaceAll(_lowerBlock, '_');

  static final _callBegin = RegExp(
    r'<\|tool_call_begin\|>\s*(?:function\s*)?(?:<\|tool_sep\|>\s*)?([A-Za-z0-9_.\-]+)',
  );

  /// 没有 begin 包裹、只剩分隔符的残缺形态（上游丢了起始 token 时会这样）。
  static final _sepOnly = RegExp(
    r'(?:^|\n)\s*(?:function\s*)?<\|tool_sep\|>\s*([A-Za-z0-9_.\-]+)',
  );

  static final _hermes = RegExp(
    r'<tool_call>\s*(\{[\s\S]*?\})\s*</tool_call>',
    multiLine: true,
  );

  static final _markupHint = RegExp(
    r'<\|tool_calls?_begin\|>|<\|tool_sep\|>|<\|tool_call_end\|>|<tool_call>',
  );

  /// 扫描一段正文。没捞到东西时返回原文，[RecoveredToolCalls.calls] 为空。
  static RecoveredToolCalls scan(String content) {
    if (content.isEmpty) {
      return RecoveredToolCalls(content: content, calls: const []);
    }
    final normalized = _normalize(content);
    final sawMarkup = _markupHint.hasMatch(normalized);

    final dsml = _scanDsml(content, normalized);
    if (dsml.calls.isNotEmpty) return dsml;

    final hermes = _scanHermes(content, normalized);
    if (hermes.calls.isNotEmpty) return hermes;

    final bare = _scanBareJson(content);
    if (bare.calls.isNotEmpty) return bare;

    return RecoveredToolCalls(
      content: content,
      calls: const [],
      sawMarkup: sawMarkup,
    );
  }

  static RecoveredToolCalls _scanDsml(String original, String normalized) {
    final matches = _callBegin.allMatches(normalized).toList();
    final useSepOnly = matches.isEmpty;
    final effective =
        useSepOnly ? _sepOnly.allMatches(normalized).toList() : matches;
    if (effective.isEmpty) {
      return RecoveredToolCalls(content: original, calls: const []);
    }

    final calls = <LlmToolCall>[];
    final kept = StringBuffer();
    var cursor = 0;
    for (var i = 0; i < effective.length; i++) {
      final m = effective[i];
      final name = m.group(1)?.trim() ?? '';
      // 这段调用的正文范围：从名字之后，到显式的 end 标记 / 下一个调用 / 结尾。
      final bodyStart = m.end;
      final endMarker = normalized.indexOf('<|tool_call_end|>', bodyStart);
      final nextStart =
          i + 1 < effective.length ? effective[i + 1].start : normalized.length;
      var bodyEnd = normalized.length;
      if (endMarker >= 0 && endMarker < nextStart) {
        bodyEnd = endMarker;
      } else if (nextStart < normalized.length) {
        bodyEnd = nextStart;
      }
      final body = original.substring(bodyStart, bodyEnd);
      if (name.isEmpty) continue;

      // 保留标记之前的正文：模型经常先说一句话再调工具，那句话是有用的。
      if (m.start > cursor) {
        kept.write(original.substring(cursor, m.start));
      }
      // 整个调用块（含可能的 end 标记与外层 calls_end）都算消耗掉。
      cursor = bodyEnd;
      final tail = normalized.indexOf('<|tool_call_end|>', bodyEnd);
      if (tail == bodyEnd) cursor = bodyEnd + '<|tool_call_end|>'.length;

      calls.add(
        LlmToolCall(
          id: 'recovered_${calls.length + 1}',
          name: name,
          arguments: _decodeArgs(body),
        ),
      );
    }
    if (calls.isEmpty) {
      return RecoveredToolCalls(content: original, calls: const []);
    }
    if (cursor < original.length) kept.write(original.substring(cursor));
    return RecoveredToolCalls(
      content: _cleanup(kept.toString()),
      calls: calls,
      sawMarkup: true,
    );
  }

  static RecoveredToolCalls _scanHermes(String original, String normalized) {
    final matches = _hermes.allMatches(normalized).toList();
    if (matches.isEmpty) {
      return RecoveredToolCalls(content: original, calls: const []);
    }
    final calls = <LlmToolCall>[];
    final kept = StringBuffer();
    var cursor = 0;
    for (final m in matches) {
      final payload = original.substring(m.start, m.end);
      final jsonStart = payload.indexOf('{');
      final jsonEnd = payload.lastIndexOf('}');
      if (jsonStart < 0 || jsonEnd <= jsonStart) continue;
      final call = _callFromJson(payload.substring(jsonStart, jsonEnd + 1));
      if (call == null) continue;
      if (m.start > cursor) kept.write(original.substring(cursor, m.start));
      cursor = m.end;
      calls.add(
        LlmToolCall(
          id: 'recovered_${calls.length + 1}',
          name: call.name,
          arguments: call.arguments,
        ),
      );
    }
    if (calls.isEmpty) {
      return RecoveredToolCalls(content: original, calls: const []);
    }
    if (cursor < original.length) kept.write(original.substring(cursor));
    return RecoveredToolCalls(
      content: _cleanup(kept.toString()),
      calls: calls,
      sawMarkup: true,
    );
  }

  /// 整段正文就是一个 `{"name":…,"arguments":{…}}`（有的服务端会这么退化）。
  ///
  /// 严格要求：去掉围栏后必须**整段**都是这个对象，且带 name 和 arguments。
  /// 否则会把模型正常回复里贴的 JSON 误判成工具调用。
  static RecoveredToolCalls _scanBareJson(String original) {
    final trimmed = _stripFence(original).trim();
    if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
      return RecoveredToolCalls(content: original, calls: const []);
    }
    final call = _callFromJson(trimmed);
    if (call == null) {
      return RecoveredToolCalls(content: original, calls: const []);
    }
    return RecoveredToolCalls(
      content: '',
      calls: [
        LlmToolCall(
            id: 'recovered_1', name: call.name, arguments: call.arguments),
      ],
      sawMarkup: true,
    );
  }

  static LlmToolCall? _callFromJson(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final name = (decoded['name'] ?? decoded['tool'] ?? '').toString().trim();
      if (name.isEmpty) return null;
      final rawArgs = decoded['arguments'] ?? decoded['parameters'];
      Map<String, dynamic> args = {};
      if (rawArgs is Map) {
        args = rawArgs.map((k, v) => MapEntry(k.toString(), v));
      } else if (rawArgs is String && rawArgs.trim().isNotEmpty) {
        final inner = jsonDecode(rawArgs);
        if (inner is Map) {
          args = inner.map((k, v) => MapEntry(k.toString(), v));
        }
      } else if (rawArgs == null) {
        // 没有 arguments 字段的不算工具调用，避免把普通 JSON 认成调用。
        return null;
      }
      return LlmToolCall(id: 'recovered', name: name, arguments: args);
    } catch (_) {
      return null;
    }
  }

  /// 从一段调用正文里抠出参数 JSON。
  static Map<String, dynamic> _decodeArgs(String body) {
    final text = _stripFence(body).trim();
    if (text.isEmpty) return const {};
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return {'_raw': text};
    final slice = text.substring(start, end + 1);
    try {
      final decoded = jsonDecode(slice);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {
      // 参数坏了也要把调用交出去：让工具层报"参数不对"，
      // 比静默当成"模型只是说了句话"要好得多。
    }
    return {'_raw': slice};
  }

  /// 去掉 ```json ``` 之类的围栏。
  static String _stripFence(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final firstBreak = trimmed.indexOf('\n');
    if (firstBreak < 0) return trimmed;
    var body = trimmed.substring(firstBreak + 1);
    final closing = body.lastIndexOf('```');
    if (closing >= 0) body = body.substring(0, closing);
    return body.trim();
  }

  /// 剔掉残留的孤立标记，再收掉多余空行。
  static String _cleanup(String text) {
    var out = text;
    for (final marker in const [
      'tool_calls_begin',
      'tool_calls_end',
      'tool_call_begin',
      'tool_call_end',
      'tool_sep',
      'tool_output_begin',
      'tool_output_end',
      'tool_outputs_begin',
      'tool_outputs_end',
    ]) {
      out = out
          .replaceAll(
              '<$_fullWidthBar${marker.replaceAll('_', _lowerBlock)}$_fullWidthBar>',
              '')
          .replaceAll('<|$marker|>', '');
    }
    return out.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }
}
