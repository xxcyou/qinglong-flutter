import 'package:flutter/material.dart';
import 'code_editor_page.dart';

/// 弹出可拖拽、可缩放、纯黑背景的悬浮代码编辑器。
///
/// 用一个透明遮罩的 Dialog 承载，窗口本身支持：
/// - 顶部拖动条移动窗口
/// - 右下角把手缩放
/// - 右上角 X 关闭
/// - 点击窗口任意位置把它保持在最前（Dialog 天然在最上层，不会跑到页面下面）
Future<void> showFloatingCodeEditor(
  BuildContext context, {
  required String path,
  required String initial,
  String subtitle = '',
  Future<bool> Function(String content)? onSave,
  Future<bool> Function()? onDelete,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭编辑器',
    barrierColor: Colors.black45,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, animation, secondaryAnimation) =>
        _FloatingEditorWindow(
      path: path,
      initial: initial,
      subtitle: subtitle,
      onSave: onSave,
      onDelete: onDelete,
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _FloatingEditorWindow extends StatefulWidget {
  const _FloatingEditorWindow({
    required this.path,
    required this.initial,
    required this.subtitle,
    this.onSave,
    this.onDelete,
  });

  final String path;
  final String initial;
  final String subtitle;
  final Future<bool> Function(String content)? onSave;
  final Future<bool> Function()? onDelete;

  @override
  State<_FloatingEditorWindow> createState() => _FloatingEditorWindowState();
}

class _FloatingEditorWindowState extends State<_FloatingEditorWindow> {
  static const double _minWidth = 260;
  static const double _minHeight = 220;

  late double _left;
  late double _top;
  late double _width;
  late double _height;

  @override
  void initState() {
    super.initState();
    final size = MediaQuery.sizeOf(context);
    _width = size.width * 0.92;
    _height = size.height * 0.86;
    _left = (size.width - _width) / 2;
    _top = (size.height - _height) / 2;
  }

  void _clampPosition(Size screen) {
    _left = _left.clamp(0.0, screen.width - _width);
    _top = _top.clamp(0.0, screen.height - _height);
    _width = _width.clamp(_minWidth, screen.width);
    _height = _height.clamp(_minHeight, screen.height);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    _clampPosition(screen);
    final scheme = Theme.of(context).colorScheme;
    final name = widget.path.split('/').last;

    return Stack(
      children: [
        // 点击空白也能关掉（可选）；窗口本身在最上层。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        Positioned(
          left: _left,
          top: _top,
          width: _width,
          height: _height,
          child: Material(
            color: Colors.transparent,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: const Color(0xFF0B0D10), // 纯黑底
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white24, width: 1),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x99000000),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // 顶部无边框拖动条
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (details) {
                      setState(() {
                        _left += details.delta.dx;
                        _top += details.delta.dy;
                        _clampPosition(screen);
                      });
                    },
                    child: Container(
                      height: 34,
                      color: const Color(0xFF15181D),
                      padding: const EdgeInsets.only(left: 12, right: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.code,
                            size: 15,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '关闭',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(
                              Icons.close,
                              size: 18,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  Expanded(
                    child: CodeEditorPage(
                      path: widget.path,
                      initial: widget.initial,
                      subtitle: widget.subtitle,
                      aiSource: 'file_manager',
                      onSave: widget.onSave,
                      onDelete: widget.onDelete,
                      showBack: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 右下角缩放把手
        Positioned(
          left: _left + _width - 20,
          top: _top + _height - 20,
          width: 20,
          height: 20,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) {
              setState(() {
                _width += details.delta.dx;
                _height += details.delta.dy;
                _width = _width.clamp(_minWidth, screen.width);
                _height = _height.clamp(_minHeight, screen.height);
              });
            },
            child: const Icon(
              Icons.open_in_full,
              size: 13,
              color: Colors.white38,
            ),
          ),
        ),
      ],
    );
  }
}
