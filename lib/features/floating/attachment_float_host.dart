import 'package:flutter/material.dart';

import '../../shared/image_preview_overlay.dart';
import '../../shared/image_preview_overlay_controller.dart';
import 'float_bounds_registry.dart';

/// 图片/附件预览悬浮窗宿主：常驻在 [AppFloatLayer] 中。
///
/// 以前 `ImagePreviewOverlay.show` 走 `showGeneralDialog`，外部悬浮模式没有
/// Navigator，点附件没反应；现在改成注册到这层，和终端/浏览器一样是独立
/// 悬浮窗，可拖动、可缩放、可关闭，并自动纳入原生覆盖窗口的 bounds。
class AttachmentFloatHost extends StatelessWidget {
  const AttachmentFloatHost({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AttachmentPreviewState?>(
      valueListenable: AttachmentPreviewController.instance.state,
      builder: (context, state, _) {
        if (state == null) return const SizedBox.shrink();
        return _AttachmentWindow(
          key: state.key,
          state: state,
        );
      },
    );
  }
}

class _AttachmentWindow extends StatefulWidget {
  const _AttachmentWindow({super.key, required this.state});

  final AttachmentPreviewState state;

  @override
  State<_AttachmentWindow> createState() => _AttachmentWindowState();
}

class _AttachmentWindowState extends State<_AttachmentWindow> {
  static const _boundsKey = 'attachment-preview';
  static const _minWidth = 220.0;
  static const _minHeight = 180.0;

  late double _left;
  late double _top;
  late double _width;
  late double _height;
  bool _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    final size = MediaQuery.sizeOf(context);
    _width = (size.width * 0.82).clamp(_minWidth, size.width - 16);
    _height = (size.height * 0.7).clamp(_minHeight, size.height - 120);
    _left = (size.width - _width) / 2;
    _top = (size.height - _height) / 2;
    _ready = true;
  }

  @override
  void dispose() {
    FloatBoundsRegistry.remove(_boundsKey);
    super.dispose();
  }

  void _clamp(Size screen, EdgeInsets padding) {
    _width = _width.clamp(_minWidth, screen.width);
    _height = _height.clamp(_minHeight, screen.height - padding.vertical);
    _left = _left.clamp(0.0, screen.width - _width);
    _top = _top.clamp(
      padding.top,
      screen.height - _height - padding.bottom,
    );
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    _clamp(screen, padding);
    FloatBoundsRegistry.report(
      _boundsKey,
      Rect.fromLTWH(_left, _top, _width, _height),
    );
    return Positioned(
      left: _left,
      top: _top,
      width: _width,
      height: _height,
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ColoredBox(
                  color: const Color(0xF0101318),
                  child: ImagePreviewOverlay(
                    image: widget.state.image!,
                    networkUrl: widget.state.networkUrl,
                    onClose: AttachmentPreviewController.instance.close,
                  ),
                ),
              ),
            ),
            // 左上角拖动条：避开图片预览自带的右上角关闭/缩放按钮。
            Positioned(
              left: 0,
              top: 0,
              width: 52,
              height: 26,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanUpdate: (d) => setState(() {
                  _left += d.delta.dx;
                  _top += d.delta.dy;
                }),
                child: const ColoredBox(
                  color: Colors.transparent,
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    size: 18,
                    color: Colors.white38,
                  ),
                ),
              ),
            ),
            // 右下角缩放手柄。
            Positioned(
              right: 0,
              bottom: 0,
              width: 30,
              height: 30,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanUpdate: (d) => setState(() {
                  _width = (_width + d.delta.dx).clamp(_minWidth, screen.width);
                  _height = (_height + d.delta.dy)
                      .clamp(_minHeight, screen.height - padding.vertical);
                }),
                child: const Icon(
                  Icons.south_east_rounded,
                  size: 16,
                  color: Colors.white38,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
