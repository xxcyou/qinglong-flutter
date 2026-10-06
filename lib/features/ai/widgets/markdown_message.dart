import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../shared/image_preview_overlay.dart';
import '../../../shared/mono_text.dart';
import '../models/ai_message.dart';

/// AI 回复的 Markdown 渲染：表格、代码块、列表都能正常显示，
/// 代码块可长按复制。用户消息仍用纯文本，避免把用户输入当标记解析。
class MarkdownMessage extends StatelessWidget {
  const MarkdownMessage({
    super.key,
    required this.text,
    this.textColor,
    this.selectable = true,
  });

  final String text;
  final Color? textColor;

  /// 在 GitHub Flavored Markdown 基础上追加自定义行内语法：
  /// 默认语法先解析（代码块/行内代码优先），再处理 ++/==/{c:}。
  static final md.ExtensionSet enhancedExtensionSet = md.ExtensionSet(
    md.ExtensionSet.gitHubFlavored.blockSyntaxes,
    [
      ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
      _UnderlineSyntax(),
      _GlowSyntax(),
      _ColorSyntax(),
      _HighlightSyntax(),
    ],
  );

  /// 是否支持长按选取文本。默认 true；聊天气泡取消默认长按选取，
  /// 只有用户从长按菜单点“选取文字”后才临时打开。
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: textColor,
          height: 1.45,
        );
    final codeBlockBuilder = _CodeBlockBuilder();
    return MarkdownBody(
      data: text,
      selectable: selectable,
      extensionSet: enhancedExtensionSet,
      blockSyntaxes: [_FunctionPlotSyntax()],
      builders: {
        'u': _UnderlineBuilder(),
        'mark': _GlowBuilder(),
        'span': _ColorSpanBuilder(),
        'highlight': _HighlightBuilder(),
        'pre': codeBlockBuilder,
        'code': codeBlockBuilder,
        'functionPlot': _FunctionPlotBuilder(),
      },
      imageBuilder: (uri, title, alt) => _MarkdownImage(uri: uri, alt: alt),
      onTapLink: (_, href, __) {
        if (href != null) Clipboard.setData(ClipboardData(text: href));
      },
      styleSheet: MarkdownStyleSheet(
        p: base,
        listBullet: base,
        a: base?.copyWith(
          color: scheme.primary,
          decoration: TextDecoration.underline,
        ),
        h1: base?.copyWith(fontSize: 19, fontWeight: FontWeight.bold),
        h2: base?.copyWith(fontSize: 17, fontWeight: FontWeight.bold),
        h3: base?.copyWith(fontSize: 15.5, fontWeight: FontWeight.bold),
        strong: base?.copyWith(fontWeight: FontWeight.bold),
        em: base?.copyWith(fontStyle: FontStyle.italic),
        code: base?.copyWith(
          fontFamily: kMonoFamily,
          fontFamilyFallback: kMonoFallback,
          fontSize: 12.5,
          backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
        ),
        codeblockDecoration: BoxDecoration(
          // 代码块也透一点，聊天流里才不是一块块黑砖。
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        codeblockPadding: const EdgeInsets.all(10),
        blockquoteDecoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(color: scheme.primary, width: 3),
            right: BorderSide(color: Colors.transparent, width: 0),
            top: BorderSide(color: Colors.transparent, width: 0),
            bottom: BorderSide(color: Colors.transparent, width: 0),
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.07),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        tableBorder: TableBorder.all(color: scheme.outlineVariant),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 5,
        ),
        tableHead: base?.copyWith(fontWeight: FontWeight.bold),
        tableBody: base?.copyWith(fontSize: 12.5),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
      ),
    );
  }
}

/// `++文字++` → 下划线。
class _UnderlineSyntax extends md.InlineSyntax {
  _UnderlineSyntax() : super(r'\+\+([^+\n]+?)\+\+');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('u', match.group(1) ?? ''));
    return true;
  }
}

/// `==文字==` → 发光（霓虹强调）。
class _GlowSyntax extends md.InlineSyntax {
  _GlowSyntax() : super(r'==([^=\n]+?)==');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('mark', match.group(1) ?? ''));
    return true;
  }
}

