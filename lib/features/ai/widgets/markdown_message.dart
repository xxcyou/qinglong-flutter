import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    return MarkdownBody(
      data: text,
      selectable: selectable,
      extensionSet: enhancedExtensionSet,
      builders: {
        'u': _UnderlineBuilder(),
        'mark': _GlowBuilder(),
        'span': _ColorSpanBuilder(),
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
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant),
        ),
        codeblockPadding: const EdgeInsets.all(10),
        blockquoteDecoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.55),
          border: Border(left: BorderSide(color: scheme.primary, width: 3)),
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
