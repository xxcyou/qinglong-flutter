import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:highlight/highlight.dart' as full;
import 'package:highlight/highlight_core.dart';

import 'code_language.dart';

/// 使用本地 `Highlight` 实例 + Monokai 主题直接高亮。
///
/// highlight 自带解析器遇到个别 JS 非法词法时会直接降级成纯文本
/// （例如 volc_ark_lite_quota.js、sub2api_balance_monitor.js），
/// 这里在检测到纯文本结果时再走一层轻量正则兜底，保证所有 JS 至少
/// 有注释/字符串/关键字/数字的颜色，而不是整片白色。
class HighlightingCodeController extends CodeController {
  /// HTML 标签用偏橙/红的可见色，不用 monokai 自带的“tag 白”，
  /// 否则 `<style>` `<script>` 在白底黑字里像没上色。
  static const Color _htmlTagColor = Color(0xFFFF7B72);
  static const Color _htmlAttrColor = Color(0xFF79C0FF);

  /// VS Code 深色主题风格：关键字蓝、字符串橙、变量/属性浅蓝、
  /// 函数黄、类型青、注释绿，整体比 monokai 更接近现代编辑器。
  static const Color _keywordColor = Color(0xFF569CD6);
  static const Color _stringColor = Color(0xFFCE9178);
  static const Color _numberColor = Color(0xFFB5CEA8);
  static const Color _commentColor = Color(0xFF6A9955);
  static const Color _functionColor = Color(0xFFDCDCAA);
  static const Color _variableColor = Color(0xFF9CDCFE);
  static const Color _propertyColor = Color(0xFF9CDCFE);
  static const Color _typeColor = Color(0xFF4EC9B0);
  static const Color _builtInColor = Color(0xFF4EC9B0);
  static const Color _operatorColor = Color(0xFFD4D4D4);
  static const Color _punctuationColor = Color(0xFF808080);

  static const Map<String, TextStyle> _vsTheme = {
    'comment': TextStyle(color: _commentColor, fontStyle: FontStyle.italic),
    'string': TextStyle(color: _stringColor),
    'number': TextStyle(color: _numberColor),
    'keyword': TextStyle(color: _keywordColor),
    'literal': TextStyle(color: _keywordColor),
    'built_in': TextStyle(color: _builtInColor),
    'title': TextStyle(color: _functionColor, fontWeight: FontWeight.w600),
    'function': TextStyle(color: _functionColor),
    'params': TextStyle(color: _variableColor),
    'variable': TextStyle(color: _variableColor),
    'attribute': TextStyle(color: _htmlAttrColor),
    'type': TextStyle(color: _typeColor),
    'meta': TextStyle(color: _keywordColor),
    'tag': TextStyle(color: _htmlTagColor),
    'attr': TextStyle(color: _htmlAttrColor),
    'operator': TextStyle(color: _operatorColor),
    'punctuation': TextStyle(color: _punctuationColor),
    'template': TextStyle(color: _stringColor),
    'template-string': TextStyle(color: _stringColor),
  };

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

    // HTML 不是整块用 xml 高亮：<script>/<style> 内部要分别交给
    // JS/CSS 高亮，标签和属性仍用 xml 高亮。
    if (name == 'html') {
      return _buildHtmlSpan(text, style);
    }

