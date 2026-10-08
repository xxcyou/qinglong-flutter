import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
/// 修复常见的“代码围栏没闭合”：如果 ```/~~~ 只开不关，
/// markdown 解析会把后面所有内容都吞进代码块。这里自动补一个闭合围栏。
String _normalizeUnclosedFences(String input) {
  final lines = input.split('\n');
  var inFence = false;
  var fenceChar = '`';
  var fenceLen = 3;
  for (final line in lines) {
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty) continue;
    final ch = trimmed[0];
    if (ch != '`' && ch != '~') continue;
    var run = 0;
    while (run < trimmed.length && trimmed[run] == ch) {
      run++;
    }
    if (run < 3) continue;
    final rest = trimmed.substring(run).trim();
    if (!inFence) {
      inFence = true;
      fenceChar = ch;
      fenceLen = run;
    } else if (ch == fenceChar && run >= fenceLen && rest.isEmpty) {
      inFence = false;
    }
  }
  if (!inFence) return input;
  final fence = fenceChar * fenceLen;
  return '$input\n$fence\n';
}


/// 用增强语法再次解析自定义标签里的原始文本，支持 `=={c:red}文字{/c}==` 这类嵌套渲染。
List<md.Node> _parseStyleNodes(String text) {
  return md.Document(extensionSet: MarkdownMessage.enhancedExtensionSet)
      .parseInline(text);
}

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
      _NeonSyntax(),
      _GradientSyntax(),
      _FlashSyntax(),
      _RainbowSyntax(),
      _PulseSyntax(),
      _ShimmerSyntax(),
      _BounceSyntax(),
      _TypingSyntax(),
      _WrapASyntax(),
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
      data: _normalizeUnclosedFences(text),
      selectable: selectable,
      extensionSet: enhancedExtensionSet,
      blockSyntaxes: [_FunctionPlotSyntax()],
      builders: {
        'u': _UnderlineBuilder(),
        'mark': _GlowBuilder(),
        'span': _ColorSpanBuilder(),
        'highlight': _HighlightBuilder(),
        'neon': _NeonBuilder(),
        'g': _GradientBuilder(),
        'flash': _FlashBuilder(),
        'rainbow': _RainbowBuilder(),
        'pulse': _PulseBuilder(),
        'shimmer': _ShimmerBuilder(),
        'bounce': _BounceBuilder(),
        'typing': _TypingBuilder(),
        'wrap': _TransparentBuilder(),
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
  _UnderlineSyntax() : super(r'\+\+(.+?)\+\+');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    // 只保留一个原始文本子节点；真正嵌套样式在 Builder 里二次解析，
    // 避免 flutter_markdown 合并时因为多个子节点只替换第一个而丢样式。
    parser.addNode(md.Element('u', [md.Text(match.group(1) ?? '')]));
    return true;
  }
}

/// `==文字==` → 发光（霓虹强调）。
class _GlowSyntax extends md.InlineSyntax {
  _GlowSyntax() : super(r'==(.+?)==');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element('mark', [md.Text(match.group(1) ?? '')]));
    return true;
  }
}

