import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 高档 Logo：深空渐变底 + 流光圆环 + “Q”尾点。
///
/// [animation] 驱动入场进度（0→1）：缩放回弹、轻微旋转、圆环扫入、光晕呼吸；
/// 同时内部还有一条循环流光特效（shimmer / 旋转高光 / 微粒），
/// 只在 [animation] 非空（启动页/加载态）时启用，静态场景保持干净。
class PremiumLogo extends StatefulWidget {
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
  State<PremiumLogo> createState() => _PremiumLogoState();
}

class _PremiumLogoState extends State<PremiumLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fx;

  @override
  void initState() {
    super.initState();
    _fx = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    if (widget.animation != null) {
      _fx.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant PremiumLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animation != null && oldWidget.animation == null) {
      _fx.repeat();
    } else if (widget.animation == null && oldWidget.animation != null) {
      _fx.stop();
      _fx.value = 0;
    }
  }

  @override
  void dispose() {
    _fx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final anim = widget.animation;
    if (anim == null) {
      return _LogoBody(progress: widget.progress, size: widget.size);
    }
    return AnimatedBuilder(
      animation: Listenable.merge([anim, _fx]),
      builder: (context, _) {
        final t = anim.value.clamp(0.0, 1.0);
        return _LogoBody(
          progress: t,
          size: widget.size,
          fx: _fx.value,
        );
      },
    );
  }
}

class _LogoBody extends StatelessWidget {
  const _LogoBody({
    required this.progress,
    required this.size,
    this.fx = 0.0,
  });

  final double progress;
  final double size;
  final double fx;

