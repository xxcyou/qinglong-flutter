import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 任务状态环形图。
///
/// 用一个环把「运行中 / 失败 / 已停用 / 正常」的比例画出来，中间写总数。
/// 比一行数字更容易一眼看出"这台面板有没有问题"。
class StatusDonut extends StatelessWidget {
  const StatusDonut({
    super.key,
    required this.segments,
    this.size = 52,
    this.thickness = 8,
    this.centerLabel = '',
    this.centerSub = '',
  });

  /// (数量, 颜色) 列表，顺序即绘制顺序。
  final List<(int, Color)> segments;
  final double size;
  final double thickness;
  final String centerLabel;
  final String centerSub;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = segments.fold<int>(0, (sum, s) => sum + s.$1);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DonutPainter(
          segments: segments,
          thickness: thickness,
          total: total,
          trackColor: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                centerLabel.isEmpty ? '$total' : centerLabel,
                style: TextStyle(
                  fontSize: size * 0.3,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
              if (centerSub.isNotEmpty)
                Text(
                  centerSub,
                  style: TextStyle(
                    fontSize: size * 0.17,
                    color: scheme.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.segments,
    required this.thickness,
    required this.total,
    required this.trackColor,
  });

  final List<(int, Color)> segments;
  final double thickness;
  final int total;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      thickness / 2,
      thickness / 2,
      size.width - thickness,
      size.height - thickness,
    );
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..color = trackColor;
    canvas.drawArc(rect, 0, math.pi * 2, false, track);
    if (total <= 0) return;

    // 从 12 点开始顺时针画，留一点间隙让相邻扇区分得清。
    var start = -math.pi / 2;
    const gap = 0.03;
    for (final (count, color) in segments) {
      if (count <= 0) continue;
      final sweep = math.pi * 2 * (count / total);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness
        ..strokeCap = StrokeCap.butt
        ..color = color;
      canvas.drawArc(
        rect,
        start + gap / 2,
        math.max(sweep - gap, 0.02),
        false,
        paint,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.total != total ||
      old.thickness != thickness ||
      old.segments.length != segments.length ||
      !_sameSegments(old.segments, segments);

  bool _sameSegments(List<(int, Color)> a, List<(int, Color)> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].$1 != b[i].$1 || a[i].$2 != b[i].$2) return false;
    }
    return true;
  }
}

/// 图例里的一个小点 + 文字。
class DonutLegend extends StatelessWidget {
  const DonutLegend({
    super.key,
    required this.color,
    required this.label,
    required this.count,
  });

  final Color color;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          '$label $count',
          style: TextStyle(
            fontSize: 11.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
