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
    var broken = false;
    if (contentRecovered != null) {
      content = contentRecovered.clean;
      calls = [...calls, ...contentRecovered.calls];
    } else if (_hasIncompleteLeak(content)) {
      // 只看见开标签、没有闭标签：通常是模型把大段参数写太长，输出被截断。
      // 这时没法恢复完整调用，至少把半截标签从展示里删掉，并标记 broken，
      // 让上层要求模型用标准 function call 重发。
      content = _stripIncompleteLeak(content);
      broken = true;
    }

    if (reasoning.isNotEmpty && _looksLikeLeak(reasoning)) {
      final reasoningCleaned = _stripTags(reasoning);
      if (reasoningCleaned != reasoning) reasoning = reasoningCleaned;
    } else if (reasoning.isNotEmpty && _hasIncompleteLeak(reasoning)) {
      reasoning = _stripIncompleteLeak(reasoning);
      broken = true;
    }

    if (content == response.content &&
        reasoning == response.reasoningContent &&
        calls.length == response.toolCalls.length &&
        !broken) {
      return response;
    }

    return response.copyWith(
      content: content,
      reasoningContent: reasoning,
      toolCalls: calls,
      brokenToolMarkup: broken,
    );
  }

  /// 是否像“工具调用标记泄漏”：必须有 calls 外壳 + 至少一个 invoke，
  /// 避免把用户/AI 正常讨论标签的文本也误删成工具调用。
  static bool _looksLikeLeak(String text) {
    final hasCallsWrapper = RegExp(
      r'<[^>]*?calls[^>]*>',
      caseSensitive: false,
    ).hasMatch(text);
    final hasInvoke = RegExp(
      r'<[^>]*?invoke\s+name=',
      caseSensitive: false,
    ).hasMatch(text);
    return hasCallsWrapper && hasInvoke;
  }

  /// 只看到 `<...invoke name=...>` 开标签、没看到闭标签，而且后面跟着参数标签：
  /// 几乎可以断定是长参数写了一半被截断。删掉半截残块，避免用户看到一堆乱码。
  static bool _hasIncompleteLeak(String text) {
    final open = RegExp(
      r'<[^>]*?invoke\s+name=',
      caseSensitive: false,
    ).firstMatch(text);
    if (open == null) return false;
    final close = RegExp(
      r'</[^>]*?invoke[^>]*>',
      caseSensitive: false,
    ).firstMatch(text.substring(open.end));
    if (close != null) return false;
    return RegExp(
      r'<[^>]*?parameter\s+name=',
      caseSensitive: false,
    ).hasMatch(text.substring(open.end));
  }

  static String _stripIncompleteLeak(String text) {
    final open = RegExp(
      r'<[^>]*?invoke\s+name=',
      caseSensitive: false,
    ).firstMatch(text);
    if (open == null) return text;
    final close = RegExp(
      r'</[^>]*?invoke[^>]*>',
      caseSensitive: false,
    ).firstMatch(text.substring(open.end));
    if (close != null) return text;
    return text.substring(0, open.start);
  }

  static _Recovered? _recoverFromText(String text) {
    if (!_looksLikeLeak(text)) return null;
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