  @override
  Widget build(BuildContext context) {
    // 入场：从 0.7 弹性放大到 1.0，带一点过冲。
    final entrance = Curves.elasticOut.transform(progress.clamp(0.0, 1.0));
    final scale = 0.7 + entrance * 0.34;
    // 入场时从左侧微微旋转回正。
    final rotation = (1 - Curves.easeOutBack.transform(progress.clamp(0.0, 1.0))) * -0.09;
    // 光晕呼吸：入场时增强，之后随 fx 脉动。
    final glowPulse = 0.10 + 0.14 * progress + 0.09 * (0.5 + 0.5 * math.sin(fx * 2 * math.pi));
    final borderGlow = 0.10 + 0.12 * progress + 0.06 * (0.5 + 0.5 * math.cos(fx * 2 * math.pi));

    return Transform.rotate(
      angle: rotation,
      child: Transform.scale(
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
              color: const Color(0xFFFFFFFF).withValues(alpha: borderGlow.clamp(0.0, 1.0)),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00D4FF).withValues(alpha: glowPulse.clamp(0.0, 0.55)),
                blurRadius: 28 + 24 * (0.5 + 0.5 * math.sin(fx * 2 * math.pi + 0.6)),
                spreadRadius: 1 + 3 * progress,
              ),
              BoxShadow(
                color: const Color(0xFFB16CFF).withValues(alpha: 0.08 + 0.10 * (0.5 + 0.5 * math.cos(fx * 2 * math.pi + 1.2))),
                blurRadius: 40,
                spreadRadius: -2,
              ),
              const BoxShadow(
                color: Color(0x55000000),
                blurRadius: 24,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(size * 0.22),
            child: Stack(
              children: [
                const Positioned.fill(
                  child: CustomPaint(
                    painter: _TransferGlowPainter(),
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _PremiumLogoPainter(progress: progress, fx: fx),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 玻璃内部的大范围渐变光晕（独立静态层，垫在 Logo 底下）。
class _TransferGlowPainter extends CustomPainter {
  const _TransferGlowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.3, -0.4),
        radius: 1.2,
        colors: [
          Color(0x3326C6FF),
          Color(0x0D4C6FFF),
          Color(0x0000E5FF),
        ],
        stops: [0.0, 0.45, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_TransferGlowPainter oldDelegate) => false;
}

class _PremiumLogoPainter extends CustomPainter {
  const _PremiumLogoPainter({required this.progress, required this.fx});

  final double progress;
  final double fx;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 - 2);
    final radius = size.width * 0.24;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 圆环流光：入场时从 0° 扫入，之后持续旋转。
    final sweepStart = progress * 0.6 * math.pi + fx * 2 * math.pi;
    final sweepSweep = math.pi * 1.45 + progress * math.pi * 0.55;
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: sweepStart,
        endAngle: sweepStart + sweepSweep,
        colors: const [
          Color(0xFF00E5FF),
          Color(0xFF4C6FFF),
          Color(0xFFB16CFF),
          Color(0xFF00E5FF),
        ],
      ).createShader(rect.inflate(12));
    canvas.drawCircle(center, radius, ringPaint);

    // 圆环速度残影：一根更淡的尾迹，让旋转更有“流光”感。
    final trailPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: sweepStart - 1.0,
        endAngle: sweepStart - 0.35,
        colors: [
          const Color(0xFF00E5FF).withValues(alpha: 0.0),
          const Color(0xFF7DF9FF).withValues(alpha: 0.22),
          const Color(0xFF00E5FF).withValues(alpha: 0.0),
        ],
      ).createShader(rect.inflate(12));
    canvas.drawCircle(center, radius, trailPaint);

    // Q 的尾巴：从圆环右下角向外甩出，入场时先画 80%，随后补全。
    final tailProgress = (0.5 + 0.5 * progress).clamp(0.0, 1.0);
    final tailEndX = center.dx + radius * (0.78 + 0.54 * tailProgress);
    final tailEndY = center.dy + radius * (0.72 + 0.66 * tailProgress);
    final tail = Path()
      ..moveTo(center.dx + radius * 0.78, center.dy + radius * 0.72)
      ..quadraticBezierTo(
        center.dx + radius * 1.25,
        center.dy + radius * 0.95,
        tailEndX,
        tailEndY,
      )
      ..lineTo(
        center.dx + radius * 1.18,
        center.dy + radius * 1.22,
      );
    canvas.drawPath(tail, ringPaint..strokeWidth = 5);

    // 尾点高光：入场时弹入，随 fx 微微涨缩。
    final dot = Offset(tailEndX, tailEndY);
    final dotScale = 0.6 + 0.4 * Curves.elasticOut.transform(progress) + 0.08 * math.sin(fx * 2 * math.pi);
    canvas.drawCircle(
      dot,
      3.4 * dotScale,
      Paint()
        ..style = PaintingStyle.fill
        ..color = const Color(0xFF7DF9FF),
    );
    canvas.drawCircle(
      dot,
      7 * dotScale,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFF7DF9FF).withValues(alpha: 0.35),
    );

    // 内部细高光描边。
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

    // 旋转高光扫过：一条斜向白色光带沿圆环扫，增强“炫”。
    final shineAngle = fx * 2 * math.pi;
    final shineCenter = center + Offset(
          math.cos(shineAngle) * radius * 0.9,
          math.sin(shineAngle) * radius * 0.9,
        );
    canvas.drawCircle(
      shineCenter,
      5.5,
      Paint()
        ..style = PaintingStyle.fill
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.18 + 0.10 * math.sin(shineAngle * 3)),
    );

    // 微粒：环绕 Logo 的星点，随 fx 明灭。
    const starCount = 6;
    for (var i = 0; i < starCount; i++) {
      final phase = i / starCount;
      final angle = fx * 2 * math.pi + phase * 2 * math.pi;
      final rr = radius * (1.55 + 0.10 * math.sin(fx * 3 * math.pi + i));
      final pos = center + Offset(math.cos(angle) * rr, math.sin(angle) * rr);
      final alpha = (0.25 + 0.6 * (0.5 + 0.5 * math.sin(fx * 6 * math.pi + phase * 2 * math.pi))).clamp(0.0, 1.0);
      canvas.drawCircle(
        pos,
        i.isEven ? 1.8 : 1.2,
        Paint()
          ..style = PaintingStyle.fill
          ..color = const Color(0xFFBDEBFF).withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_PremiumLogoPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.fx != fx;
}
