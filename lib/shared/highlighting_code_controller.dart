import 'package:code_text_field/code_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:highlight/highlight.dart' as full;
import 'package:highlight/highlight_core.dart';

/// 使用本地 `Highlight` 实例 + Monokai 主题直接高亮。
///
/// highlight 自带解析器遇到个别 JS 非法词法时会直接降级成纯文本
/// （例如 volc_ark_lite_quota.js、sub2api_balance_monitor.js），
/// 这里在检测到纯文本结果时再走一层轻量正则兜底，保证所有 JS 至少
/// 有注释/字符串/关键字/数字的颜色，而不是整片白色。
class HighlightingCodeController extends CodeController {
  HighlightingCodeController({
    super.language,
    super.text,
    this.languageName,
  });

  /// 当前选中的文本；没有有效选区时返回空字符串。
  String get selectedText {
    final sel = selection;
    if (!sel.isValid || sel.start < 0 || sel.start >= text.length) {
      return '';
    }
    final end = sel.end > text.length ? text.length : sel.end;
    return text.substring(sel.start, end);
  }

  /// 统计关键字出现次数（普通子串匹配，不跨重叠）。
  int countMatches(String query, {bool caseSensitive = false}) {
    if (query.isEmpty) return 0;
    final haystack = caseSensitive ? text : text.toLowerCase();
    final needle = caseSensitive ? query : query.toLowerCase();
    var count = 0;
    var index = haystack.indexOf(needle);
    while (index != -1) {
      count++;
      index = haystack.indexOf(needle, index + needle.length);
    }
    return count;
  }

  /// 跳转到下一个匹配并选中该匹配文本。
  ///
  /// [reverse] 为 true 时向上一个匹配。默认允许循环查找。
  TextSelection? selectNextMatch(
    String query, {
    bool caseSensitive = false,
    bool reverse = false,
  }) {
    if (query.isEmpty || text.isEmpty) return null;
    final haystack = caseSensitive ? text : text.toLowerCase();
    final needle = caseSensitive ? query : query.toLowerCase();
    final sel = selection;

    int searchFrom;
    if (reverse) {
      final start = sel.isValid ? sel.start : text.length;
      searchFrom = start > text.length ? text.length : start;
    } else {
      final start = sel.isValid ? sel.end : 0;
      searchFrom = start < 0 ? 0 : (start > text.length ? text.length : start);
    }

    int index;
    if (reverse) {
      index = haystack.lastIndexOf(needle, searchFrom - 1);
      if (index < 0) {
        index = haystack.lastIndexOf(needle);
      }
    } else {
      index = haystack.indexOf(needle, searchFrom);
      if (index < 0) {
        index = haystack.indexOf(needle);
      }
    }
    if (index < 0) return null;

    final match = TextSelection(
      baseOffset: index,
      extentOffset: index + needle.length,
    );
    selection = match;
    return match;
  }

  /// 可直接传给 `full.highlight.parse` 的语言名，例如 `javascript`。
  final String? languageName;

  /// 独立 Highlight 实例，注册与解析使用同一个实例，避免全局单例不一致。
  static final full.Highlight _localHighlight = full.Highlight();

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    bool? withComposing,
  }) {
    final name = languageName;
    final languageMode = language;
    if (name == null || name.isEmpty || languageMode == null) {
      return TextSpan(text: text, style: style);
    }

    final langId = 'ql_full_$name';
    _localHighlight.registerLanguage(langId, languageMode);
    final result = _localHighlight.parse(text, language: langId);

    TextSpan buildNode(Node node) {
      final nodeStyle = monokaiSublimeTheme[node.className];
      final value = node.value;
      final nodeChildren = node.children;

      if (value != null) {
        return TextSpan(text: value, style: nodeStyle);
      }

      final children = <TextSpan>[];
      for (final child in nodeChildren ?? const <Node>[]) {
        children.add(buildNode(child));
      }
      return TextSpan(style: nodeStyle, children: children);
    }

    final children = <TextSpan>[
      for (final node in result.nodes ?? const <Node>[]) buildNode(node),
    ];

    int countColored(TextSpan span) {
      var n = span.style?.color != null ? 1 : 0;
      for (final child in span.children ?? const <InlineSpan>[]) {
        if (child is TextSpan) n += countColored(child);
      }
      return n;
    }

    final coloredCount = countColored(TextSpan(children: children));

    if (coloredCount == 0 && text.trim().isNotEmpty) {
      return TextSpan(style: style, children: _buildFallback(name));
    }

    return TextSpan(style: style, children: children);
  }

  /// highlight 解析失败时使用的轻量正则高亮。
  List<TextSpan> _buildFallback(String name) {
    final code = text;
    final children = <TextSpan>[];
    final RegExp pattern = _patternFor(name);
    if (pattern == RegExp('')) return [TextSpan(text: code)];

    var last = 0;
    for (final match in pattern.allMatches(code)) {
      if (match.start > last) {
        children.add(TextSpan(text: code.substring(last, match.start)));
      }
      final token = match[0]!;
      if (token.startsWith('//') ||
          token.startsWith('/*') ||
          token.startsWith('#')) {
        children.add(TextSpan(
          text: token,
          style: monokaiSublimeTheme['comment'],
        ));
      } else if (token.startsWith("'") ||
          token.startsWith('"') ||
          token.startsWith('`')) {
        children.add(TextSpan(
          text: token,
          style: monokaiSublimeTheme['string'],
        ));
      } else if (RegExp(r'^\d').hasMatch(token)) {
        children.add(TextSpan(
          text: token,
          style: monokaiSublimeTheme['number'],
        ));
      } else {
        children.add(TextSpan(
          text: token,
          style: monokaiSublimeTheme['keyword'],
        ));
      }
      last = match.end;
    }
    if (last < code.length) {
      children.add(TextSpan(text: code.substring(last)));
    }
    return children;
  }

  RegExp _patternFor(String name) {
    switch (name) {
      case 'javascript':
      case 'typescript':
        return RegExp(
          r'''(//[^\n]*|/\*[\s\S]*?\*/|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`|\b(?:const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|class|extends|super|this|async|await|import|export|from|default|try|catch|finally|throw|typeof|instanceof|delete|void|in|of|yield|static|get|set|null|undefined|true|false)\b|\b\d+(?:\.\d+)?\b)''',
        );
      case 'python':
      case 'bash':
        return RegExp(
          r'''(#[^\n]*|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|\b(?:def|class|return|if|elif|else|for|while|import|from|as|try|except|finally|with|lambda|pass|break|continue|global|nonlocal|and|or|not|in|is|None|True|False|async|await|yield|raise|then|fi|do|done|case|esac|function|local|export)\b|\b\d+(?:\.\d+)?\b)''',
        );
      case 'yaml':
      case 'json':
        return RegExp(
          r'''('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|\b(?:true|false|null|yes|no|on|off)\b|\b\d+(?:\.\d+)?\b|#[^\n]*)''',
        );
      default:
        return RegExp('');
    }
  }
}