/// `{c:red}文字{/c}` → 指定颜色，支持红/绿/蓝等名字或 #RRGGBB。
class _ColorSyntax extends md.InlineSyntax {
  _ColorSyntax() : super(r'\{c:([^}\n]+)\}([^{]+?)\{/c\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element.text('span', match.group(2) ?? '')
      ..attributes['color'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

/// `{bg:yellow}文字{/bg}` → 背景高亮（荧光笔）。
class _HighlightSyntax extends md.InlineSyntax {
    _HighlightSyntax() : super(r'\{bg:([^}\n]+)\}([^{]+?)\{/bg\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element.text('highlight', match.group(2) ?? '')
      ..attributes['bg'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

class _UnderlineBuilder extends MarkdownElementBuilder {
  _UnderlineBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text = element.textContent;
    if (text.isEmpty) return null;
    return Text.rich(
      TextSpan(
        text: text,
        style: (parentStyle ?? const TextStyle()).copyWith(
          decoration: TextDecoration.underline,
          decorationColor: parentStyle?.color,
        ),
      ),
    );
  }
}

class _GlowBuilder extends MarkdownElementBuilder {
  _GlowBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text = element.textContent;
    if (text.isEmpty) return null;
    const glow = Color(0xFFFFD54F);
    return Text.rich(
      TextSpan(
        text: text,
        style: (parentStyle ?? const TextStyle()).copyWith(
          color: glow,
          shadows: const [
            Shadow(color: Color(0x66FFD54F), blurRadius: 6),
            Shadow(color: Color(0x44FFB300), blurRadius: 14),
          ],
        ),
      ),
    );
  }
}

class _ColorSpanBuilder extends MarkdownElementBuilder {
  _ColorSpanBuilder();

  static const Map<String, Color> _named = {
    'red': Color(0xFFFF5252),
    'green': Color(0xFF69F0AE),
    'blue': Color(0xFF82B1FF),
    'yellow': Color(0xFFFFD740),
    'orange': Color(0xFFFFAB40),
    'purple': Color(0xFFB388FF),
    'pink': Color(0xFFFF80AB),
    'cyan': Color(0xFF80DEEA),
    'teal': Color(0xFF80CBC4),
    'gray': Color(0xFFB0BEC5),
    'grey': Color(0xFFB0BEC5),
    'brown': Color(0xFFBCAAA4),
    'indigo': Color(0xFF9FA8DA),
    'white': Color(0xFFFFFFFF),
    'black': Color(0xFF000000),
  };

  Color? _parse(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return null;
    final lower = v.toLowerCase();
    if (_named.containsKey(lower)) return _named[lower];
    if (v.startsWith('#')) v = v.substring(1);
    if (v.length == 3) {
      final r = int.parse(v.substring(0, 1), radix: 16);
      final g = int.parse(v.substring(1, 2), radix: 16);
      final b = int.parse(v.substring(2, 3), radix: 16);
      return Color(0xFF000000 | (r << 20) | (g << 12) | (b << 4));
    }
    if ((v.length == 6 || v.length == 8) &&
        int.tryParse(v, radix: 16) != null) {
      final value = int.parse(v, radix: 16);
      if (v.length == 6) return Color(0xFF000000 | value);
      return Color(value);
    }
    return null;
  }

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text = element.textContent;
    final color = _parse(element.attributes['color'] ?? '');
    if (text.isEmpty) return null;
    return Text.rich(
      TextSpan(
        text: text,
        style: (parentStyle ?? const TextStyle()).copyWith(color: color),
      ),
    );
  }
}

class _HighlightBuilder extends MarkdownElementBuilder {
  _HighlightBuilder();

  static Color? _parseColor(String raw) => _ColorSpanBuilder()._parse(raw);

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text = element.textContent;
    if (text.isEmpty) return null;
    final bg = _parseColor(element.attributes['bg'] ?? '');
    final base = parentStyle ?? const TextStyle();
    return Text.rich(
      TextSpan(
        text: text,
        style: base.copyWith(
          backgroundColor: bg,
          color: bg != null ? _readableOn(bg) : base.color,
        ),
      ),
    );
  }

  Color _readableOn(Color bg) {
    // 简单的亮度判断：深底用浅字，浅底用深字。
    final luminance = 0.299 * bg.red + 0.587 * bg.green + 0.114 * bg.blue;
    return luminance > 150 ? const Color(0xFF1A1A1A) : Colors.white;
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  bool _inPre = false;
  String? _pendingLanguage;

  @override
  bool isBlockElement() => false;

  @override
  void visitElementBefore(md.Element element) {
    if (element.tag == 'pre') {
      _inPre = true;
      _pendingLanguage = null;
    } else if (element.tag == 'code' && _inPre) {
      final cls = element.attributes['class'] ?? '';
      String? language;
      if (cls.startsWith('language-') && cls.length > 'language-'.length) {
        language = cls.substring('language-'.length);
      }
      _pendingLanguage = language;
    }
  }

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) {
    if (!_inPre) return null;
    final language = _pendingLanguage;
    _inPre = false;
    _pendingLanguage = null;
    return _CodeBlock(code: text.text, language: language);
  }

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // 代码块在 visitText 里整体渲染，这里不再追加。
    return null;
  }
}

class _CodeBlock extends StatefulWidget {
  const _CodeBlock({required this.code, this.language});

  final String code;
  final String? language;

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;
  Object? _json;
  String? _formatKind;
  bool _formatted = false;
  bool _treeMode = false;

  @override
  void initState() {
    super.initState();
    final trimmed = widget.code.trim();
    try {
      _json = jsonDecode(trimmed);
      _formatKind = 'json';
      _formatted = true;
      return;
    } catch (_) {}
    final lang = (widget.language ?? '').toLowerCase();
    if (lang == 'html' || lang == 'xml' || lang == 'svg' ||
        (trimmed.startsWith('<') && trimmed.contains('>'))) {
      _formatKind = 'html';
    } else if (lang == 'css' ||
        (lang.isEmpty && trimmed.contains('{') && trimmed.contains(';'))) {
      _formatKind = 'css';
    }
  }

