import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qinglong_flutter/features/external/external_overlay_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('关掉悬浮窗后原生窗口收回到剩余悬浮球，全部关闭立刻收成空窗口',
      (tester) async {
    final c = ExternalOverlayController.instance;
    const ball = Rect.fromLTWH(1560, 2260, 96, 96);
    const chat = Rect.fromLTWH(80, 180, 900, 1200);
    final union = ball.expandToInclude(chat);

    c.noteBounds(ball);
    expect(c.bounds.value, ball, reason: '首次上报应直接采用并集');

    c.noteBounds(union);
    expect(c.bounds.value, union, reason: '打开悬浮窗后窗口应扩大到并集');

    // 只关掉悬浮窗、保留悬浮球：并集缩小远超阈值，200ms 防抖后收回。
    c.noteBounds(ball);
    expect(c.bounds.value, union, reason: '缩小有防抖，不应每帧抖动');
    await tester.pump(const Duration(milliseconds: 250));
    expect(c.bounds.value, ball, reason: '关掉悬浮窗后窗口必须收回，否则挡桌面');

    // 全部关闭：空并集必须立即上报，不能等防抖。
    c.noteBounds(Rect.zero);
    expect(c.bounds.value, Rect.zero, reason: '全部关闭应立即收成空窗口');
  });
}
