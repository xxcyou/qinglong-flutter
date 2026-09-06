import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 一块"要消散掉的东西"：它当时的样子（截图）+ 它当时在屏幕上的位置。
@immutable
class DissolvePiece {
  const DissolvePiece(this.image, this.rect);

  final ui.Image image;

  /// 屏幕坐标（逻辑像素）。Navigator 的 Overlay 铺满全屏且原点在 (0,0)，
  /// 所以这个矩形可以直接拿去画。
  final Rect rect;
}

/// 把这些部件当下的画面抓下来。
///
/// 只抓已经在屏幕上、并且已经画过一帧的：ListView 没构建到的条目（滑出视口）
/// 拿不到 RenderObject，直接跳过——反正用户也看不见它消散。
///
/// 调用方必须在**删数据之前**调用它，抓完再删。
Future<List<DissolvePiece>> captureDissolvePieces(
  Iterable<GlobalKey> keys, {
  double pixelRatio = 1.5,
}) async {
  // 等这一帧画完再抓。toImage 在 debug 下会断言"不能有待重绘的内容"，
  // 而点按往往伴随着一次重建（比如刚关掉确认弹窗）。
  await WidgetsBinding.instance.endOfFrame;
  final pieces = <DissolvePiece>[];
  for (final key in keys) {
    // 只从 key 取 RenderObject，不碰 BuildContext 的其他能力，
    // 所以跨 await 用它是安全的（部件没了 currentContext 就是 null）。
    final object = key.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) continue;
    if (!object.attached || object.debugNeedsPaint) continue;
    final size = object.size;
    if (size.isEmpty) continue;
    try {
      final image = await object.toImage(pixelRatio: pixelRatio);
      pieces
          .add(DissolvePiece(image, object.localToGlobal(Offset.zero) & size));
    } catch (_) {
      // 抓不到就算了：动画是锦上添花，不能因为它把撤回搞失败。
    }
  }
  return pieces;
}