  String get _displayCode {
    if (!_formatted) return widget.code;
    switch (_formatKind) {
      case 'json':
        if (_json != null) {
          return const JsonEncoder.withIndent('  ').convert(_json);
        }
        break;
      case 'html':
        return _formatHtml(widget.code);
      case 'css':
        return _formatCss(widget.code);
    }
    return widget.code;
  }

  Future<void> _copy() async {
    final text = _displayCode.isEmpty ? widget.code : _displayCode;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (mounted) setState(() => _copied = false);
  }

  void _toggleFormat() {
    if (_formatKind == null) return;
    setState(() {
      _formatted = !_formatted;
      if (_formatKind == 'json') _treeMode = false;
    });
  }

  void _toggleTree() {
    if (_json == null) return;
    setState(() => _treeMode = !_treeMode);
  }

  String _formatHtml(String source) {
    final buffer = StringBuffer();
    var indent = 0;
    final tagReg = RegExp(r'(<[^>]+>)|([^<]+)');
    const voidTags = {
      'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
      'link', 'meta', 'param', 'source', 'track', 'wbr',
    };
    for (final m in tagReg.allMatches(source)) {
      final tag = m.group(1);
      if (tag != null) {
        final isClosing = tag.startsWith('</');
        final isSelfClose = tag.endsWith('/>');
        final tagName = RegExp(r'<[/]?([a-zA-Z0-9-]+)').firstMatch(tag)?.group(1) ?? '';
        if (isClosing) {
          indent = indent > 0 ? indent - 1 : 0;
          buffer.writeln('${'  ' * indent}$tag');
        } else if (isSelfClose || voidTags.contains(tagName.toLowerCase())) {
          buffer.writeln('${'  ' * indent}$tag');
        } else {
          buffer.writeln('${'  ' * indent}$tag');
          indent++;
        }
      } else {
        final text = (m.group(2) ?? '').trim();
        if (text.isNotEmpty) buffer.writeln('${'  ' * indent}$text');
      }
    }
    var result = buffer.toString().trimRight();
    return result.isEmpty ? source : result;
  }

  String _formatCss(String source) {
    final buffer = StringBuffer();
    var indent = 0;
    for (var i = 0; i < source.length; i++) {
      final c = source[i];
      if (c == '{') {
        final current = buffer.toString().trimRight();
        buffer.clear();
        buffer
          ..write('$current {\n')
          ..write('  ' * indent);
        indent++;
        buffer.write('  ' * indent);
      } else if (c == '}') {
        buffer
          ..write('\n')
          ..write('  ' * (indent > 0 ? indent - 1 : 0))
          ..write('}');
        indent = indent > 0 ? indent - 1 : 0;
      } else if (c == ';') {
        buffer
          ..write(';\n')
          ..write('  ' * indent);
      } else {
        buffer.write(c);
      }
    }
    var result = buffer.toString().trimRight();
    return result.isEmpty ? source : result;
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
  }) {
    final color = active
        ? const Color(0xFF8AB4FF)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(fontSize: 11, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final language = widget.language;
    final label = language == null
        ? 'CODE'
        : language.toUpperCase();
    final theme = Map<String, TextStyle>.from(atomOneDarkTheme);
    final rootStyle = theme['root'];
    if (rootStyle != null) {
      theme['root'] = rootStyle.copyWith(
        color: const Color(0xFFE6EDF7),
        backgroundColor: const Color(0xFF121826),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: const BoxDecoration(
            color: Color(0xFF1D2635),
            borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
          ),
          child: Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF8AB4FF),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              if (_formatKind != null) ...[
                _actionButton(
                  icon: _formatted ? Icons.undo : Icons.format_align_left,
                  label: _formatted ? '原文' : '格式化',
                  onTap: _toggleFormat,
                  active: _formatted,
                ),
                if (_formatKind == 'json')
                  _actionButton(
                    icon: _treeMode ? Icons.article_outlined : Icons.account_tree_outlined,
                    label: _treeMode ? '文本' : '树',
                    onTap: _toggleTree,
                    active: _treeMode,
                  ),
              ],
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _copy,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _copied ? Icons.check : Icons.copy_rounded,
                          size: 13,
                          color: _copied
                              ? const Color(0xFF69F0AE)
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _copied ? '已复制' : '复制',
                          style: TextStyle(
                            fontSize: 11,
                            color: _copied
                                ? const Color(0xFF69F0AE)
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_json != null && _treeMode)
          _JsonTreeView(data: _json!)
        else
          HighlightView(
            _displayCode,
            language: widget.language,
            theme: theme,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            textStyle: const TextStyle(
              fontFamily: kMonoFamily,
              fontFamilyFallback: kMonoFallback,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
      ],
    );
  }
}

class _JsonTreeView extends StatelessWidget {
  const _JsonTreeView({required this.data});

  final Object data;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF121826),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: _JsonTreeNode(value: data, depth: 0, initiallyExpanded: true),
      ),
    );
  }
}