/// `{c:red}文字{/c}` → 指定颜色，支持红/绿/蓝等名字或 #RRGGBB。
class _ColorSyntax extends md.InlineSyntax {
  _ColorSyntax() : super(r'\{c:([^}\n]+)\}(.+?)\{/c\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element('span', [md.Text(match.group(2) ?? '')])
      ..attributes['color'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

/// `{bg:yellow}文字{/bg}` → 背景高亮（荧光笔）。
class _HighlightSyntax extends md.InlineSyntax {
    _HighlightSyntax() : super(r'\{bg:([^}\n]+)\}(.+?)\{/bg\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element('highlight', [md.Text(match.group(2) ?? '')])
      ..attributes['bg'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

/// `{neon:cyan}文字{/neon}` → 指定颜色霓虹发光。
class _NeonSyntax extends md.InlineSyntax {
  _NeonSyntax() : super(r'\{neon:([^}\n]*)\}(.+?)\{/neon\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element('neon', [md.Text(match.group(2) ?? '')])
      ..attributes['color'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

/// `{g:red,yellow}文字{/g}` → 左右渐变。
class _GradientSyntax extends md.InlineSyntax {
  _GradientSyntax() : super(r'\{g:([^}\n]+)\}(.+?)\{/g\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element('g', [md.Text(match.group(2) ?? '')])
      ..attributes['colors'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

/// `{flash:red,yellow}文字{/flash}` → 闪烁动画。
class _FlashSyntax extends md.InlineSyntax {
  _FlashSyntax() : super(r'\{flash:([^}\n]+)\}(.+?)\{/flash\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element('flash', [md.Text(match.group(2) ?? '')])
      ..attributes['colors'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

/// 解析逗号分隔的颜色列表，如 `red,#00ffcc`。
List<Color> _parseColorList(String raw) {
  final colors = <Color>[];
  for (final part in raw.split(',')) {
    final c = _ColorSpanBuilder()._parse(part.trim());
    if (c != null) colors.add(c);
  }
  if (colors.isEmpty) {
    colors.addAll(const  [Color(0xFF00E5FF), Color(0xFFFF4081)]);
  }
  return colors;
}

/// 估算文本宽度，用于内嵌渐变时的 shader 横向长度。
double _estimateTextWidth(String text, TextStyle? style) {
  final count = text.runes.length;
  final size = style?.fontSize ?? 14;
  return math.max(20.0, count * size * 0.62);
}

/// `{a}...{/a}` → 通用透明外层（AI 偶尔会生成，不增加特效，只让里面标签正常渲染）。
class _WrapASyntax extends md.InlineSyntax {
  _WrapASyntax() : super(r'\{a\}(.+?)\{/a\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element('wrap', [md.Text(match.group(1) ?? '')]));
    return true;
  }
}

/// `{rainbow}文字{/rainbow}` → 彩虹渐变循环（可 `{rainbow:red,blue}` 自定义色板）。
class _RainbowSyntax extends md.InlineSyntax {
  _RainbowSyntax() : super(r'\{rainbow(?::([^}\n]+))?\}(.+?)\{/rainbow\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element('rainbow', [md.Text(match.group(2) ?? '')])
      ..attributes['colors'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

/// `{pulse}文字{/pulse}` → 呼吸/脉冲效果（可给颜色）。
class _PulseSyntax extends md.InlineSyntax {
  _PulseSyntax() : super(r'\{pulse(?::([^}\n]+))?\}(.+?)\{/pulse\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element('pulse', [md.Text(match.group(2) ?? '')])
      ..attributes['colors'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

/// `{shimmer}文字{/shimmer}` → 金属流光扫过。
class _ShimmerSyntax extends md.InlineSyntax {
  _ShimmerSyntax() : super(r'\{shimmer(?::([^}\n]+))?\}(.+?)\{/shimmer\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element('shimmer', [md.Text(match.group(2) ?? '')])
      ..attributes['colors'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

/// `{bounce}文字{/bounce}` → 上下跳动。
class _BounceSyntax extends md.InlineSyntax {
  _BounceSyntax() : super(r'\{bounce\}(.+?)\{/bounce\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element('bounce', [md.Text(match.group(1) ?? '')]));
    return true;
  }
}

/// `{typing}文字{/typing}` → 打字机逐个出现。
class _TypingSyntax extends md.InlineSyntax {
  _TypingSyntax() : super(r'\{typing(?::([^}\n]+))?\}(.+?)\{/typing\}');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final node = md.Element('typing', [md.Text(match.group(2) ?? '')])
      ..attributes['color'] = match.group(1) ?? '';
    parser.addNode(node);
    return true;
  }
}

/// 递归构建**扁平**内联 TextSpan。
///
/// 不能返回嵌套 TextSpan 树：flutter_markdown 合并相邻文本时会把中间层
/// 的 children 丢掉，导致样式丢失/文字消失。这里把所有样式累积到叶子 TextSpan 上。
List<InlineSpan> _buildInlineSpans(List<md.Node>? nodes, TextStyle? parent) {
  if (nodes == null || nodes.isEmpty) return const [];
  final result = <InlineSpan>[];
  for (final node in nodes) {
    _buildNodeSpans(node, parent, result);
  }
  return result;
}

void _buildNodeSpans(md.Node node, TextStyle? parent, List<InlineSpan> out) {
  if (node is md.Text) {
    out.add(TextSpan(text: node.text, style: parent));
    return;
  }
  if (node is md.Element) {
    final children = node.children;
    final base = parent ?? const TextStyle();
    TextStyle? style;
    switch (node.tag) {
      case 'u':
        style = base.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: base.color,
        );
        for (final child in _parseStyleNodes(node.textContent)) {
          _buildNodeSpans(child, style, out);
        }
        return;
      case 'mark':
        const glow = Color(0xFFFFD54F);
        // 发光只负责加光晕；外层已指定颜色时保留外层颜色。
        style = base.copyWith(
          color: base.color ?? glow,
          shadows: const [
            Shadow(color: Color(0x66FFD54F), blurRadius: 6),
            Shadow(color: Color(0x44FFB300), blurRadius: 14),
          ],
        );
        for (final child in _parseStyleNodes(node.textContent)) {
          _buildNodeSpans(child, style, out);
        }
        return;
      case 'span':
        final color =
            _ColorSpanBuilder()._parse(node.attributes['color'] ?? '');
        style = base.copyWith(color: color);
        for (final child in _parseStyleNodes(node.textContent)) {
          _buildNodeSpans(child, style, out);
        }
        return;
      case 'highlight':
        final bg = _ColorSpanBuilder()._parse(node.attributes['bg'] ?? '');
        // 背景不覆盖外层颜色；只有没指定颜色时才按背景亮度自适应。
        style = base.copyWith(
          backgroundColor: bg,
          color:
              base.color != null
                  ? base.color
                  : (bg != null && bg.computeLuminance() > 0.55
                      ? const Color(0xFF1A1A1A)
                      : base.color),
        );
        for (final child in _parseStyleNodes(node.textContent)) {
          _buildNodeSpans(child, style, out);
        }
        return;
      case 'strong':
        style = base.copyWith(fontWeight: FontWeight.bold);
        break;
      case 'em':
        style = base.copyWith(fontStyle: FontStyle.italic);
        break;
      case 'code':
        style = base.copyWith(
          fontFamily: kMonoFamily,
          fontFamilyFallback: kMonoFallback,
          fontSize: 12.5,
        );
        break;
      case 'del':
      case 's':
      case 'strike':
        style = base.copyWith(
          decoration: TextDecoration.lineThrough,
          decorationColor: base.color,
        );
        break;
      case 'neon':
        final neonColor =
            _ColorSpanBuilder()._parse(node.attributes['color'] ?? '') ??
                const Color(0xFF00E5FF);
        style = base.copyWith(
          color: neonColor,
          shadows: [
            Shadow(color: neonColor.withValues(alpha: 0.9), blurRadius: 8),
            Shadow(color: neonColor.withValues(alpha: 0.6), blurRadius: 16),
            Shadow(color: neonColor.withValues(alpha: 0.3), blurRadius: 24),
          ],
        );
        for (final child in _parseStyleNodes(node.textContent)) {
          _buildNodeSpans(child, style, out);
        }
        return;
      case 'g':
        final gradientColors = _parseColorList(node.attributes['colors'] ?? '');
        final parsed = _parseStyleNodes(node.textContent);
        final childSpans = _buildInlineSpans(parsed, null);
        for (final span in childSpans) {
          if (span is TextSpan && span.text != null && span.text!.isNotEmpty) {
            final paint = Paint()
              ..shader = ui.Gradient.linear(
                Offset.zero,
                Offset(_estimateTextWidth(span.text!, base), 0),
                gradientColors,
              );
            out.add(TextSpan(
              text: span.text,
              style: (span.style ?? const TextStyle()).copyWith(
                foreground: paint,
                shadows: span.style?.shadows,
              ),
            ));
          } else {
            out.add(span);
          }
        }
        return;
      case 'flash':
        final flashColors = _parseColorList(node.attributes['colors'] ?? '');
        style = base.copyWith(color: flashColors.first);
        for (final child in _parseStyleNodes(node.textContent)) {
          _buildNodeSpans(child, style, out);
        }
        return;
      case 'rainbow':
        final rainbowColors = _parseColorList(node.attributes['colors'] ?? '');
        out.add(WidgetSpan(
          child: _RainbowText(
            child: Text.rich(TextSpan(
                children:
                    _buildInlineSpans(_parseStyleNodes(node.textContent), base))),
            colors: rainbowColors,
          ),
        ));
        return;
      case 'pulse':
        final pulseColors = _parseColorList(node.attributes['colors'] ?? '');
        out.add(WidgetSpan(
          child: _PulseText(
            child: Text.rich(TextSpan(
                children:
                    _buildInlineSpans(_parseStyleNodes(node.textContent), base))),
            colors: pulseColors,
          ),
        ));
        return;
      case 'shimmer':
        final shimmerColors = _parseColorList(node.attributes['colors'] ?? '');
        out.add(WidgetSpan(
          child: _ShimmerText(
            child: Text.rich(TextSpan(
                children:
                    _buildInlineSpans(_parseStyleNodes(node.textContent), base))),
            colors: shimmerColors,
          ),
        ));
        return;
      case 'bounce':
        out.add(WidgetSpan(
          child: _BounceText(
            child: Text.rich(TextSpan(
                children:
                    _buildInlineSpans(_parseStyleNodes(node.textContent), base))),
          ),
        ));
        return;
      case 'typing':
        final typingColor =
            _ColorSpanBuilder()._parse(node.attributes['color'] ?? '');
        final typingBase =
            typingColor != null ? base.copyWith(color: typingColor) : base;
        out.add(WidgetSpan(
          child: _TypingText(
            child: Text.rich(TextSpan(
                children: _buildInlineSpans(
                    _parseStyleNodes(node.textContent), typingBase))),
          ),
        ));
        return;
      case 'wrap':
        for (final child in _parseStyleNodes(node.textContent)) {
          _buildNodeSpans(child, base, out);
        }
        return;
      default:
        style = parent;
        break;
    }
    if (children != null) {
      for (final child in children) {
        _buildNodeSpans(child, style, out);
      }
    }
    return;
  }
  out.add(TextSpan(text: node.textContent, style: parent));
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
    final style = (parentStyle ?? const TextStyle()).copyWith(
      decoration: TextDecoration.underline,
      decorationColor: parentStyle?.color,
    );
    final spans = _buildInlineSpans(_parseStyleNodes(element.textContent), style);
    if (spans.isEmpty) return null;
    return Text.rich(TextSpan(children: spans));
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
    const glow = Color(0xFFFFD54F);
    final style = (parentStyle ?? const TextStyle()).copyWith(
      color: parentStyle?.color ?? glow,
      shadows: const [
        Shadow(color: Color(0x66FFD54F), blurRadius: 6),
        Shadow(color: Color(0x44FFB300), blurRadius: 14),
      ],
    );
    final spans = _buildInlineSpans(_parseStyleNodes(element.textContent), style);
    if (spans.isEmpty) return null;
    return Text.rich(TextSpan(children: spans));
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
    final color = _parse(element.attributes['color'] ?? '');
    final spans = _buildInlineSpans(
        _parseStyleNodes(element.textContent),
        (parentStyle ?? const TextStyle()).copyWith(color: color));
    if (spans.isEmpty) return null;
    return Text.rich(TextSpan(children: spans));
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
    final bg = _parseColor(element.attributes['bg'] ?? '');
    final base = parentStyle ?? const TextStyle();
    final style = base.copyWith(
      backgroundColor: bg,
      color: bg != null ? _readableOn(bg) : base.color,
    );
    final spans = _buildInlineSpans(_parseStyleNodes(element.textContent), style);
    if (spans.isEmpty) return null;
    return Text.rich(TextSpan(children: spans));
  }

  Color _readableOn(Color bg) {
    // 简单的亮度判断：深底用浅字，浅底用深字。
    final luminance = 0.299 * bg.red + 0.587 * bg.green + 0.114 * bg.blue;
    return luminance > 150 ? const Color(0xFF1A1A1A) : Colors.white;
  }
}

class _NeonBuilder extends MarkdownElementBuilder {
  _NeonBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final neonColor =
        _ColorSpanBuilder()._parse(element.attributes['color'] ?? '') ??
            const Color(0xFF00E5FF);
    final style = (parentStyle ?? const TextStyle()).copyWith(
      color: neonColor,
      shadows: [
        Shadow(color: neonColor.withValues(alpha: 0.9), blurRadius: 8),
        Shadow(color: neonColor.withValues(alpha: 0.6), blurRadius: 16),
        Shadow(color: neonColor.withValues(alpha: 0.3), blurRadius: 24),
      ],
    );
    final spans =
        _buildInlineSpans(_parseStyleNodes(element.textContent), style);
    if (spans.isEmpty) return null;
    return Text.rich(TextSpan(children: spans));
  }
}

class _GradientBuilder extends MarkdownElementBuilder {
  _GradientBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final colors = _parseColorList(element.attributes['colors'] ?? '');
    final spans =
        _buildInlineSpans(_parseStyleNodes(element.textContent), parentStyle);
    if (spans.isEmpty) return null;
    return ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        colors: colors,
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(bounds),
      blendMode: BlendMode.srcIn,
      child: Text.rich(TextSpan(children: spans)),
    );
  }
}

class _FlashBuilder extends MarkdownElementBuilder {
  _FlashBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final colors = _parseColorList(element.attributes['colors'] ?? '');
    final nodes = _parseStyleNodes(element.textContent);
    return _FlashText(
      nodes: nodes,
      baseStyle: parentStyle,
      colors: colors,
    );
  }
}

class _FlashText extends StatefulWidget {
  const _FlashText({
    required this.nodes,
    required this.baseStyle,
    required this.colors,
  });

  final List<md.Node> nodes;
  final TextStyle? baseStyle;
  final List<Color> colors;

  @override
  State<_FlashText> createState() => _FlashTextState();
}

class _FlashTextState extends State<_FlashText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = (math.sin(_controller.value * math.pi * 2) + 1) / 2;
        final flashColor =
            Color.lerp(widget.colors.first, widget.colors.last, t) ??
                widget.colors.first;
        final base = widget.baseStyle ?? const TextStyle();
        final style = base.copyWith(color: flashColor);
        final spans = _buildInlineSpans(widget.nodes, style);
        return Text.rich(TextSpan(children: spans));
      },
    );
  }
}

class _RainbowBuilder extends MarkdownElementBuilder {
  _RainbowBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final colors = _parseColorList(element.attributes['colors'] ?? '');
    final child = Text.rich(TextSpan(
        children: _buildInlineSpans(
            _parseStyleNodes(element.textContent), parentStyle)));
    return Text.rich(TextSpan(
      children: [WidgetSpan(child: _RainbowText(child: child, colors: colors))],
    ));
  }
}

class _PulseBuilder extends MarkdownElementBuilder {
  _PulseBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final colors = _parseColorList(element.attributes['colors'] ?? '');
    final child = Text.rich(TextSpan(
        children: _buildInlineSpans(
            _parseStyleNodes(element.textContent), parentStyle)));
    return Text.rich(TextSpan(
      children: [WidgetSpan(child: _PulseText(child: child, colors: colors))],
    ));
  }
}

class _ShimmerBuilder extends MarkdownElementBuilder {
  _ShimmerBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final colors = _parseColorList(element.attributes['colors'] ?? '');
    final child = Text.rich(TextSpan(
        children: _buildInlineSpans(
            _parseStyleNodes(element.textContent), parentStyle)));
    return Text.rich(TextSpan(
      children: [WidgetSpan(child: _ShimmerText(child: child, colors: colors))],
    ));
  }
}

class _BounceBuilder extends MarkdownElementBuilder {
  _BounceBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final child = Text.rich(TextSpan(
        children: _buildInlineSpans(
            _parseStyleNodes(element.textContent), parentStyle)));
    return Text.rich(TextSpan(
      children: [WidgetSpan(child: _BounceText(child: child))],
    ));
  }
}

class _TypingBuilder extends MarkdownElementBuilder {
  _TypingBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final color =
        _ColorSpanBuilder()._parse(element.attributes['color'] ?? '');
    final base = parentStyle ?? const TextStyle();
    final style = color != null ? base.copyWith(color: color) : base;
    final child = Text.rich(TextSpan(
        children: _buildInlineSpans(
            _parseStyleNodes(element.textContent), style)));
    return Text.rich(TextSpan(
      children: [WidgetSpan(child: _TypingText(child: child))],
    ));
  }
}

class _TransparentBuilder extends MarkdownElementBuilder {
  _TransparentBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final spans = _buildInlineSpans(
        _parseStyleNodes(element.textContent), parentStyle);
    if (spans.isEmpty) return null;
    return Text.rich(TextSpan(children: spans));
  }
}

class _RainbowText extends StatefulWidget {
  const _RainbowText({required this.child, required this.colors});

  final Widget child;
  final List<Color> colors;

  @override
  State<_RainbowText> createState() => _RainbowTextState();
}

class _RainbowTextState extends State<_RainbowText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            colors: widget.colors,
            begin: Alignment(-1.2 + 2.4 * t, 0),
            end: Alignment(0.8 + 2.4 * t, 0),
          ).createShader(bounds),
          blendMode: BlendMode.srcIn,
          child: widget.child,
        );
      },
    );
  }
}

class _PulseText extends StatefulWidget {
  const _PulseText({required this.child, required this.colors});

