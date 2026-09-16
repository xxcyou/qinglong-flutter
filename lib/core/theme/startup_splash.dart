import 'package:flutter/material.dart';

/// 启动 Logo 遮罩：在主题加载完成前盖在整棵 App 上，
/// 既挡住默认暗色/亮色的“空白起步”，也让启动过程有个品牌过渡。
class StartupSplash extends StatelessWidget {
  const StartupSplash({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.55),
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
              child: Icon(
                Icons.auto_awesome,
                size: 44,
                color: scheme.primary,
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
            const SizedBox(height: 28),
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
