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

  /// 主题未就绪时 Logo 最多淡到这个“半显”程度，不让它先完成加载。
  static const double _partialValue = 0.12;
  bool _readySequenceStarted = false;

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
    if (widget.ready) {
      // 主题已经就绪：直接走完整淡入 → 全显 → 淡出。
      _startReadySequence();
    } else {
      // 主题还没加载完：Logo 只淡到半显，等主题就绪后再走完剩余动画。
      _controller.animateTo(
        _partialValue,
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInCubic,
      );
    }
  }

  @override
  void didUpdateWidget(covariant StartupSplash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ready && !oldWidget.ready && !_readySequenceStarted) {
      _startReadySequence();
    }
  }

  /// 主题就绪后接管动画：从当前（半显）位置继续到全显，再停留并淡出。
  void _startReadySequence() {
    if (_readySequenceStarted) return;
    _readySequenceStarted = true;
    _controller.stop();
    final start = _controller.value;
    final remaining = (1.0 - start).clamp(0.0, 1.0);
    final durationMs = (remaining * 1200).round().clamp(400, 1200);
    _controller
        .animateTo(
      1.0,
      duration: Duration(milliseconds: durationMs),
      curve: Curves.easeInOutCubic,
    )
        .whenComplete(() {
      if (mounted) widget.onFinished?.call();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 启动页背景必须保持固定深色，不跟随主题切换：
    // 否则主题在 Logo 期间从暗色切到亮色，会出现“暗→卡→亮”的跳变。
    const bg = Color(0xFF0F1115);
    const primaryText = Color(0xFFE8EAED);
    const secondaryText = Color(0xFF9AA0A6);
    return Material(
      color: bg,
      child: Center(
        child: FadeTransition(
          opacity: _opacity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFFFF).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: const Color(0xFFFFFFFF).withValues(alpha: 0.22),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 28,
                      offset: Offset(0, 10),
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
              const Text(
                '青龙面板',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  color: primaryText,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'QingLong Shell',
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 1.4,
                  color: secondaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