  final Widget child;
  final List<Color> colors;

  @override
  State<_PulseText> createState() => _PulseTextState();
}

class _PulseTextState extends State<_PulseText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_controller.value);
        Widget child = widget.child;
        if (widget.colors.isNotEmpty) {
          final from = widget.colors.first;
          final to = widget.colors.length >= 2 ? widget.colors[1] : from;
          final color = Color.lerp(from, to, t) ?? from;
          child = ColorFiltered(
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
            child: widget.child,
          );
        }
        return Opacity(opacity: 0.55 + 0.45 * t, child: child);
      },
    );
  }
}

class _ShimmerText extends StatefulWidget {
  const _ShimmerText({required this.child, required this.colors});

  final Widget child;
  final List<Color> colors;

  @override
  State<_ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<_ShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final baseColor =
            widget.colors.length >= 2
                ? widget.colors[0]
                : const Color(0xFF888888);
        final endColor =
            widget.colors.length >= 2
                ? widget.colors[1]
                : const Color(0xFFDDDDDD);
        return ShaderMask(
          shaderCallback: (bounds) {
            // 光带从第一个字开始，向右扫到最后一个字后离开。
            final bandWidth = bounds.width * 0.45;
            final startX = -bandWidth + t * (bounds.width + bandWidth);
            return ui.Gradient.linear(
              Offset(startX, 0),
              Offset(startX + bandWidth, 0),
              [baseColor, Colors.white, endColor],
              const [0.0, 0.5, 1.0],
            );
          },
          blendMode: BlendMode.srcIn,
          child: widget.child,
        );
      },
    );
  }
}

class _BounceText extends StatefulWidget {
  const _BounceText({required this.child});

  final Widget child;

  @override
  State<_BounceText> createState() => _BounceTextState();
}