/// 播放粒子消散。调用后立刻返回，动画自己在 Overlay 上跑完并清理。
///
/// [clip] 用来把粒子关在列表区域里，不让它们飘到标题栏和输入框上面。
void playDissolve(
  BuildContext context,
  List<DissolvePiece> pieces, {
  Rect? clip,
  Duration duration = const Duration(milliseconds: 760),
}) {
  if (pieces.isEmpty) return;
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) {
    for (final piece in pieces) {
      piece.image.dispose();
    }
    return;
  }
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _DissolveLayer(
      pieces: pieces,
      clip: clip,
      duration: duration,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _DissolveLayer extends StatefulWidget {
  const _DissolveLayer({
    required this.pieces,
    required this.duration,
    required this.onDone,
    this.clip,
  });

  final List<DissolvePiece> pieces;
  final Rect? clip;
  final Duration duration;
  final VoidCallback onDone;

  @override
  State<_DissolveLayer> createState() => _DissolveLayerState();
}

class _DissolveLayerState extends State<_DissolveLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone();
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    // 图片只在这里释放：无论是自然播完还是页面被弹掉，都会走到这。
    for (final piece in widget.pieces) {
      piece.image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      // 粒子只是"尸体"，不能挡住底下真正的界面。
      child: IgnorePointer(
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              painter: _DissolvePainter(
                pieces: widget.pieces,
                t: _controller.value,
                clip: widget.clip,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DissolvePainter extends CustomPainter {
  _DissolvePainter({required this.pieces, required this.t, this.clip});

  final List<DissolvePiece> pieces;
  final double t;
  final Rect? clip;

  /// 每帧最多画这么多小块。粒子数越多越细腻，但这是每帧几百次
  /// drawImageRect，切太碎会掉帧——掉帧的消散比不消散更难看。
  static const _cellBudget = 430;

  @override
  void paint(Canvas canvas, Size size) {
    final region = clip;
    if (region != null) {
      canvas.save();
      canvas.clipRect(region);
    }
    final budget = (_cellBudget / pieces.length).clamp(24.0, 260.0);
    final paint = Paint()..filterQuality = FilterQuality.low;
    for (var index = 0; index < pieces.length; index++) {
      _paintPiece(canvas, pieces[index], index, budget, paint);
    }
    if (region != null) canvas.restore();
  }

  void _paintPiece(
    Canvas canvas,
    DissolvePiece piece,
    int pieceIndex,
    double budget,
    Paint paint,
  ) {
    final rect = piece.rect;
    final image = piece.image;
    // 按面积均分预算，反推小块边长。
    final side = math.sqrt(rect.width * rect.height / budget).clamp(16.0, 70.0);
    final cols = math.max(2, (rect.width / side).round());
    final rows = math.max(2, (rect.height / side).round());
    final cw = rect.width / cols;
    final ch = rect.height / rows;
    final sw = image.width / cols;
    final sh = image.height / rows;
    final center = rect.center;
    final diagonal = math.max(rect.longestSide, 1.0);

    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final seed = pieceIndex * 7919 + row * 131 + col;
        final r1 = _rand(seed);
        final r2 = _rand(seed + 1);
        final r3 = _rand(seed + 2);

        // 起飞时间错开：整体从左下往右上扫过去，再加一点随机，
        // 免得看起来像一堵墙整齐地飞走。
        final sweep = (col / cols) * 0.55 + (1 - row / rows) * 0.45;
        final delay = (sweep * 0.42 + r1 * 0.12).clamp(0.0, 0.6);
        final raw = ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
        if (raw <= 0) {
          // 还没轮到它：原样画着，看起来就是"还没散到这里"。
          _drawCell(canvas, image, paint, rect, col, row, cw, ch, sw, sh, 1);
          continue;
        }
        if (raw >= 1) continue;

        final ease = Curves.easeOutCubic.transform(raw);
        final cellCenter = Offset(
          rect.left + (col + 0.5) * cw,
          rect.top + (row + 0.5) * ch,
        );
        // 往外炸开：离中心越远的块飞得越远，看着像被撕开的。
        final away = (cellCenter - center) / diagonal;
        final dx = away.dx * 120 * ease + (r2 - 0.5) * 34 * ease;
        // 先微微上浮再落下：纯往下像掉渣，纯往上像烟，两者混着最像"消散"。
        final dy = away.dy * 40 * ease - 26 * ease + 74 * ease * ease;
        final scale = 1 - 0.6 * ease;
        final spin = (r3 - 0.5) * 1.5 * ease;
        final alpha = (1 - raw * raw).clamp(0.0, 1.0);

        canvas.save();
        canvas.translate(cellCenter.dx + dx, cellCenter.dy + dy);
        canvas.rotate(spin);
        canvas.scale(scale);
        canvas.translate(-cellCenter.dx, -cellCenter.dy);
        _drawCell(canvas, image, paint, rect, col, row, cw, ch, sw, sh, alpha);
        canvas.restore();
      }
    }
  }

  void _drawCell(
    Canvas canvas,
    ui.Image image,
    Paint paint,
    Rect rect,
    int col,
    int row,
    double cw,
    double ch,
    double sw,
    double sh,
    double alpha,
  ) {
    paint.color = Color.fromRGBO(255, 255, 255, alpha);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(col * sw, row * sh, sw, sh),
      Rect.fromLTWH(rect.left + col * cw, rect.top + row * ch, cw, ch),
      paint,
    );
  }

  /// 便宜的确定性随机：同一块每帧必须拿到同一个方向，
  /// 否则粒子会在原地乱抖。
  static double _rand(int seed) {
    var x = seed * 1103515245 + 12345;
    x ^= x >> 13;
    return (x.abs() % 10007) / 10007;
  }

  @override
  bool shouldRepaint(_DissolvePainter old) =>
      old.t != t || old.pieces != pieces || old.clip != clip;
}
