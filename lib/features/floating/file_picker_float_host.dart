import 'package:flutter/material.dart';

import '../../shared/local_file_picker.dart';
import 'float_bounds_registry.dart';

/// 文件选择器悬浮窗宿主：常驻在 [AppFloatLayer] 中。
///
/// 以前 `LocalFilePicker.pick` 走 `showModalBottomSheet`，外部悬浮模式没有
/// Navigator，点附件没有任何反应；现在统一渲染成独立悬浮窗，APP 内外都能选。
class FilePickerFloatHost extends StatelessWidget {
  const FilePickerFloatHost({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FilePickerFloatRequest?>(
      valueListenable: FilePickerFloatController.instance.state,
      builder: (context, request, _) {
        if (request == null) return const SizedBox.shrink();
        return Stack(
          children: [
            _FilePickerWindow(
              key: request.key,
              request: request,
            ),
          ],
        );
      },
    );
  }
}

class _FilePickerWindow extends StatefulWidget {
  const _FilePickerWindow({super.key, required this.request});

  final FilePickerFloatRequest request;

  @override
  State<_FilePickerWindow> createState() => _FilePickerWindowState();
}

class _FilePickerWindowState extends State<_FilePickerWindow> {
  static const _boundsKey = 'file-picker';
  static const _minWidth = 280.0;
  static const _minHeight = 260.0;

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
    _width = (size.width * 0.92).clamp(_minWidth, size.width);
    _height = (size.height * 0.78).clamp(_minHeight, size.height - 100);
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
    _top = _top.clamp(padding.top, screen.height - _height - padding.bottom);
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xF0181C22),
            ),
            child: Column(
              children: [
                _buildHeader(context),
                Expanded(
                  child: LocalFilePicker(
                    mode: widget.request.mode,
                    maxChars: widget.request.maxChars,
                    title: widget.request.title,
                    extensionFilter: widget.request.extensionFilter,
                    onPicked: FilePickerFloatController.instance.complete,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) => setState(() {
        _left += d.delta.dx;
        _top += d.delta.dy;
      }),
      child: Container(
        height: 38,
        padding: const EdgeInsets.only(left: 12, right: 4),
        color: const Color(0xFF232A33),
        child: Row(
          children: [
            const Icon(Icons.drag_indicator_rounded,
                size: 18, color: Colors.white54),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.request.title ?? '选择文件',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              icon: const Icon(Icons.close_rounded, color: Colors.white70),
              onPressed: () => FilePickerFloatController.instance.complete(null),
            ),
          ],
        ),
      ),
    );
  }
}
