import 'package:flutter/material.dart';

/// 启动 Logo 遮罩：主题加载完成前盖在整棵 App 上，
/// 用“淡入 → 全显停留 → 淡出”代替转圈，让启动过程更干净。
class StartupSplash extends StatefulWidget {
  const StartupSplash({
    super.key,
    required this.ready,
    this.onFinished,
  });

  /// 主题已加载且最短展示时间已到，允许开始淡出。
  final bool ready;

  /// 淡出动画结束后回调，由父层移除启动遮罩。
  final VoidCallback? onFinished;

  @override
  State<StartupSplash> createState() => _StartupSplashState();
}

class _StartupSplashState extends State<StartupSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  bool _fadingOut = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _opacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: ConstantTween(1.0),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 30,
      ),
    ]).animate(_controller);
    _controller.value = 0;
    // 先走到“全显阶段结束”（约 70%）：淡入 + 全显停留。
    _controller.animateTo(
      0.7,
      duration: const Duration(milliseconds: 1000),
      curve: Curves.linear,
    ).whenComplete(() {
      if (mounted && widget.ready) _fadeOut();
    });
  }

  @override
  void didUpdateWidget(covariant StartupSplash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ready && !oldWidget.ready && !_fadingOut) {
      _fadeOut();
    }
  }

  void _fadeOut() {
    if (_fadingOut) return;
    _fadingOut = true;
    _controller.animateTo(
      1.0,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
    ).whenComplete(() {
      widget.onFinished?.call();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FadeTransition(
      opacity: _opacity,
      child: Material(
        color: scheme.surface,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.4),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.18),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset(
                    'assets/images/app_icon.png',
                    width: 76,
                    height: 76,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '青龙面板',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'QingLong Shell',
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 1.4,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}