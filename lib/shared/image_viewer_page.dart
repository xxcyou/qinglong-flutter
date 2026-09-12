import 'dart:io';

import 'package:flutter/material.dart';

import '../core/theme/glass.dart';
import 'file_kinds.dart';
import 'glass_scaffold.dart';

/// 内置图片查看器。
///
/// 文件管理器里点开一张图不该跳出 APP：跳出去再回来，当前目录、选中状态、
/// 面板高度全丢了。这里就地开一页，支持双指缩放、双击放大、拖动平移。
/// 真正需要外部 APP 的是压缩包、APK、PDF 这类我们不打算内建的格式。
class ImageViewerPage extends StatefulWidget {
  ImageViewerPage({
    super.key,
    this.hostPath,
    this.hostPaths = const [],
    this.initialIndex = 0,
    required this.title,
    this.subtitle,
    this.onOpenExternal,
  }) : assert(hostPath != null || hostPaths.isNotEmpty, '至少需要一个图片路径');

  /// 兼容单图：宿主真实路径。
  final String? hostPath;

  /// 多图列表：文件管理器把当前目录所有图片传进来，支持左右滑切换。
  final List<String> hostPaths;

  /// 打开时落在第几张。
  final int initialIndex;

  final String title;
  final String? subtitle;

  /// "用其它 APP 打开"，为 null 则不显示这个按钮。
  final VoidCallback? onOpenExternal;

  List<String> get paths => hostPaths.isNotEmpty ? hostPaths : [hostPath!];

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  final _pageController = PageController();
  int _pageIndex = 0;

  /// 图片本身的像素尺寸，取到后显示在副标题里。
  int? _width;
  int? _height;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _pageIndex = widget.initialIndex.clamp(0, widget.paths.length - 1);
    if (_pageIndex != widget.initialIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(_pageIndex);
        }
      });
    }
    _resolveSize();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  String get _currentHost => widget.paths[_pageIndex];

  String get _currentName {
    final p = _currentHost.replaceAll('\\', '/');
    return p.substring(p.lastIndexOf('/') + 1);
  }

  Future<void> _resolveSize() async {
    setState(() {
      _width = null;
      _height = null;
      _error = null;
    });
    try {
      final file = File(_currentHost);
      if (!file.existsSync()) {
        if (mounted) setState(() => _error = '文件不存在');
        return;
      }
      final stream = Image.file(file).image.resolve(
            const ImageConfiguration(),
          );
      final completer = stream;
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          if (mounted) {
            setState(() {
              _width = info.image.width;
              _height = info.image.height;
            });
          }
          completer.removeListener(listener);
        },
        onError: (error, _) {
          if (mounted) setState(() => _error = error);
          completer.removeListener(listener);
        },
      );
      completer.addListener(listener);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = _width != null && _height != null ? '$_width×$_height' : null;
    final total = widget.paths.length;
    final subtitleParts = [
      if (total > 1) '${_pageIndex + 1}/$total',
      if (size != null) size,
      if (widget.subtitle != null) widget.subtitle!,
    ];
    return GlassScaffold(
      title: _currentName,
      subtitle: subtitleParts.join(' · '),
      bodyTopPadding: 0,
      actions: [
        IconButton(
          tooltip: '还原缩放',
          onPressed: () => _pageKey.currentState?.reset(),
          icon: const Icon(Icons.zoom_out_map),
        ),
        if (widget.onOpenExternal != null)
          IconButton(
            tooltip: '用其它 APP 打开',
            onPressed: widget.onOpenExternal,
            icon: const Icon(Icons.open_in_new),
          ),
      ],
      body: Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ColoredBox(
            // 看图要暗底：玻璃背景透出来的花纹会干扰对图片本身的判断。
            color: const Color(0xFF101014),
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '这张图打不开：$_error',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  )
                : PageView.builder(
                    controller: _pageController,
                    itemCount: total,
                    onPageChanged: (i) {
                      setState(() => _pageIndex = i);
                      _resolveSize();
                    },
                    itemBuilder: (context, index) => _ZoomableImage(
                      key: index == _pageIndex ? _pageKey : null,
                      hostPath: widget.paths[index],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  final _pageKey = GlobalKey<_ZoomableImageState>();
}

/// 可缩放/双击放大的单张图片。
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({super.key, required this.hostPath});

  final String hostPath;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final _controller = TransformationController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void reset() {
    _controller.value = Matrix4.identity();
  }

  void _toggleZoom(TapDownDetails details) {
    final current = _controller.value.getMaxScaleOnAxis();
    if (current > 1.05) {
      _controller.value = Matrix4.identity();
      return;
    }
    final position = details.localPosition;
    _controller.value = Matrix4.identity()
      ..translateByDouble(-position.dx * 1.5, -position.dy * 1.5, 0, 1)
      ..scaleByDouble(2.5, 2.5, 2.5, 1);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: _toggleZoom,
      onDoubleTap: () {},
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 0.5,
        maxScale: 8,
        child: Center(
          child: Image.file(
            File(widget.hostPath),
            fit: BoxFit.contain,
            errorBuilder: (_, error, __) => Center(
              child: Text(
                '解码失败：$error',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 非文本、非图片的文件：给一张信息卡 + "用其它 APP 打开"。
///
/// 直接把二进制丢进代码编辑器会得到一屏乱码，还可能因为几十 MB 的内容卡死 UI，
/// 所以这类文件到这里为止，交给系统里专门的 APP。
class BinaryFileSheet extends StatelessWidget {
  const BinaryFileSheet({
    super.key,
    required this.name,
    required this.kind,
    required this.sizeText,
    required this.dateText,
    required this.onOpenExternal,
    required this.onShare,
    this.onForceText,
  });

  final String name;
  final FileKind kind;
  final String sizeText;
  final String dateText;
  final VoidCallback onOpenExternal;
  final VoidCallback onShare;

  /// 硬要当文本打开（用户明确知道自己在干什么时）。
  final VoidCallback? onForceText;

  static Future<void> show(
    BuildContext context, {
    required String name,
    required FileKind kind,
    required String sizeText,
    required String dateText,
    required VoidCallback onOpenExternal,
    required VoidCallback onShare,
    VoidCallback? onForceText,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => BinaryFileSheet(
        name: name,
        kind: kind,
        sizeText: sizeText,
        dateText: dateText,
        onOpenExternal: onOpenExternal,
        onShare: onShare,
        onForceText: onForceText,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassPanel(
      radius: 22,
      blur: Glass.blurStrong,
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: kind.color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(kind.icon, color: kind.color, size: 23),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${kind.label} · $sizeText · $dateText',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '这是${kind.label}，APP 内没有对应的查看器。'
              '可以交给手机上专门的 APP 打开，或者分享出去。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onOpenExternal();
                    },
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('用其它 APP 打开'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: '分享',
                  onPressed: () {
                    Navigator.of(context).pop();
                    onShare();
                  },
                  icon: const Icon(Icons.ios_share, size: 19),
                ),
              ],
            ),
            if (onForceText != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    onForceText!();
                  },
                  icon: const Icon(Icons.text_snippet_outlined, size: 17),
                  label: const Text(
                    '仍然当文本打开',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
