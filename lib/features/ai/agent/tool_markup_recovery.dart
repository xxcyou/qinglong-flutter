import 'dart:convert';

import '../../../core/llm/llm_client.dart';

/// 工具标记泄漏的 **Dart 侧硬兜底**。
///
/// 无论 JS 插件有没有生效，只要模型把
/// `<｜tool｜ calls> <｜tool｜ invoke name=...>` 这类标签泄漏进正文/思考，
/// 这里都能把它：
/// 1. 解析回结构化 `LlmToolCall`（让 Agent 真的去执行）；
/// 2. 从正文/思考里删除整段标签，用户不再看到乱码。
///
/// 插件仍然是第一道关卡，这里是最后防线。
class ToolMarkupRecovery {
  ToolMarkupRecovery._();

  /// 对 [response] 做一次扫描恢复。没有泄漏时原样返回。
  static LlmResponse apply(LlmResponse response) {
    var calls = List<LlmToolCall>.from(response.toolCalls);
    var content = response.content;
    var reasoning = response.reasoningContent;

    final contentRecovered = _recoverFromText(content);
    if (contentRecovered != null) {
      content = contentRecovered.clean;
      calls = [...calls, ...contentRecovered.calls];
    }

    if (reasoning.isNotEmpty) {
      final reasoningCleaned = _stripTags(reasoning);
      if (reasoningCleaned != reasoning) reasoning = reasoningCleaned;
    }

    if (content == response.content &&
        reasoning == response.reasoningContent &&
        calls.length == response.toolCalls.length) {
      return response;
    }

    return response.copyWith(
      content: content,
      reasoningContent: reasoning,
      toolCalls: calls,
    );
  }

  static _Recovered? _recoverFromText(String text) {
    final spans = <(int, int)>[];
    final calls = <LlmToolCall>[];
    final invokeRe = RegExp(
      r'''<([^>]*?)invoke\s+name=(?:"([^"]+)"|'([^']+)')\s*\/?\s*>([\s\S]*?)<\/([^>]*?)invoke[^>]*>''',
      caseSensitive: false,
    );
    var index = 0;
    while (true) {
      final m = invokeRe.firstMatch(text.substring(index));
      if (m == null) break;
      final start = index + m.start;
      final end = index + m.end;
      final name = m.group(2) ?? m.group(3) ?? '';
      final body = m.group(4) ?? '';
      final args = <String, dynamic>{};
      final paramRe = RegExp(
        r'''<[^>]*?parameter\s+name=(?:"([^"]+)"|'([^']+)')(?:\s+string=(?:"([^"]+)"|'([^']+)'))?\s*>([\s\S]*?)<\/([^>]*?)parameter[^>]*>''',
        caseSensitive: false,
      );
      for (final pm in paramRe.allMatches(body)) {
        final pName = pm.group(1) ?? pm.group(2) ?? '';
        final isString = (pm.group(3) ?? pm.group(4) ?? 'true') != 'false';
        final raw = (pm.group(5) ?? '').trim();
        if (pName.isEmpty) continue;
        if (isString) {
          args[pName] = raw;
        } else {
          try {
            args[pName] = jsonDecode(raw);
          } catch (_) {
            args[pName] = raw;
          }
        }
      }
      calls.add(LlmToolCall(
        id: 'recovered_${calls.length + 1}',
        name: name,
        arguments: args,
      ));
      spans.add((start, end));
      index = end;
    }

    // 把 <...calls> 和 </...calls> 外壳标签也找出来删掉。
    final callsTagRe = RegExp(r'<[^>]*?calls[^>]*>', caseSensitive: false);
    for (final m in callsTagRe.allMatches(text)) {
      spans.add((m.start, m.end));
    }

    if (spans.isEmpty) return null;

    final clean = _removeSpans(text, spans);
    return _Recovered(clean, calls);
  }

  static String _stripTags(String text) {
    var out = text;
    final invokeRe = RegExp(
      r'''<([^>]*?)invoke\s+name=(?:"([^"]+)"|'([^']+)')\s*\/?\s*>([\s\S]*?)<\/([^>]*?)invoke[^>]*>''',
      caseSensitive: false,
    );
    out = out.replaceAll(invokeRe, '');
    out =
        out.replaceAll(RegExp(r'<[^>]*?calls[^>]*>', caseSensitive: false), '');
    out = out.replaceAll(
        RegExp(r'<[^>]*?parameter[^>]*>[\s\S]*?</[^>]*?parameter[^>]*>',
            caseSensitive: false),
        '');
    return out;
  }

  static String _removeSpans(String text, List<(int, int)> spans) {
    final sorted = [...spans]..sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final s in sorted) {
      if (merged.isNotEmpty && s.$1 <= merged.last.$2) {
        if (s.$2 > merged.last.$2) {
          final last = merged.removeLast();
          merged.add((last.$1, s.$2));
        }
      } else {
        merged.add(s);
      }
    }
    final parts = <String>[];
    var prev = 0;
    for (final span in merged) {
      parts.add(text.substring(prev, span.$1));
      prev = span.$2;
    }
    parts.add(text.substring(prev));
    return parts.join();
  }
}

class _Recovered {
  const _Recovered(this.clean, this.calls);

  final String clean;
  final List<LlmToolCall> calls;
}
