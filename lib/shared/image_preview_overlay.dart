import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../features/ai/models/ai_message.dart';

/// 聊天图片的独立悬浮预览。
///
/// 不占用 Navigator 页面栈、不打断聊天，作为一层全屏浮层盖在当前界面上：
/// 支持双指/双击放大缩小、拖动平移，右上角 × 关闭。
class ImagePreviewOverlay extends StatefulWidget {
  const ImagePreviewOverlay({super.key, required this.image});

  final AiImageAttachment image;

  static Future<void> show(BuildContext context, AiImageAttachment image) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭图片预览',
      barrierColor: Colors.black.withValues(alpha: 0.82),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, __, ___) => ImagePreviewOverlay(image: image),
      transitionBuilder: (_, animation, __, child) => FadeTransition(
        opacity: animation,
        child: child,
      ),
    );
  }

  @override
  State<ImagePreviewOverlay> createState() => _ImagePreviewOverlayState();
}

class _ImagePreviewOverlayState extends State<ImagePreviewOverlay> {
  final _controller = TransformationController();
  bool _zoomed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Uint8List get _bytes {
    final comma = widget.image.dataUri.indexOf(',');
    final raw = comma >= 0
        ? widget.image.dataUri.substring(comma + 1)
        : widget.image.dataUri;
    try {
      return base64Decode(raw);
    } catch (_) {
      return Uint8List(0);
    }
  }

  void _toggleZoom(TapDownDetails details) {
    if (_controller.value.getMaxScaleOnAxis() > 1.05) {
      _controller.value = Matrix4.identity();
      _zoomed = false;
      return;
    }
    final p = details.localPosition;
    _controller.value = Matrix4.identity()
      ..translateByDouble(-p.dx * 1.5, -p.dy * 1.5, 0, 1)
      ..scaleByDouble(2.5, 2.5, 2.5, 1);
    _zoomed = true;
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onDoubleTapDown: _toggleZoom,
            onDoubleTap: () {},
            child: InteractiveViewer(
              transformationController: _controller,
              minScale: 0.5,
              maxScale: 8,
              child: Center(
                child: bytes.isEmpty
                    ? const Text(
                        '图片数据无效',
                        style: TextStyle(color: Colors.white70),
                      )
                    : Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        errorBuilder: (_, e, __) => Text(
                          '解码失败：$e',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 14,
          top: MediaQuery.paddingOf(context).top + 10,
          child: _FloatingButton(
            icon: _zoomed ? Icons.zoom_out_map : Icons.zoom_in_map,
            tooltip: _zoomed ? '还原缩放' : '双击图片也能缩放',
            onTap: () {
              _controller.value = Matrix4.identity();
              setState(() => _zoomed = false);
            },
          ),
        ),
        Positioned(
          right: 14,
          top: MediaQuery.paddingOf(context).top + 10,
          child: _FloatingButton(
            icon: Icons.close_rounded,
            tooltip: '关闭',
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
      ],
    );
  }
}

class _FloatingButton extends StatelessWidget {
  const _FloatingButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            child: Icon(icon, color: Colors.white, size: 21),
          ),
        ),
      ),
    );
  }
}
