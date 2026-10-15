import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('扩大窗口立即下发；Shell 等原生 boundsApplied 后再切坐标', (tester) async {
    final c = ExternalOverlayController.instance;
    const channel = MethodChannel('qinglong/external_overlay');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      c.active.value = false;
      c.devicePixelRatio = 1.0;
      c.fullScreenSize = Size.zero;
      c.appliedBounds.value = Rect.zero;
    });

    c.devicePixelRatio = 1.0;
    c.fullScreenSize = const Size(1200, 2608);
    c.active.value = true;
    c.appliedBounds.value = Rect.zero;
    calls.clear();

    // 首次扩大：必须立即下发 updateBounds，而不是等 60ms 防抖。
    c.noteBounds(const Rect.fromLTWH(100, 100, 200, 200));
    await tester.pump();
    expect(c.bounds.value, const Rect.fromLTWH(100, 100, 200, 200));
    expect(
      calls.where((call) => call.method == 'updateBounds'),
      isNotEmpty,
      reason: '扩大窗口应立刻通知原生，Shell 才不会和原生窗口错位',
    );

    // 原生还没回 boundsApplied：appliedBounds 保持旧值，Shell 不会提前切坐标。
    expect(c.appliedBounds.value, Rect.zero);

    // 原生应用完成回传后，appliedBounds 才更新。
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('boundsApplied', <String, double>{
          'left': 100,
          'top': 100,
          'width': 200,
          'height': 200,
        }),
      ),
      (_) {},
    );
    await tester.pump();
    expect(c.appliedBounds.value, const Rect.fromLTWH(100, 100, 200, 200));
  });
}