class _JsonTreeNode extends StatefulWidget {
  const _JsonTreeNode({
    required this.value,
    required this.depth,
    this.keyName,
    this.initiallyExpanded = false,
  });

  final Object? value;
  final int depth;
  final String? keyName;
  final bool initiallyExpanded;

  @override
  State<_JsonTreeNode> createState() => _JsonTreeNodeState();
}

class _JsonTreeNodeState extends State<_JsonTreeNode> {
  late bool _expanded = widget.initiallyExpanded;
  bool _valueExpanded = false;

  bool get _isMap => widget.value is Map;
  bool get _isList => widget.value is List;
  bool get _isContainer => _isMap || _isList;

  List<Widget> _children() {
    final result = <Widget>[];
    if (widget.value is Map) {
      final map = widget.value! as Map;
      for (final entry in map.entries) {
        result.add(_JsonTreeNode(
          keyName: entry.key.toString(),
          value: entry.value,
          depth: widget.depth + 1,
        ));
      }
    } else if (widget.value is List) {
      final list = widget.value! as List;
      for (var i = 0; i < list.length; i++) {
        result.add(_JsonTreeNode(
          keyName: '[$i]',
          value: list[i],
          depth: widget.depth + 1,
        ));
      }
    }
    return result;
  }

  TextSpan _valueSpan(Object? value, {bool expanded = false}) {
    if (value is String) {
      const maxLength = 80;
      final text = value;
      final shown = expanded || text.length <= maxLength
          ? text
          : '${text.substring(0, maxLength)}…';
      return TextSpan(
        text: '"$shown"',
        style: const TextStyle(color: Color(0xFF98C379)),
      );
    }
    if (value is num) {
      return TextSpan(
        text: '$value',
        style: const TextStyle(color: Color(0xFFD19A66)),
      );
    }
    if (value is bool) {
      return TextSpan(
        text: '$value',
        style: const TextStyle(color: Color(0xFFC678DD)),
      );
    }
    if (value == null) {
      return const TextSpan(
        text: 'null',
        style: TextStyle(color: Color(0xFFC678DD), fontStyle: FontStyle.italic),
      );
    }
    return TextSpan(
      text: '$value',
      style: const TextStyle(color: Color(0xFFABB2BF)),
    );
  }

  @override
  Widget build(BuildContext context) {
    const keyStyle = TextStyle(color: Color(0xFF8AB4FF));
    final indent = widget.depth * 16.0;
    if (!_isContainer) {
      final bool isLongString = widget.value is String && (widget.value as String).length > 80;
      return InkWell(
        onTap: isLongString ? () => setState(() => _valueExpanded = !_valueExpanded) : null,
        child: Padding(
          padding: EdgeInsets.only(left: indent, right: 12, top: 2, bottom: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLongString)
                Icon(
                  _valueExpanded ? Icons.arrow_drop_down : Icons.arrow_right,
                  size: 16,
                  color: const Color(0xFF98C379),
                ),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (widget.keyName != null) TextSpan(text: '${widget.keyName}: ', style: keyStyle),
                      _valueSpan(widget.value, expanded: _valueExpanded),
                    ],
                  ),
                  style: const TextStyle(
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final count = _isMap ? (widget.value! as Map).length : (widget.value! as List).length;
    final bracket = _isMap ? '{' : '[';
    final closeBracket = _isMap ? '}' : ']';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: EdgeInsets.only(left: indent, right: 12, top: 2, bottom: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                  size: 18,
                  color: const Color(0xFF8AB4FF),
                ),
                if (widget.keyName != null)
                  Text('${widget.keyName}: ', style: keyStyle),
                Text(
                  '$bracket$count$closeBracket',
                  style: const TextStyle(
                    color: Color(0xFFABB2BF),
                    fontSize: 12.5,
                    fontFamily: kMonoFamily,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: EdgeInsets.only(left: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _children(),
            ),
          ),
      ],
    );
  }
}

/// ` ```plot` 代码块 → 函数图。
class _FunctionPlotSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(r'^```(?:plot|func)\s*$');

  @override
  md.Node? parse(md.BlockParser parser) {
    parser.advance();
    final lines = <String>[];
    while (!parser.isDone) {
      final line = parser.current;
      if (line.content.trimLeft().startsWith('```')) {
        parser.advance();
        break;
      }
      lines.add(line.content);
      parser.advance();
    }
    return md.Element('functionPlot', <md.Node>[md.Text(lines.join('\n'))]);
  }
}

class _FunctionPlotBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) {
    return _FunctionPlotCard(source: text.text);
  }
}

class _FunctionPlotCard extends StatefulWidget {
  const _FunctionPlotCard({required this.source});

  final String source;

  @override
  State<_FunctionPlotCard> createState() => _FunctionPlotCardState();
}

