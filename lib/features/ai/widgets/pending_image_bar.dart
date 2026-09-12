import 'dart:convert';
import 'package:flutter/material.dart';

import '../../../shared/image_preview_overlay.dart';
import '../models/ai_message.dart';

/// 输入框上方待发送的图片条。
///
/// 显示缩略图，点缩略图放大预览，点右上角 × 从待发列表里撤下。
class PendingImageBar extends StatelessWidget {
  const PendingImageBar({
    super.key,
    required this.images,
    required this.onRemove,
    this.margin,
  });

  final List<AiImageAttachment> images;
  final ValueChanged<int> onRemove;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: margin ?? const EdgeInsets.fromLTRB(14, 0, 14, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < images.length; i++)
              _Thumb(
                image: images[i],
                onTap: () => ImagePreviewOverlay.show(context, images[i]),
                onRemove: () => onRemove(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.image,
    required this.onTap,
    required this.onRemove,
  });

  final AiImageAttachment image;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = base64Decode(
      image.dataUri.contains(',')
          ? image.dataUri.substring(image.dataUri.indexOf(',') + 1)
          : image.dataUri,
    );
    return Stack(
      children: [
        GestureDetector(
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 58,
              height: 58,
              child: bytes.isEmpty
                  ? ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: const Icon(Icons.broken_image_outlined),
                    )
                  : Image.memory(
                      bytes,
                      width: 58,
                      height: 58,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: const Icon(Icons.broken_image_outlined),
                      ),
                    ),
            ),
          ),
        ),
        Positioned(
          right: -4,
          top: -4,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.72),
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface),
              ),
              child: Icon(
                Icons.close_rounded,
                size: 13,
                color: scheme.surface,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
