import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

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
  });

  final String text;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: textColor,
          height: 1.45,
        );
    return MarkdownBody(
      data: text,
      selectable: true,
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