class _FunctionPlotCardState extends State<_FunctionPlotCard>
    with SingleTickerProviderStateMixin {
  _ParsePlot? _parsed;
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _parsed = _parsePlot(widget.source);
    final parsed = _parsed;
    if (parsed == null) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      );
      return;
    }
    if (parsed.usesT) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 4),
      )..repeat();
    } else {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      )..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parsed = _parsed;
    if (parsed == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '函数图格式示例：\n```plot\ny = x^2\nx: -10, 10\n```\n'
          '动态函数用 t：\n```plot\ny = sin(x + t)\n```',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF273246)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights, size: 15, color: const Color(0xFF8AB4FF)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  parsed.connect
                      ? '组合曲线 · ${parsed.series.length} 段'
                      : parsed.series.length > 1
                          ? '${parsed.series.length} 条函数'
                          : parsed.series.first.expr,
                  style: const TextStyle(
                    color: Color(0xFFE6EDF7),
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (parsed.usesT)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1D4ED8).withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: const Color(0xFF3B82F6).withValues(alpha: 0.5),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.animation, size: 12, color: Color(0xFF93C5FD)),
                      SizedBox(width: 4),
                      Text(
                        '动态',
                        style: TextStyle(
                          color: Color(0xFF93C5FD),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (parsed.series.length > 1) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                if (parsed.connect)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFF64B5F6),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        '组合曲线',
                        style: TextStyle(
                          color: Color(0xFFB6C2D4),
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  )
                else
                  for (final s in parsed.series)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: s.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          s.label,
                          style: const TextStyle(
                            color: Color(0xFFB6C2D4),
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 260,
              width: double.infinity,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final progress = parsed.usesT ? 1.0 : _controller.value;
                  final t = parsed.usesT
                      ? _controller.value * 2 * math.pi
                      : 0.0;
                  return CustomPaint(
                    painter: _FunctionPainter(
                      series: parsed.series,
                      xMin: parsed.xMin,
                      xMax: parsed.xMax,
                      t: t,
                      progress: progress,
                      connect: parsed.connect,
                      gridColor: const Color(0xFF243044),
                      axisColor: const Color(0xFF6B7A90),
                    ),
                  );
                },
              ),
            ),
          ),
          if (parsed.usesT)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                't 为动态参数，自动 0~2π 循环',
                style: TextStyle(color: Color(0xFF73839A), fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }
}

_ParsePlot? _parsePlot(String source) {
  final lines = source
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty && !e.startsWith('#'))
      .toList();
  if (lines.isEmpty) return null;
  double? xMin = -10, xMax = 10;
  var connect = false;
  final exprLines = <String>[];
  for (final line in lines) {
    final connectM = RegExp(r'^connect\s*[:：]\s*(true|false)\s*$', caseSensitive: false).firstMatch(line);
    if (connectM != null) {
      connect = connectM.group(1)!.toLowerCase() == 'true';
    } else if (RegExp(r'^x\s*[:：]\s*').hasMatch(line)) {
      final m = RegExp(r'^x\s*[:：]\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*$').firstMatch(line);
      if (m != null) {
        final a = double.tryParse(m.group(1)!);
        final b = double.tryParse(m.group(2)!);
        if (a != null && b != null) {
          xMin = a;
          xMax = b;
        }
      }
    } else {
      exprLines.add(line);
    }
  }
  if (exprLines.isEmpty || xMin == null || xMax == null || xMax <= xMin) {
    return null;
  }
  const colors = [
    Color(0xFF64B5F6),
    Color(0xFFF48FB1),
    Color(0xFF81C784),
    Color(0xFFFFD54F),
    Color(0xFFBA68C8),
    Color(0xFF4DD0E1),
    Color(0xFFFF8A65),
    Color(0xFF9CCC65),
  ];
  try {
    final series = <_FunctionSeries>[];
    for (var i = 0; i < exprLines.length; i++) {
      final raw = exprLines[i];
      double? segMin;
      double? segMax;
      var body = raw;
      final segM = RegExp(
        r'^(.*?),\s*x\s*[:：]\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*$',
      ).firstMatch(raw);
      if (segM != null) {
        body = segM.group(1)!.trim();
        segMin = double.tryParse(segM.group(2)!);
        segMax = double.tryParse(segM.group(3)!);
        if (segMin == null || segMax == null || segMax <= segMin) {
          body = raw;
          segMin = null;
          segMax = null;
        }
      }
      var label = '';
      var expr = body;
      if (body.contains('=')) {
        final idx = body.indexOf('=');
        label = body.substring(0, idx).trim();
        expr = body.substring(idx + 1).trim();
      }
      if (expr.isEmpty) continue;
      final fn = _ExprParser(expr).parse();
      final usesT = RegExp(r'(^|[^a-zA-Z_])t([^a-zA-Z_]|$)').hasMatch(expr);
      series.add(_FunctionSeries(
        label: label.isEmpty ? (series.length == 0 ? 'y' : 'y${series.length + 1}') : label,
        expr: expr,
        fn: fn,
        usesT: usesT,
        color: connect
            ? const Color(0xFF64B5F6)
            : colors[series.length % colors.length],
        segmentXMin: segMin,
        segmentXMax: segMax,
      ));
    }
    if (series.isEmpty) return null;
    return _ParsePlot(
      series: series,
      xMin: xMin,
      xMax: xMax,
      connect: connect,
    );
  } catch (_) {
    return null;
  }
}
class _FunctionSeries {
  const _FunctionSeries({
    required this.label,
    required this.expr,
    required this.fn,
    required this.usesT,
    required this.color,
    this.segmentXMin,
    this.segmentXMax,
  });