class _BounceTextState extends State<_BounceText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final dy = math.sin(_controller.value * math.pi * 2) * 5.0;
        return Transform.translate(
          offset: Offset(0, dy),
          child: widget.child,
        );
      },
    );
  }
}

class _TypingText extends StatefulWidget {
  const _TypingText({required this.child});

  final Widget child;

  @override
  State<_TypingText> createState() => _TypingTextState();
}

class _TypingTextState extends State<_TypingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_controller.value);
        return ClipRect(
          clipper: _TypingRevealClipper(t.clamp(0.0, 1.0)),
          child: widget.child,
        );
      },
    );
  }
}

class _TypingRevealClipper extends CustomClipper<Rect> {
  const _TypingRevealClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(covariant _TypingRevealClipper oldClipper) =>
      oldClipper.fraction != fraction;
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
            // highlight 0.7 在 language == null 时会直接抛 ArgumentError，
            // 无语言围栏（AI 很常发）会整块渲染失败；这里回退到 plaintext。
            language: (widget.language == null ||
                    widget.language!.trim().isEmpty)
                ? 'plaintext'
                : widget.language,
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

/// ` ```plot` / `~~~plot` 代码块 → 函数图。
///
/// 兼容 AI 常见的各种写法：0~3 空格缩进、3 个以上反引号/波浪线、
/// plot/plotly/gnuplot/func/function/graph/chart/curve/math 等语言名。
class _FunctionPlotSyntax extends md.BlockSyntax {
  static final RegExp _pattern = RegExp(
    r'^\s*(`{3,}|~{3,})\s*(?:plot(?:ly)?|gnuplot|func(?:tion)?|graph|chart|curve|math)\s*(.*)$',
    caseSensitive: false,
  );

  @override
  RegExp get pattern => _pattern;