    return _buildLanguageSpan(text, name, languageMode, style);
  }

  /// 用指定语言高亮一段代码；如果解析结果全无色就落到轻量正则兜底。
  TextSpan _buildLanguageSpan(
    String code,
    String name,
    Mode languageMode,
    TextStyle? style,
  ) {
    final langId = 'ql_full_$name';
    _localHighlight.registerLanguage(langId, languageMode);
    final result = _localHighlight.parse(code, language: langId);
    final children = [
      for (final node in result.nodes ?? const <Node>[]) _buildNode(node),
    ];

    if (_countColored(TextSpan(children: children)) == 0 &&
        code.trim().isNotEmpty) {
      return TextSpan(
        style: style,
        children: _enrichSpans(_buildFallback(name)),
      );
    }

    return TextSpan(style: style, children: _enrichSpans(children));
  }

  /// 对高亮结果里“没有指定样式的纯文本叶子”再做一层 VS Code 式处理：
  /// 普通变量/对象属性/函数调用都补上颜色，让代码不是大片白字。
  List<InlineSpan> _enrichSpans(List<InlineSpan> spans) {
    return [
      for (final span in spans)
        if (span is TextSpan) _enrich(span) else span,
    ];
  }

  TextSpan _enrich(TextSpan span) {
    if (span.text != null) {
      if (span.style == null) {
        final enriched = _splitPlainText(span.text!);
        if (enriched.isNotEmpty) {
          return TextSpan(children: enriched);
        }
      }
      return span;
    }
    final children = span.children;
    if (children == null || children.isEmpty) return span;
    return TextSpan(style: span.style, children: _enrichSpans(children));
  }

  /// 把纯文本叶子按标识符/数字/空白/符号拆开并上色。
  ///
  /// 函数调用 `foo(` -> 黄色；对象键 `foo:` / `.foo` -> 浅蓝；
  /// 其余普通标识符 -> 浅蓝；数字/符号也分别上色。
  static final RegExp _plainTokenPattern = RegExp(
    r'''([A-Za-z_$][A-Za-z0-9_$]*)|(\d+(?:\.\d+)?)|(\s+)|([^\sA-Za-z0-9_$]+)''',
  );

  List<TextSpan> _splitPlainText(String text) {
    final result = <TextSpan>[];
    var last = 0;
    for (final match in _plainTokenPattern.allMatches(text)) {
      if (match.start > last) {
        result.add(TextSpan(text: text.substring(last, match.start)));
      }
      final token = match[0]!;
      if (match.group(1) != null) {
        final after = _nextNonSpace(text, match.end);
        final before = _prevNonSpace(text, match.start);
        final isFunction = after == '(';
        final isProperty = after == ':' || before == '.';
        result.add(TextSpan(
          text: token,
          style: TextStyle(
            color: isFunction
                ? _functionColor
                : isProperty
                    ? _propertyColor
                    : _variableColor,
          ),
        ));
      } else if (match.group(2) != null) {
        result.add(TextSpan(text: token, style: _vsTheme['number']));
      } else if (match.group(3) != null) {
        result.add(TextSpan(text: token));
      } else {
        result.add(TextSpan(text: token, style: _vsTheme['punctuation']));
      }
      last = match.end;
    }
    return result;
  }

  String? _nextNonSpace(String text, int index) {
    for (var i = index; i < text.length; i++) {
      if (!RegExp(r'\s').hasMatch(text[i])) return text[i];
    }
    return null;
  }

  String? _prevNonSpace(String text, int index) {
    for (var i = index - 1; i >= 0; i--) {
      if (!RegExp(r'\s').hasMatch(text[i])) return text[i];
    }
    return null;
  }

  TextSpan _buildNode(Node node) {
    final nodeStyle = _styleForNode(node.className);
    final value = node.value;
    final nodeChildren = node.children;

    if (value != null) {
      return TextSpan(text: value, style: nodeStyle);
    }

    final children = <TextSpan>[];
    for (final child in nodeChildren ?? const <Node>[]) {
      children.add(_buildNode(child));
    }
    return TextSpan(style: nodeStyle, children: children);
  }

  TextStyle? _styleForNode(String? className) {
    if (className == null) return null;
    return _vsTheme[className] ?? monokaiSublimeTheme[className];
  }

  /// HTML 专用节点构建：把标签/属性名从“白色 tag”换成肉眼可见的颜色。
  TextSpan _buildHtmlNode(Node node) {
    TextStyle? nodeStyle = _styleForNode(node.className);
    if (node.className == 'tag' || node.className == 'name') {
      nodeStyle = const TextStyle(color: _htmlTagColor);
    } else if (node.className == 'attr' ||
        node.className == 'attribute' ||
        node.className == 'selector-attr') {
      nodeStyle = const TextStyle(color: _htmlAttrColor);
    }
    final value = node.value;
    final nodeChildren = node.children;

    if (value != null) {
      return TextSpan(text: value, style: nodeStyle);
    }

    final children = <TextSpan>[];
    for (final child in nodeChildren ?? const <Node>[]) {
      children.add(_buildHtmlNode(child));
    }
    return TextSpan(style: nodeStyle, children: children);
  }

  int _countColored(TextSpan span) {
    var n = span.style?.color != null ? 1 : 0;
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan) n += _countColored(child);
    }
    return n;
  }

  /// HTML 混合高亮：拆出 <script> 和 <style> 的内嵌代码块。
  TextSpan _buildHtmlSpan(String code, TextStyle? style) {
    final splitPattern = RegExp(
      r'''<script\b[^>]*>([\s\S]*?)</script\s*>|<style\b[^>]*>([\s\S]*?)</style\s*>''',
      caseSensitive: false,
    );
    final children = <TextSpan>[];
    var last = 0;

    for (final match in splitPattern.allMatches(code)) {
      if (match.start > last) {
        children.add(_parseHtmlSegment(code.substring(last, match.start)));
      }
      final full = match[0]!;
      final isScript = match.group(1) != null;
      final inner = isScript ? match.group(1)! : match.group(2)!;
      final openEnd = full.indexOf(inner);
      final closeStart = openEnd + inner.length;

      // 开始标签（含 <script src=...>）按 HTML 高亮。
      children.add(_parseHtmlSegment(full.substring(0, openEnd)));
      // 内嵌代码按 JS/CSS 高亮。
      final innerMode = modeForLanguage(isScript ? 'javascript' : 'css');
      if (innerMode != null) {
        children.add(_buildLanguageSpan(
          inner,
          isScript ? 'javascript' : 'css',
          innerMode,
          style,
        ));
      } else {
        children.add(TextSpan(text: inner, style: style));
      }
      // 结束标签按 HTML 高亮。
      children.add(_parseHtmlSegment(full.substring(closeStart)));
      last = match.end;
    }

    if (last < code.length) {
      children.add(_parseHtmlSegment(code.substring(last)));
    }
    return TextSpan(style: style, children: children);
  }

  /// HTML 片段：优先用 xml 模式解析标签/属性/注释。
  ///
  /// highlight 的 xml 解析器遇到大型/复杂 HTML（尤其内嵌 CSS/JS 里大量
  /// `{}`）时会整段退化成纯文本，所以解析结果一个颜色都没有时改用
  /// 轻量 HTML 正则高亮兜底，保证标签至少有色。
  TextSpan _parseHtmlSegment(String segment) {
    final xmlMode = modeForLanguage('xml');
    if (xmlMode == null || segment.trim().isEmpty) {
      return TextSpan(text: segment);
    }
    const id = 'ql_html_xml';
    _localHighlight.registerLanguage(id, xmlMode);
    final result = _localHighlight.parse(segment, language: id);
    final children = [
      for (final node in result.nodes ?? const <Node>[]) _buildHtmlNode(node),
    ];
    if (_countColored(TextSpan(children: children)) > 0) {
      return TextSpan(children: children);
    }
    return TextSpan(children: _buildHtmlFallback(segment));
  }

  /// 轻量 HTML 正则高亮：注释、DOCTYPE、标签、引号字符串。
  List<TextSpan> _buildHtmlFallback(String segment) {
    final pattern = RegExp(
      r'''(<!--[\s\S]*?-->|<!DOCTYPE[^>]*>|</?[a-zA-Z][^>]*>|"[^"]*"|'[^']*')''',
      caseSensitive: false,
    );
    final children = <TextSpan>[];
    var last = 0;
    for (final match in pattern.allMatches(segment)) {
      if (match.start > last) {
        children.add(TextSpan(text: segment.substring(last, match.start)));
      }
      final token = match[0]!;
      if (token.startsWith('<!--')) {
        children.add(TextSpan(
          text: token,
          style: _styleForNode('comment'),
        ));
      } else if (RegExp(r'^<!DOCTYPE', caseSensitive: false).hasMatch(token)) {
        children.add(TextSpan(
          text: token,
          style: _styleForNode('meta'),
        ));
      } else if (token.startsWith('<')) {
        children.add(TextSpan(
          text: token,
          style: const TextStyle(color: _htmlTagColor),
        ));
      } else {
        children.add(TextSpan(
          text: token,
          style: _styleForNode('string'),
        ));
      }
      last = match.end;
    }
    if (last < segment.length) {
      children.add(TextSpan(text: segment.substring(last)));
    }
    return children;
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
          style: _styleForNode('comment'),
        ));
      } else if (token.startsWith("'") ||
          token.startsWith('"') ||
          token.startsWith('`')) {
        children.add(TextSpan(
          text: token,
          style: _styleForNode('string'),
        ));
      } else if (RegExp(r'^\d').hasMatch(token)) {
        children.add(TextSpan(
          text: token,
          style: _styleForNode('number'),
        ));
      } else {
        children.add(TextSpan(
          text: token,
          style: _styleForNode('keyword'),
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