  final String label;
  final String expr;
  final _ExprNode fn;
  final bool usesT;
  final Color color;
  final double? segmentXMin;
  final double? segmentXMax;
}

class _ParsePlot {
  const _ParsePlot({
    required this.series,
    required this.xMin,
    required this.xMax,
    required this.connect,
  });

  final List<_FunctionSeries> series;

  bool get usesT => series.any((s) => s.usesT);

  final double xMin;
  final double xMax;
  final bool connect;
}
/// 简易表达式求值：支持 + - * / ^ ( ) 数字、x、t、pi/e，以及常见函数。
/// `t` 是动态时间变量，函数图会把它当作动画参数（0~2π 循环）。
abstract class _ExprNode {
  double eval(double x, double t);
}

class _NumberNode implements _ExprNode {
  _NumberNode(this.value);
  final double value;
  @override
  double eval(double x, double t) => value;
}

class _VarNode implements _ExprNode {
  @override
  double eval(double x, double t) => x;
}

class _TVarNode implements _ExprNode {
  @override
  double eval(double x, double t) => t;
}

class _BinaryNode implements _ExprNode {
  _BinaryNode(this.op, this.left, this.right);
  final String op;
  final _ExprNode left;
  final _ExprNode right;
  @override
  double eval(double x, double t) {
    final l = left.eval(x, t);
    final r = right.eval(x, t);
    switch (op) {
      case '+':
        return l + r;
      case '-':
        return l - r;
      case '*':
        return l * r;
      case '/':
        return r == 0 ? double.nan : l / r;
      case '^':
        var v = double.nan;
        try {
          v = l < 0 && r % 1 != 0 ? double.nan : math.pow(l, r).toDouble();
        } catch (_) {}
        return v;
    }
    return double.nan;
  }
}

class _NegNode implements _ExprNode {
  _NegNode(this.child);
  final _ExprNode child;
  @override
  double eval(double x, double t) => -child.eval(x, t);
}

class _FuncNode implements _ExprNode {
  _FuncNode(this.name, this.arg);
  final String name;
  final _ExprNode arg;
  @override
  double eval(double x, double t) {
    final v = arg.eval(x, t);
    try {
      switch (name) {
        case 'sin':
          return math.sin(v);
        case 'cos':
          return math.cos(v);
        case 'tan':
          return math.tan(v);
        case 'asin':
          return math.asin(v);
        case 'acos':
          return math.acos(v);
        case 'atan':
          return math.atan(v);
        case 'sqrt':
          return v < 0 ? double.nan : math.sqrt(v);
        case 'abs':
          return v.abs();
        case 'exp':
          return math.exp(v);
        case 'ln':
          return v <= 0 ? double.nan : math.log(v);
        case 'log':
        case 'log10':
          return v <= 0 ? double.nan : math.log(v) / math.ln10;
        case 'floor':
          return v.floorToDouble();
        case 'ceil':
          return v.ceilToDouble();
        case 'round':
          return v.roundToDouble();
      }
    } catch (_) {
      return double.nan;
    }
    return double.nan;
  }
}

class _ExprParser {
  _ExprParser(String input)
      : _tokens = _tokenize(input),
        _pos = 0;

  final List<String> _tokens;
  int _pos;

  static final RegExp _num = RegExp(r'^-?\d+(\.\d+)?([eE][+-]?\d+)?$');
  static final RegExp _id = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');
  static final Set<String> _functions = {
    'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'sqrt', 'abs',
    'exp', 'ln', 'log', 'log10', 'floor', 'ceil', 'round',
  };

  static List<String> _tokenize(String input) {
    final result = <String>[];
    final chars = input.replaceAll(' ', '').split('');
    for (var i = 0; i < chars.length; i++) {
      final c = chars[i];
      if ('+-*/^(),'.contains(c)) {
        result.add(c);
      } else if (RegExp(r'[0-9.]').hasMatch(c)) {
        var buf = c;
        while (i + 1 < chars.length &&
            RegExp(r'[0-9.eE+-]').hasMatch(chars[i + 1]) &&
            !'*/^(),'.contains(chars[i + 1])) {
          // 科学计数法里的 +/- 允许跟在 e/E 后
          final next = chars[i + 1];
          final prev = chars[i];
          if ((next == '+' || next == '-') &&
              prev != 'e' && prev != 'E') break;
          i++;
          buf += next;
        }
        result.add(buf);
      } else if (RegExp(r'[a-zA-Z_]').hasMatch(c)) {
        var buf = c;
        while (i + 1 < chars.length && RegExp(r'[a-zA-Z0-9_]').hasMatch(chars[i + 1])) {
          i++;
          buf += chars[i];
        }
        result.add(buf);
      } else {
        throw FormatException('unknown char $c');
      }
    }
    return result;
  }

