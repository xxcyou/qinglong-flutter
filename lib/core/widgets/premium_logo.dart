import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 高档 Logo：深空渐变底 + 流光圆环 + “Q”尾点，带轻微呼吸/旋转渐变。
///
/// 不依赖图片资源，放大缩小都不糊；[animation] 复用启动淡入淡出 Controller，
/// 静态场景直接传 [progress] = 1.0 即可。
class PremiumLogo extends StatelessWidget {
  const PremiumLogo({
    super.key,
    this.animation,
    this.progress = 1.0,
    this.size = 96,
  });

  final Animation<double>? animation;
  final double progress;
  final double size;

  @override
  Widget build(BuildContext context) {
    final anim = animation;
    if (anim == null) {
      return _LogoBody(progress: progress, size: size);
    }
    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) {
        final t = anim.value.clamp(0.0, 1.0);
        return _LogoBody(progress: t, size: size);
      },
    );
  }
}

class _LogoBody extends StatelessWidget {
  const _LogoBody({required this.progress, required this.size});

  final double progress;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scale = 0.92 + progress.clamp(0.0, 1.0) * 0.08;
    return Transform.scale(
      scale: scale,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.083),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.29),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF1C2A4A),
              Color(0xFF0C1226),
              Color(0xFF071120),
            ],
          ),
          border: Border.all(
            color: const Color(0xFFFFFFFF).withValues(alpha: 0.14),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00D4FF).withValues(alpha: 0.18),
              blurRadius: 32,
              spreadRadius: 2,
            ),
            const BoxShadow(
              color: Color(0x55000000),
              blurRadius: 24,
              offset: Offset(0, 14),
            ),
          ],
        ),
        child: CustomPaint(
          painter: _PremiumLogoPainter(progress: progress),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _PremiumLogoPainter extends CustomPainter {
  const _PremiumLogoPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 - 2);
    final radius = size.width * 0.24;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 流光圆环。
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: progress * 2 * math.pi,
        colors: const [
          Color(0xFF00E5FF),
          Color(0xFF4C6FFF),
          Color(0xFFB16CFF),
          Color(0xFF00E5FF),
        ],
      ).createShader(rect.inflate(12));
    canvas.drawCircle(center, radius, ringPaint);

    // Q 的尾巴：从圆环右下角向外甩出。
    final tail = Path()
      ..moveTo(center.dx + radius * 0.78, center.dy + radius * 0.72)
      ..quadraticBezierTo(
        center.dx + radius * 1.25,
        center.dy + radius * 0.95,
        center.dx + radius * 1.32,
        center.dy + radius * 1.38,
      )
      ..lineTo(center.dx + radius * 1.18, center.dy + radius * 1.22);
    canvas.drawPath(tail, ringPaint..strokeWidth = 5);

    // 尾点高光。
    final dot = Offset(
      center.dx + radius * 1.32,
      center.dy + radius * 1.38,
    );
    canvas.drawCircle(
      dot,
      3.4,
      Paint()
        ..style = PaintingStyle.fill
        ..color = const Color(0xFF7DF9FF),
    );
    canvas.drawCircle(
      dot,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFF7DF9FF).withValues(alpha: 0.35),
    );

    // 内部细高光描边，增加“玻璃感”。
    final inner = RRect.fromRectAndRadius(
      Rect.fromLTWH(1.5, 1.5, size.width - 3, size.height - 3),
      Radius.circular(24),
    );
    canvas.drawRRect(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.08),
    );
  }

  @override
  bool shouldRepaint(_PremiumLogoPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