  @override
  md.Node? parse(md.BlockParser parser) {
    final first = _pattern.firstMatch(parser.current.content);
    if (first == null) return null;
    final marker = first.group(1)!;
    final fenceChar = marker[0];
    final fenceLen = marker.length;
    parser.advance();
    final lines = <String>[];
    final inline = first.group(2)?.trim();
    if (inline != null && inline.isNotEmpty) lines.add(inline);
    while (!parser.isDone) {
      final raw = parser.current.content;
      final trimmed = raw.trimLeft();
      if (trimmed.isNotEmpty && trimmed[0] == fenceChar) {
        var run = 0;
        while (run < trimmed.length && trimmed[run] == fenceChar) {
          run++;
        }
        if (run >= fenceLen && trimmed.substring(run).trim().isEmpty) {
          parser.advance();
          break;
        }
      }
      lines.add(raw);
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

class _ViewBounds {
  const _ViewBounds(this.xMin, this.xMax, this.yMin, this.yMax);

  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;

  double get xSpan => xMax - xMin;
  double get ySpan => yMax - yMin;
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
  _ViewBounds? _view;
  _ViewBounds? _gestureStart;
  Size? _plotSize;

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
    if (parsed.usesT || parsed.usesU) {
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

  /// 计算“能完整展示所有结果”的等比视图范围。
  _ViewBounds? _autoBounds(Size size) {
    final parsed = _parsed;
    if (parsed == null || size.width <= 0 || size.height <= 0) return null;
    double? dataXMin;
    double? dataXMax;
    double? dataYMin;
    double? dataYMax;

    if (parsed.paramSeries.isNotEmpty) {
      final pts = <Offset>[];
      const n = 400;
      final step = (parsed.tMax - parsed.tMin) / n;
      final uCount = parsed.usesU ? 16 : 1;
      for (final ps in parsed.paramSeries) {
        for (var ui = 0; ui <= uCount; ui++) {
          final uu = parsed.usesU ? 2 * math.pi * ui / uCount : 0.0;
          for (var i = 0; i <= n; i++) {
            final tt = parsed.tMin + step * i;
            final x = ps.x.eval(0, tt, uu);
            final y = ps.y.eval(0, tt, uu);
            if (x.isFinite && y.isFinite && x.abs() < 1e9 && y.abs() < 1e9) {
              pts.add(Offset(x, y));
            }
          }
        }
      }
      if (pts.isNotEmpty) {
        final xs = pts.map((p) => p.dx).toList()..sort();
        final ys = pts.map((p) => p.dy).toList()..sort();
        dataXMin = xs.first;
        dataXMax = xs.last;
        dataYMin = ys.first;
        dataYMax = ys.last;
      }
    }

    if (parsed.series.isNotEmpty) {
      final fxMin = parsed.xMin;
      final fxMax = parsed.xMax;
      if (fxMax > fxMin) {
        final ys = <double>[];
        final dynamicMode = parsed.usesT || parsed.usesU;
        const rangeSampleCount = 256;
        final xSpan = fxMax - fxMin;
        final rangeStep = xSpan / rangeSampleCount;
        if (dynamicMode) {
          const tSteps = 16;
          for (var ti = 0; ti <= tSteps; ti++) {
            final tt = 2 * math.pi * ti / tSteps;
            for (var i = 0; i <= rangeSampleCount; i++) {
              final x = fxMin + rangeStep * i;
              for (final s in parsed.series) {
                final v = s.fn.eval(x, tt, tt);
                if (v.isFinite && v.abs() < 1e9) ys.add(v);
              }
            }
          }
        } else {
          for (var i = 0; i <= rangeSampleCount; i++) {
            final x = fxMin + rangeStep * i;
            for (final s in parsed.series) {
              final v = s.fn.eval(x, 0, 0);
              if (v.isFinite && v.abs() < 1e9) ys.add(v);
            }
          }
        }
        if (ys.isNotEmpty) {
          ys.sort();
          final yMin = dynamicMode ? ys.first : ys[ys.length ~/ 20];
          final yMax = dynamicMode ? ys.last : ys[ys.length * 19 ~/ 20];
          final dxMin = dataXMin ?? fxMin;
          final dxMax = dataXMax ?? fxMax;
          final dyMin = dataYMin ?? yMin;
          final dyMax = dataYMax ?? yMax;
          dataXMin = math.min(dxMin, fxMin);
          dataXMax = math.max(dxMax, fxMax);
          dataYMin = math.min(dyMin, yMin);
          dataYMax = math.max(dyMax, yMax);
        }
      }
    }

    if (dataXMin == null || dataXMax == null || dataYMin == null || dataYMax == null) {
      return null;
    }
    if ((dataXMax - dataXMin).abs() < 0.5) {
      final c = (dataXMax + dataXMin) / 2;
      dataXMin = c - 1;
      dataXMax = c + 1;
    }
    if ((dataYMax - dataYMin).abs() < 0.5) {
      final c = (dataYMax + dataYMin) / 2;
      dataYMin = c - 1;
      dataYMax = c + 1;
    }
    if (dataXMax <= dataXMin || dataYMax <= dataYMin) return null;
    const pad = 8.0;
    final availW = size.width - pad * 2;
    final availH = size.height - pad * 2;
    if (availW <= 0 || availH <= 0) return null;
    // 等比缩放：x/y 每单位像素数一致，同时留 8% 边距
    final u = math.min(
      availW / ((dataXMax - dataXMin) * 1.08),
      availH / ((dataYMax - dataYMin) * 1.08),
    );
    final dispXSpan = availW / u;
    final dispYSpan = availH / u;
    final cx = (dataXMin + dataXMax) / 2;
    final cy = (dataYMin + dataYMax) / 2;
    return _ViewBounds(
      cx - dispXSpan / 2,
      cx + dispXSpan / 2,
      cy - dispYSpan / 2,
      cy + dispYSpan / 2,
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    final auto = _autoBounds(_plotSize ?? Size.zero);
    if (auto == null) return;
    _gestureStart = _view ?? auto;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final start = _gestureStart;
    final size = _plotSize;
    if (start == null || size == null) return;
    const pad = 8.0;
    final availW = size.width - pad * 2;
    final availH = size.height - pad * 2;
    if (availW <= 0 || availH <= 0) return;
    final oldSpanX = start.xSpan;
    final oldSpanY = start.ySpan;
    final scale = details.scale.clamp(0.2, 10.0);
    final newSpanX = oldSpanX / scale;
    final newSpanY = oldSpanY / scale;
    final fx = ((details.localFocalPoint.dx - pad) / availW).clamp(0.0, 1.0);
    final fy = ((details.localFocalPoint.dy - pad) / availH).clamp(0.0, 1.0);
    final worldX = start.xMin + oldSpanX * fx;
    final worldY = start.yMax - oldSpanY * fy;
    final nxMin = worldX - newSpanX * fx;
    final nxMax = nxMin + newSpanX;
    final nyMax = worldY + newSpanY * fy;
    final nyMin = nyMax - newSpanY;
    setState(() => _view = _ViewBounds(nxMin, nxMax, nyMin, nyMax));
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _gestureStart = null;
  }

  void _zoom(double factor) {
    final size = _plotSize;
    final auto = _autoBounds(size ?? Size.zero);
    if (auto == null) return;
    final current = _view ?? auto;
    final cx = (current.xMin + current.xMax) / 2;
    final cy = (current.yMin + current.yMax) / 2;
    final newSpanX = current.xSpan / factor;
    final newSpanY = current.ySpan / factor;
    setState(() {
      _view = _ViewBounds(
        cx - newSpanX / 2,
        cx + newSpanX / 2,
        cy - newSpanY / 2,
        cy + newSpanY / 2,
      );
    });
  }

  void _pan(double dx, double dy) {
    final size = _plotSize;
    final auto = _autoBounds(size ?? Size.zero);
    if (auto == null) return;
    final current = _view ?? auto;
    final shiftX = current.xSpan * 0.3 * dx;
    final shiftY = current.ySpan * 0.3 * dy;
    setState(() {
      _view = _ViewBounds(
        current.xMin + shiftX,
        current.xMax + shiftX,
        current.yMin + shiftY,
        current.yMax + shiftY,
      );
    });
  }

  Widget _plotIconButton(IconData icon, String tooltip, VoidCallback onPressed) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      color: const Color(0xFF93C5FD),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parsed = _parsed;
    if (parsed == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 15, color: scheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '函数图解析失败：表达式可能被截断或某一行格式不对。',
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
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
                  parsed.parametric
                      ? (parsed.series.isNotEmpty
                          ? '${parsed.paramSeries.length} 条参数曲线 + '
                              '${parsed.series.length} 条函数'
                          : parsed.paramSeries.length > 1
                              ? '${parsed.paramSeries.length} 条参数曲线'
                              : '参数曲线')
                      : parsed.pair
                          ? '${parsed.series.length ~/ 2} 层闭合曲线'
                          : parsed.connect
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
              IconButton(
                onPressed: () => setState(() => _view = null),
                icon: const Icon(Icons.center_focus_weak, size: 15),
                color: const Color(0xFF73839A),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                tooltip: '重置缩放',
              ),
              if (parsed.usesT || parsed.usesU)
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
                if (parsed.pair)
                  for (var pi = 0; pi < parsed.series.length; pi += 2)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: parsed.series[pi].color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '层${pi ~/ 2 + 1}',
                          style: const TextStyle(
                            color: Color(0xFFB6C2D4),
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    )
                else if (parsed.connect)
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _plotSize = constraints.biggest;
                  final view = _view ?? _autoBounds(constraints.biggest);
                  return AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      final _dynamicMode = parsed.usesT || parsed.usesU;
                      final progress = _dynamicMode ? 1.0 : _controller.value;
                      final t = _dynamicMode
                          ? _controller.value * 2 * math.pi
                          : 0.0;
                      return GestureDetector(
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: _onScaleUpdate,
                        onScaleEnd: _onScaleEnd,
                        onDoubleTap: () => setState(() => _view = null),
                        child: CustomPaint(
                          painter: _FunctionPainter(
                            series: parsed.series,
                            xMin: parsed.xMin,
                            xMax: parsed.xMax,
                            t: t,
                            progress: progress,
                            connect: parsed.connect,
                            pair: parsed.pair,
                            parametric: parsed.parametric,
                            paramSeries: parsed.paramSeries,
                            usesU: parsed.usesU,
                            tMin: parsed.tMin,
                            tMax: parsed.tMax,
                            viewXMin: view?.xMin,
                            viewXMax: view?.xMax,
                            viewYMin: view?.yMin,
                            viewYMax: view?.yMax,
                            gridColor: const Color(0xFF243044),
                            axisColor: const Color(0xFF6B7A90),
                          ),
                          child: const SizedBox.expand(),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _plotIconButton(
                  Icons.zoom_out,
                  '缩小',
                  () => _zoom(1 / 1.35),
                ),
                _plotIconButton(
                  Icons.zoom_in,
                  '放大',
                  () => _zoom(1.35),
                ),
                _plotIconButton(
                  Icons.keyboard_arrow_left,
                  '左移',
                  () => _pan(-1, 0),
                ),
                _plotIconButton(
                  Icons.keyboard_arrow_right,
                  '右移',
                  () => _pan(1, 0),
                ),
                _plotIconButton(
                  Icons.keyboard_arrow_up,
                  '上移',
                  () => _pan(0, 1),
                ),
                _plotIconButton(
                  Icons.keyboard_arrow_down,
                  '下移',
                  () => _pan(0, -1),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(
              '也可双指等比缩放/拖动平移 · 双击/右上角重置',
              style: TextStyle(color: Color(0xFF73839A), fontSize: 10),
            ),
          ),
          if (parsed.usesT || parsed.usesU)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                '动态参数 t/u 自动 0~2π 循环',
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
  double xMin = -10, xMax = 10;
  double tMin = 0, tMax = 6.283185307179586;
  var connect = false;
  var pairFlag = false;
  var paramFlag = false;
  final exprLines = <String>[];
  for (final line in lines) {
    final connectM = RegExp(r'^connect\s*[:：]\s*(true|false)\s*$', caseSensitive: false).firstMatch(line);
    if (connectM != null) {
      connect = connectM.group(1)!.toLowerCase() == 'true';
      continue;
    }
    final pairM = RegExp(r'^pair\s*[:：]\s*(true|false)\s*$', caseSensitive: false).firstMatch(line);
    if (pairM != null) {
      pairFlag = pairM.group(1)!.toLowerCase() == 'true';
      continue;
    }
    final paramM = RegExp(r'^(?:param|parametric)\s*[:：]\s*(true|false)\s*$', caseSensitive: false).firstMatch(line);
    if (paramM != null) {
      paramFlag = paramM.group(1)!.toLowerCase() == 'true';
      continue;
    }
    final tM = RegExp(r'^t\s*[:：]\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*$').firstMatch(line);
    if (tM != null) {
      final a = double.tryParse(tM.group(1)!);
      final b = double.tryParse(tM.group(2)!);
      if (a != null && b != null && b > a) {
        tMin = a;
        tMax = b;
      }
      continue;
    }
    if (RegExp(r'^x\s*[:：]\s*').hasMatch(line)) {
      final m = RegExp(r'^x\s*[:：]\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*$').firstMatch(line);
      if (m != null) {
        final a = double.tryParse(m.group(1)!);
        final b = double.tryParse(m.group(2)!);
        if (a != null && b != null) {
          xMin = a;
          xMax = b;
        }
      }
      continue;
    }
    exprLines.add(line);
  }
  if (exprLines.isEmpty) return null;

  // 统一收集：局部变量 r/r1/m/k、参数方程 x/y 对、以及独立函数 y= 行。
  final localVars = <String, _ExprNode>{};
  final pairs = <List<String>>[];
  final functionLines = <String>[];
  String? pendingX;
  for (final line in exprLines) {
    final assign = RegExp(r'^([a-zA-Z_]\w*)\s*=\s*(.+)$').firstMatch(line);
    if (assign != null) {
      final name = assign.group(1)!;
      if (name == 'x') {
        pendingX = assign.group(2)!.trim();
        continue;
      }
      if (name == 'y') {
        final yExpr = assign.group(2)!.trim();
        if (pendingX != null) {
          pairs.add([pendingX, yExpr]);
          pendingX = null;
        } else {
          functionLines.add(line);
        }
        continue;
      }
      // y1/y2 这类是普通函数标签，不是局部变量。
      if (RegExp(r'^y\d+[a-zA-Z_]*$').hasMatch(name)) {
        functionLines.add(line);
        continue;
      }
      // 其它名字按局部变量保存，支持 r/r1/m/k 等。
      try {
        localVars[name] = _ExprParser(assign.group(2)!, vars: localVars).parse();
      } catch (_) {}
      continue;
    }
    functionLines.add(line);
  }
  // 末尾悬空的 x= 说明这块可能被截断：忽略它，让其他能解析的曲线继续画。
  pendingX = null;

  final useParam = paramFlag || pairs.isNotEmpty;
  final paramSeries = <_ParametricSeries>[];
  for (final p in pairs) {
    try {
      paramSeries.add(_ParametricSeries(
        x: _ExprParser(p[0], vars: localVars).parse(),
        y: _ExprParser(p[1], vars: localVars).parse(),
      ));
    } catch (_) {
      // 单条参数曲线写错时不拖垮整块图，先跳过，能画的继续画。
    }
  }
  if (useParam && paramSeries.isNotEmpty && functionLines.isEmpty) {
    return _ParsePlot(
      series: const [],
      xMin: xMin,
      xMax: xMax,
      connect: connect,
      parametric: true,
      paramSeries: paramSeries,
      tMin: tMin,
      tMax: tMax,
      usesU: exprLines.any((l) => RegExp(r'\b(?:u|phase)\b').hasMatch(l)),
    );
  }

  if (xMax <= xMin) return null;
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
  final series = <_FunctionSeries>[];
  for (var i = 0; i < functionLines.length; i++) {
    final raw = functionLines[i];
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
    try {
      final fn = _ExprParser(expr, vars: localVars).parse();
      final usesT = RegExp(r'(^|[^a-zA-Z_])t([^a-zA-Z_]|$)').hasMatch(expr);
      series.add(_FunctionSeries(
        label: label.isEmpty ? (series.length == 0 ? 'y' : 'y${series.length + 1}') : label,
        expr: expr,
        fn: fn,
        usesT: usesT,
        color: connect
            ? const Color(0xFF64B5F6)
            : pairFlag
                ? colors[series.length ~/ 2 % colors.length]
                : colors[series.length % colors.length],
        segmentXMin: segMin,
        segmentXMax: segMax,
      ));
    } catch (_) {
      // 单条函数写错时同样跳过，不影响同块里其他曲线。
    }
  }
  if (series.isEmpty && paramSeries.isEmpty) return null;
  return _ParsePlot(
    series: series,
    xMin: xMin,
    xMax: xMax,
    connect: connect,
    pair: pairFlag,
    parametric: paramSeries.isNotEmpty,
    paramSeries: paramSeries,
    tMin: tMin,
    tMax: tMax,
    usesU: exprLines.any((l) => RegExp(r'\b(?:u|phase)\b').hasMatch(l)),
  );
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

class _ParametricSeries {
  const _ParametricSeries({required this.x, required this.y});

  final _ExprNode x;
  final _ExprNode y;
}

class _ParsePlot {
  const _ParsePlot({
    required this.series,
    required this.xMin,
    required this.xMax,
    required this.connect,
    this.pair = false,
    this.parametric = false,
    this.paramSeries = const [],
    this.tMin = 0,
    this.tMax = 6.283185307179586,
    this.usesU = false,
  });

  final List<_FunctionSeries> series;

  bool get usesT => parametric
      ? false
      : series.any((s) => s.usesT);

  final double xMin;
  final double xMax;
  final bool connect;
  final bool pair;
  final bool parametric;

  /// 参数方程可以写多组 x/y，每一组是一条独立曲线，自动配色。
  final List<_ParametricSeries> paramSeries;
  final double tMin;
  final double tMax;

  /// 参数方程是否使用 `u`/`phase` 作为动态相位（旋转/呼吸等）。
  final bool usesU;
}
/// 简易表达式求值：支持 + - * / ^ ( ) 数字、x、t、pi/e，以及常见函数。
/// `t` 是动态时间变量，函数图会把它当作动画参数（0~2π 循环）。
abstract class _ExprNode {
  double eval(double x, double t, [double u = 0]);
}

class _NumberNode implements _ExprNode {
  _NumberNode(this.value);
  final double value;
  @override
  double eval(double x, double t, [double u = 0]) => value;
}

class _VarNode implements _ExprNode {
  @override
  double eval(double x, double t, [double u = 0]) => x;
}

class _TVarNode implements _ExprNode {
  @override
  double eval(double x, double t, [double u = 0]) => t;
}

class _UVarNode implements _ExprNode {
  @override
  double eval(double x, double t, [double u = 0]) => u;
}

class _UserVarNode implements _ExprNode {
  _UserVarNode(this.expr);
  final _ExprNode expr;
  @override
  double eval(double x, double t, [double u = 0]) => expr.eval(x, t, u);
}

class _BinaryNode implements _ExprNode {
  _BinaryNode(this.op, this.left, this.right);
  final String op;
  final _ExprNode left;
  final _ExprNode right;
  @override
  double eval(double x, double t, [double u = 0]) {
    final l = left.eval(x, t, u);
    final r = right.eval(x, t, u);
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
  double eval(double x, double t, [double u = 0]) => -child.eval(x, t, u);
}

class _FuncNode implements _ExprNode {
  _FuncNode(this.name, this.args);
  final String name;
  final List<_ExprNode> args;

  double _v(int i, double x, double t, double u) => args[i].eval(x, t, u);

  @override
  double eval(double x, double t, [double u = 0]) {
    try {
      switch (name) {
        case 'sin':
          return math.sin(_v(0, x, t, u));
        case 'cos':
          return math.cos(_v(0, x, t, u));
        case 'tan':
          return math.tan(_v(0, x, t, u));
        case 'asin':
          return math.asin(_v(0, x, t, u));
        case 'acos':
          return math.acos(_v(0, x, t, u));
        case 'atan':
          return math.atan(_v(0, x, t, u));
        case 'atan2':
          return math.atan2(_v(0, x, t, u), _v(1, x, t, u));
        case 'sinh':
          final v = _v(0, x, t, u);
          return (math.exp(v) - math.exp(-v)) / 2;
        case 'cosh':
          final v = _v(0, x, t, u);
          return (math.exp(v) + math.exp(-v)) / 2;
        case 'tanh':
          final v = _v(0, x, t, u);
          final e = math.exp(2 * v);
          return (e - 1) / (e + 1);
        case 'asinh':
          final v = _v(0, x, t, u);
          return math.log(v + math.sqrt(v * v + 1));
        case 'acosh':
          final v = _v(0, x, t, u);
          return v < 1 ? double.nan : math.log(v + math.sqrt(v * v - 1));
        case 'atanh':
          final v = _v(0, x, t, u);
          final a = 1 + v;
          final b = 1 - v;
          if (b <= 0) return double.nan;
          return 0.5 * math.log(a / b);
        case 'sec':
          return 1 / math.cos(_v(0, x, t, u));
        case 'csc':
          return 1 / math.sin(_v(0, x, t, u));
        case 'cot':
          return math.cos(_v(0, x, t, u)) / math.sin(_v(0, x, t, u));
        case 'sinc': {
          final v = _v(0, x, t, u);
          return v.abs() < 1e-12 ? 1 : math.sin(v) / v;
        }
        case 'hypot':
          return math.sqrt(_v(0, x, t, u) * _v(0, x, t, u) +
              _v(1, x, t, u) * _v(1, x, t, u));
        case 'gcd': {
          var a = _v(0, x, t, u).round();
          var b = _v(1, x, t, u).round();
          a = a.abs();
          b = b.abs();
          while (b != 0) {
            final r = a % b;
            a = b;
            b = r;
          }
          return a.toDouble();
        }
        case 'lcm': {
          final a = _v(0, x, t, u).round().abs();
          final b = _v(1, x, t, u).round().abs();
          if (a == 0 || b == 0) return 0;
          var p = a;
          var q = b;
          while (q != 0) {
            final r = p % q;
            p = q;
            q = r;
          }
          return (a / p * b).toDouble();
        }
        case 'frac':
          final v = _v(0, x, t, u);
          return v - v.floorToDouble();
        case 'trunc':
          return _v(0, x, t, u).truncateToDouble();
        case 'rad':
          return _v(0, x, t, u) * math.pi / 180;
        case 'deg':
          return _v(0, x, t, u) * 180 / math.pi;
        case 'smoothstep': {
          final e0 = _v(0, x, t, u);
          final e1 = _v(1, x, t, u);
          final v = ((_v(2, x, t, u) - e0) / (e1 - e0)).clamp(0.0, 1.0);
          return v * v * (3 - 2 * v);
        }
        case 'sqrt':
          final v = _v(0, x, t, u);
          return v < 0 ? double.nan : math.sqrt(v);
        case 'abs':
          return _v(0, x, t, u).abs();
        case 'exp':
          return math.exp(_v(0, x, t, u));
        case 'ln':
          final v = _v(0, x, t, u);
          return v <= 0 ? double.nan : math.log(v);
        case 'log2':
          final v = _v(0, x, t, u);
          return v <= 0 ? double.nan : math.log(v) / math.ln2;
        case 'log10':
          final v = _v(0, x, t, u);
          return v <= 0 ? double.nan : math.log(v) / math.ln10;
        case 'log':
          if (args.length == 2) {
            final v = _v(0, x, t, u);
            final base = _v(1, x, t, u);
            if (v <= 0 || base <= 0 || base == 1) return double.nan;
            return math.log(v) / math.log(base);
          }
          final v = _v(0, x, t, u);
          return v <= 0 ? double.nan : math.log(v);
        case 'min':
          return math.min(_v(0, x, t, u), _v(1, x, t, u));
        case 'max':
          return math.max(_v(0, x, t, u), _v(1, x, t, u));
        case 'pow':
          return math.pow(_v(0, x, t, u), _v(1, x, t, u)).toDouble();
        case 'mod':
          final a = _v(0, x, t, u);
          final b = _v(1, x, t, u);
          return b == 0 ? double.nan : a % b;
        case 'clamp':
          final v = _v(0, x, t, u);
          final lo = _v(1, x, t, u);
          final hi = _v(2, x, t, u);
          return v.clamp(lo, hi).toDouble();
        case 'floor':
          return _v(0, x, t, u).floorToDouble();
        case 'ceil':
          return _v(0, x, t, u).ceilToDouble();
        case 'round':
          return _v(0, x, t, u).roundToDouble();
        case 'sign':
          final v = _v(0, x, t, u);
          if (v > 0) return 1;
          if (v < 0) return -1;
          return 0;
      }
    } catch (_) {
      return double.nan;
    }
    return double.nan;
  }
}

class _ExprParser {
  _ExprParser(String input, {Map<String, _ExprNode>? vars})
      : _tokens = _tokenize(input),
        _pos = 0,
        _vars = vars ?? const {};

  final List<String> _tokens;
  final Map<String, _ExprNode> _vars;
  int _pos;

  static final RegExp _num = RegExp(r'^-?\d+(\.\d+)?([eE][+-]?\d+)?$');
  static final RegExp _id = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');
  static final Set<String> _functions = {
    'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'atan2',
    'sinh', 'cosh', 'tanh', 'asinh', 'acosh', 'atanh',
    'sec', 'csc', 'cot', 'sinc', 'hypot',
    'gcd', 'lcm', 'frac', 'trunc', 'rad', 'deg', 'smoothstep',
    'sqrt', 'abs', 'exp', 'ln', 'log', 'log2', 'log10',
    'min', 'max', 'pow', 'mod', 'clamp', 'floor', 'ceil', 'round', 'sign',
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
      if (token == 'u' || token == 'phase') return _UVarNode();
      if ((token == 'pi')) return _NumberNode(3.141592653589793);
      if (token == 'e') return _NumberNode(2.718281828459045);
      if (_vars.containsKey(token)) {
        return _UserVarNode(_vars[token]!);
      }
      if (_functions.contains(token)) {
        if (_pos >= _tokens.length || _tokens[_pos] != '(') {
          throw FormatException('function needs (');
        }
        _pos++;
        final args = <_ExprNode>[];
        while (true) {
          args.add(_parseExpr());
          if (_pos < _tokens.length && _tokens[_pos] == ',') {
            _pos++;
            continue;
          }
          break;
        }
        if (_pos >= _tokens.length || _tokens[_pos] != ')') {
          throw FormatException('missing )');
        }
        _pos++;
        return _FuncNode(token, args);
      }
      throw FormatException('unknown $token');
    }
    throw FormatException('bad token $token');
  }
}

const _paramCurveColors = [
  Color(0xFF64B5F6),
  Color(0xFFF48FB1),
  Color(0xFF81C784),
  Color(0xFFFFD54F),
  Color(0xFFBA68C8),
  Color(0xFF4DD0E1),
  Color(0xFFFF8A65),
  Color(0xFF9CCC65),
];

class _FunctionPainter extends CustomPainter {
  _FunctionPainter({
    required this.series,
    required this.xMin,
    required this.xMax,
    this.t = 0,
    this.progress = 1,
    this.connect = false,
    this.pair = false,
    this.parametric = false,
    this.paramSeries = const [],
    this.tMin = 0,
    this.tMax = 6.283185307179586,
    this.usesU = false,
    this.viewXMin,
    this.viewXMax,
    this.viewYMin,
    this.viewYMax,
    required this.gridColor,
    required this.axisColor,
  });

  final List<_FunctionSeries> series;
  final double xMin;
  final double xMax;
  final double t;
  final double progress;
  final bool connect;
  final bool pair;
  final bool parametric;
  final List<_ParametricSeries> paramSeries;
  final double tMin;
  final double tMax;

  /// 参数方程是否使用 `u`/`phase` 作为动态相位。
  final bool usesU;
  final double? viewXMin;
  final double? viewXMax;
  final double? viewYMin;
  final double? viewYMax;
  final Color gridColor;
  final Color axisColor;

  List<List<Offset>> _sampleParametric(double u) {
    final curves = <List<Offset>>[];
    const n = 800;
    final step = (tMax - tMin) / n;
    for (final ps in paramSeries) {
      final pts = <Offset>[];
      for (var i = 0; i <= n; i++) {
        final tt = tMin + step * i;
        final x = ps.x.eval(0, tt, u);
        final y = ps.y.eval(0, tt, u);
        if (x.isFinite && y.isFinite && x.abs() < 1e9 && y.abs() < 1e9) {
          pts.add(Offset(x, y));
        }
      }
      curves.add(pts);
    }
    return curves;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = Paint()..color = const Color(0xFF0B1220);
    canvas.drawRect(rect, bg);

    const sampleCount = 512;
    final pad = 8.0;
    late double axisXMin;
    late double axisXMax;
    late double axisYMin;
    late double axisYMax;
    List<List<Offset>>? paramPoints;

    if (paramSeries.isNotEmpty) {
      paramPoints = _sampleParametric(t);
      if (paramPoints.isEmpty || paramPoints.every((pts) => pts.isEmpty)) {
        final noData = Paint()
          ..color = const Color(0xFF5B6B82)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
        canvas.drawLine(
          Offset(0, size.height / 2),
          Offset(size.width, size.height / 2),
          noData,
        );
        return;
      }
    }
    if (paramPoints == null && series.isEmpty) return;

    if (viewXMin != null) {
      axisXMin = viewXMin!;
      axisXMax = viewXMax!;
      axisYMin = viewYMin!;
      axisYMax = viewYMax!;
    } else {
      final xs = <double>[];
      final ys = <double>[];
      for (final pts in paramPoints ?? const <List<Offset>>[]) {
        for (final p in pts) {
          xs.add(p.dx);
          ys.add(p.dy);
        }
      }
      if (series.isNotEmpty) {
        final dynamicMode = series.any((s) => s.usesT) || usesU;
        const rangeSampleCount = 256;
        final xSpan = xMax - xMin;
        if (xSpan > 0) {
          final rangeStep = xSpan / rangeSampleCount;
          if (dynamicMode) {
            const tSteps = 16;
            for (var ti = 0; ti <= tSteps; ti++) {
              final tt = 2 * math.pi * ti / tSteps;
              for (var i = 0; i <= rangeSampleCount; i++) {
                final x = xMin + rangeStep * i;
                for (final s in series) {
                  final v = s.fn.eval(x, tt, tt);
                  if (v.isFinite && v.abs() < 1e9) ys.add(v);
                }
              }
            }
          } else {
            for (var i = 0; i <= rangeSampleCount; i++) {
              final x = xMin + rangeStep * i;
              for (final s in series) {
                final v = s.fn.eval(x, t, t);
                if (v.isFinite && v.abs() < 1e9) ys.add(v);
              }
            }
          }
          xs.add(xMin);
          xs.add(xMax);
        }
      }
      if (xs.isEmpty || ys.isEmpty) {
        final noData = Paint()
          ..color = const Color(0xFF5B6B82)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
        canvas.drawLine(
          Offset(0, size.height / 2),
          Offset(size.width, size.height / 2),
          noData,
        );
        return;
      }
      xs.sort();
      ys.sort();
      axisXMin = xs.first;
      axisXMax = xs.last;
      axisYMin = ys.first;
      axisYMax = ys.last;
      if ((axisXMax - axisXMin).abs() < 0.5) {
        final c = (axisXMax + axisXMin) / 2;
        axisXMin = c - 1;
        axisXMax = c + 1;
      }
      if ((axisYMax - axisYMin).abs() < 0.5) {
        final c = (axisYMax + axisYMin) / 2;
        axisYMin = c - 1;
        axisYMax = c + 1;
      }
      final ySpan = axisYMax - axisYMin;
      axisYMin -= ySpan * 0.08;
      axisYMax += ySpan * 0.08;
    }

    double tx(double x) =>
        pad + (x - axisXMin) / (axisXMax - axisXMin) * (size.width - pad * 2);
    double ty(double y) =>
        pad + (axisYMax - y) / (axisYMax - axisYMin) * (size.height - pad * 2);

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.6;
    const gridCount = 8;
    for (var i = 0; i <= gridCount; i++) {
      final x = axisXMin + (axisXMax - axisXMin) * i / gridCount;
      canvas.drawLine(Offset(tx(x), pad), Offset(tx(x), size.height - pad), gridPaint);
    }
    for (var i = 0; i <= 6; i++) {
      final y = axisYMin + (axisYMax - axisYMin) * i / 6;
      canvas.drawLine(Offset(pad, ty(y)), Offset(size.width - pad, ty(y)), gridPaint);
    }

    final axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1.1;
    if (axisYMin <= 0 && axisYMax >= 0) {
      final y0px = ty(0);
      canvas.drawLine(Offset(pad, y0px), Offset(size.width - pad, y0px), axisPaint);
    }
    if (axisXMin <= 0 && axisXMax >= 0) {
      final x0px = tx(0);
      canvas.drawLine(Offset(x0px, pad), Offset(x0px, size.height - pad), axisPaint);
    }

    // 曲线裁剪在绘图区内，越界部分直接裁掉而不是压成平线
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(pad, pad, size.width - pad * 2, size.height - pad * 2),
    );
    if (paramSeries.isNotEmpty) {
      final curves = paramPoints!;
      for (var ci = 0; ci < curves.length; ci++) {
        final pts = curves[ci];
        if (pts.isEmpty) continue;
        final curve = Paint()
          ..color = _paramCurveColors[ci % _paramCurveColors.length]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round;
        final path = Path();
        final drawCount = (pts.length * progress).round();
        for (var i = 0; i <= drawCount && i < pts.length; i++) {
          final p = pts[i];
          final px = tx(p.dx);
          final py = ty(p.dy);
          if (i == 0) {
            path.moveTo(px, py);
          } else {
            path.lineTo(px, py);
          }
        }
        canvas.drawPath(path, curve);
      }
    }
    if (series.isNotEmpty) {
      final step = (xMax - xMin) / sampleCount;
      final totalConnectSamples = connect
          ? series.fold<int>(0, (sum, s) => sum + 257)
          : sampleCount;
      final drawLimit = (totalConnectSamples * progress).round();
      if (pair) {
        // 成对模式：每两条配成一层闭合轮廓，上边从左到右、下边从右到左
        for (var pi = 0; pi + 1 < series.length; pi += 2) {
          final s0 = series[pi];
          final s1 = series[pi + 1];
          final curve = Paint()
            ..color = s0.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round;
          final path = Path();
          var started = false;
          // 第一段：左 -> 右
          final seg0Min = s0.segmentXMin ?? xMin;
          final seg0Max = s0.segmentXMax ?? xMax;
          final seg0Step = (seg0Max - seg0Min) / sampleCount;
          for (var i = 0; i <= drawLimit; i++) {
            final x = seg0Min + seg0Step * i;
            final y = s0.fn.eval(x, t);
            final ok = y.isFinite && y.abs() < 1e9;
            if (!ok) {
              continue;
            }
            final px = tx(x);
            final py = ty(y);
            if (!started) {
              path.moveTo(px, py);
              started = true;
            } else {
              path.lineTo(px, py);
            }
          }
          // 第二段：右 -> 左（反向，形成闭合轮廓）
          final seg1Min = s1.segmentXMin ?? xMin;
          final seg1Max = s1.segmentXMax ?? xMax;
          final seg1Step = (seg1Max - seg1Min) / sampleCount;
          for (var i = drawLimit; i >= 0; i--) {
            final x = seg1Min + seg1Step * i;
            final y = s1.fn.eval(x, t);
            final ok = y.isFinite && y.abs() < 1e9;
            if (!ok) {
              continue;
            }
            final px = tx(x);
            final py = ty(y);
            if (!started) {
              path.moveTo(px, py);
              started = true;
            } else {
              path.lineTo(px, py);
            }
          }
          // 显式闭合左侧，避免出现“右边合上、左边留空”
          if (started) {
            path.close();
            canvas.drawPath(path, curve);
          }
        }
      } else if (connect) {
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
            final py = ty(y);
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
              path.moveTo(tx(x), ty(y));
              started = true;
            } else {
              path.lineTo(tx(x), ty(y));
            }
            lastFinite = true;
          }
          if (started) canvas.drawPath(path, curve);
        }
      }
    }

    canvas.restore();

    final labelPainter = TextPainter(
      text: TextSpan(
        text: '${axisYMin.toStringAsFixed(1)} ~ ${axisYMax.toStringAsFixed(1)}',
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
      oldDelegate.pair != pair ||
      oldDelegate.parametric != parametric ||
      oldDelegate.paramSeries != paramSeries ||
      oldDelegate.tMin != tMin ||
      oldDelegate.tMax != tMax ||
      oldDelegate.usesU != usesU ||
      oldDelegate.viewXMin != viewXMin ||
      oldDelegate.viewXMax != viewXMax ||
      oldDelegate.viewYMin != viewYMin ||
      oldDelegate.viewYMax != viewYMax ||
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