  _ExprNode parse() {
    final node = _parseExpr();
    if (_pos < _tokens.length) throw FormatException('trailing');
    return node;
  }

  _ExprNode _parseExpr() {
    var left = _parseTerm();
    while (_pos < _tokens.length && (_tokens[_pos] == '+' || _tokens[_pos] == '-')) {
      final op = _tokens[_pos++];
      final right = _parseTerm();
      left = _BinaryNode(op, left, right);
    }
    return left;
  }

  _ExprNode _parseTerm() {
    var left = _parseFactor();
    while (_pos < _tokens.length && (_tokens[_pos] == '*' || _tokens[_pos] == '/')) {
      final op = _tokens[_pos++];
      final right = _parseFactor();
      left = _BinaryNode(op, left, right);
    }
    return left;
  }

  _ExprNode _parseFactor() {
    if (_pos < _tokens.length && _tokens[_pos] == '-') {
      _pos++;
      return _NegNode(_parseFactor());
    }
    if (_pos < _tokens.length && _tokens[_pos] == '+') {
      _pos++;
      return _parseFactor();
    }
    return _parsePower();
  }

  _ExprNode _parsePower() {
    final base = _parsePrimary();
    if (_pos < _tokens.length && _tokens[_pos] == '^') {
      _pos++;
      final exponent = _parseFactor();
      return _BinaryNode('^', base, exponent);
    }
    return base;
  }

  _ExprNode _parsePrimary() {
    if (_pos >= _tokens.length) throw FormatException('expected token');
    final token = _tokens[_pos];
    if (token == '(') {
      _pos++;
      final node = _parseExpr();
      if (_pos >= _tokens.length || _tokens[_pos] != ')') {
        throw FormatException('missing )');
      }
      _pos++;
      return node;
    }
    if (_num.hasMatch(token)) {
      _pos++;
      return _NumberNode(double.parse(token));
    }
    if (_id.hasMatch(token)) {
      _pos++;
      if (token == 'x') return _VarNode();
      if (token == 't') return _TVarNode();
      if ((token == 'pi')) return _NumberNode(3.141592653589793);
      if (token == 'e') return _NumberNode(2.718281828459045);
      if (_functions.contains(token)) {
        if (_pos >= _tokens.length || _tokens[_pos] != '(') {
          throw FormatException('function needs (');
        }
        _pos++;
        final arg = _parseExpr();
        if (_pos >= _tokens.length || _tokens[_pos] != ')') {
          throw FormatException('missing )');
        }
        _pos++;
        return _FuncNode(token, arg);
      }
      throw FormatException('unknown $token');
    }
    throw FormatException('bad token $token');
  }
}

class _FunctionPainter extends CustomPainter {
  _FunctionPainter({
    required this.series,
    required this.xMin,
    required this.xMax,
    this.t = 0,
    this.progress = 1,
    this.connect = false,
    required this.gridColor,
    required this.axisColor,
  });

  final List<_FunctionSeries> series;
  final double xMin;
  final double xMax;
  final double t;
  final double progress;
  final bool connect;
  final Color gridColor;
  final Color axisColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = Paint()..color = const Color(0xFF0B1220);
    canvas.drawRect(rect, bg);

    // 动态 y 范围：所有函数一起采样，避免被无穷大带飞。
    const sampleCount = 512;
    final ys = <double>[];
    final step = (xMax - xMin) / sampleCount;
    for (var i = 0; i <= sampleCount; i++) {
      final x = xMin + step * i;
      for (final s in series) {
        final v = s.fn.eval(x, t);
        if (v.isFinite && v.abs() < 1e9) ys.add(v);
      }
    }
    if (ys.isEmpty) {
      final noData = Paint()
        ..color = const Color(0xFF5B6B82)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), noData);
      return;
    }
    ys.sort();
    final y0 = ys[ys.length ~/ 20];
    final y1 = ys[ys.length * 19 ~/ 20];
    var yMin = y0;
    var yMax = y1;
    if ((yMax - yMin).abs() < 0.5) {
      final c = (yMax + yMin) / 2;
      yMin = c - 1;
      yMax = c + 1;
    }
    final pad = 8.0;

    double tx(double x) => pad + (x - xMin) / (xMax - xMin) * (size.width - pad * 2);
    double ty(double y) => pad + (yMax - y) / (yMax - yMin) * (size.height - pad * 2);

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.6;
    // 垂直网格
    const gridCount = 8;
    for (var i = 0; i <= gridCount; i++) {
      final x = xMin + (xMax - xMin) * i / gridCount;
      canvas.drawLine(Offset(tx(x), pad), Offset(tx(x), size.height - pad), gridPaint);
    }
    for (var i = 0; i <= 6; i++) {
      final y = yMin + (yMax - yMin) * i / 6;
      canvas.drawLine(Offset(pad, ty(y)), Offset(size.width - pad, ty(y)), gridPaint);
    }

    // 坐标轴
    final axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1.1;
    if (yMin <= 0 && yMax >= 0) {
      final y0px = ty(0);
      canvas.drawLine(Offset(pad, y0px), Offset(size.width - pad, y0px), axisPaint);
    }
    if (xMin <= 0 && xMax >= 0) {
      final x0px = tx(0);
      canvas.drawLine(Offset(x0px, pad), Offset(x0px, size.height - pad), axisPaint);
    }

    // 绘制所有函数曲线（progress 控制静态图的绘制动画）
    final totalConnectSamples = connect
        ? series.fold<int>(0, (sum, s) => sum + 257)
        : sampleCount;
    final drawLimit = (totalConnectSamples * progress).round();
    if (connect) {
      // 组合模式：所有段按顺序连成一条同色曲线
      final curve = Paint()
        ..color = const Color(0xFF64B5F6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      final path = Path();
      var started = false;
      var lastFinite = false;
      var drawn = 0;
      const perSegmentSamples = 256;
      for (final s in series) {
        final segMin = s.segmentXMin ?? xMin;
        final segMax = s.segmentXMax ?? xMax;
        final segStep = (segMax - segMin) / perSegmentSamples;
        for (var i = 0; i <= perSegmentSamples; i++) {
          if (drawn > drawLimit) break;
          final x = segMin + segStep * i;
          final y = s.fn.eval(x, t);
          drawn++;
          final ok = y.isFinite && y.abs() < 1e9;
          if (!ok) {
            lastFinite = false;
            continue;
          }
          final px = tx(x);
          final py = ty(y.clamp(yMin, yMax));
          if (!started || !lastFinite) {
            path.moveTo(px, py);
            started = true;
          } else {
            path.lineTo(px, py);
          }
          lastFinite = true;
        }
      }
      if (started) canvas.drawPath(path, curve);
    } else {
      for (final s in series) {
        final curve = Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round;
        final path = Path();
        var started = false;
        var lastFinite = false;
        for (var i = 0; i <= drawLimit; i++) {
          final x = xMin + step * i;
          final y = s.fn.eval(x, t);
          final ok = y.isFinite && y.abs() < 1e9;
          if (!ok) {
            lastFinite = false;
            continue;
          }
          if (!lastFinite || i == 0) {
            path.moveTo(tx(x), ty(y.clamp(yMin, yMax)));
            started = true;
          } else {
            path.lineTo(tx(x), ty(y.clamp(yMin, yMax)));
          }
          lastFinite = true;
        }
        if (started) canvas.drawPath(path, curve);
      }
    }

    // 标签
    final labelPainter = TextPainter(
      text: TextSpan(
        text: '${yMin.toStringAsFixed(1)} ~ ${yMax.toStringAsFixed(1)}',
        style: const TextStyle(color: Color(0xFF73839A), fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    labelPainter.paint(canvas, Offset(6, 2));
  }

  @override
  bool shouldRepaint(covariant _FunctionPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.xMin != xMin ||
      oldDelegate.xMax != xMax ||
      oldDelegate.t != t ||
      oldDelegate.progress != progress ||
      oldDelegate.connect != connect ||
      oldDelegate.axisColor != axisColor;
}

class _MarkdownImage extends StatefulWidget {
  const _MarkdownImage({required this.uri, this.alt});

  final Uri uri;
  final String? alt;

  @override
  State<_MarkdownImage> createState() => _MarkdownImageState();
}

class _MarkdownImageState extends State<_MarkdownImage> {
  bool _loading = false;

  static String _mimeFor(Uri uri) {
    final path = uri.path.toLowerCase();
    if (path.endsWith('.png') || path.endsWith('.apng')) return 'image/png';
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
    if (path.endsWith('.webp')) return 'image/webp';
    if (path.endsWith('.gif')) return 'image/gif';
    if (path.endsWith('.bmp')) return 'image/bmp';
    return 'image/png';
  }

  Widget _display() {
    final uri = widget.uri.toString();
    if (widget.uri.scheme == 'data') {
      return Image.memory(
        base64Decode(
            uri.contains(',') ? uri.substring(uri.indexOf(',') + 1) : uri),
        fit: BoxFit.contain,
        errorBuilder: (_, e, __) => const Icon(Icons.broken_image_outlined),
      );
    }
    return Image.network(
      uri,
      fit: BoxFit.contain,
      errorBuilder: (_, e, __) => const Icon(Icons.broken_image_outlined),
    );
  }

  Future<void> _openPreview() async {
    try {
      if (widget.uri.scheme == 'data') {
        await ImagePreviewOverlay.show(
          context,
          AiImageAttachment(
            name: widget.alt ?? 'markdown_image',
            mime: _mimeFor(widget.uri),
            dataUri: widget.uri.toString(),
          ),
        );
      } else {
        // 网络图直接用 URL 打开预览，不需要重新下载成 base64，
        // 点击立刻弹出，并复用 Flutter 图片缓存。
        await ImagePreviewOverlay.showNetwork(context, widget.uri.toString());
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('图片预览失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (_loading) return;
        setState(() => _loading = true);
        _openPreview().whenComplete(() {
          if (mounted) setState(() => _loading = false);
        });
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260, maxHeight: 260),
        child: _display(),
      ),
    );
  }
}
