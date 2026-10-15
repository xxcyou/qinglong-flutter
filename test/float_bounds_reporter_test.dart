import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qinglong_flutter/features/external/external_overlay_controller.dart';
import 'package:qinglong_flutter/features/floating/float_bounds_registry.dart';

void main() {
  testWidgets('FloatBoundsReporter 上报实际全局矩形，销毁后移除', (tester) async {
    const id = 'test-float';
    FloatBoundsRegistry.remove(id);
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 20,
              top: 30,
              width: 100,
              height: 50,
              child: FloatBoundsReporter(
                id: id,
                child: Container(color: Colors.red),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump(); // 执行 postFrame 上报
    expect(FloatBoundsRegistry.union, const Rect.fromLTWH(20, 30, 100, 50));

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(FloatBoundsRegistry.union, Rect.zero);
  });

  testWidgets('APP 外模式会加回 Shell 平移量，登记全屏逻辑坐标', (tester) async {
    const id = 'test-float-external';
    final controller = ExternalOverlayController.instance;
    controller.active.value = true;
    controller.fullScreenSize = const Size(400, 800);
    controller.bounds.value = const Rect.fromLTWH(100, 200, 300, 400);
    FloatBoundsRegistry.remove(id);
    addTearDown(() {
      FloatBoundsRegistry.remove(id);
      controller.active.value = false;
      controller.fullScreenSize = Size.zero;
      controller.bounds.value = Rect.zero;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              // 模拟 ExternalFloatShell 的负平移。
              left: -100,
              top: -200,
              width: 400,
              height: 800,
              child: Stack(
                children: [
                  Positioned(
                    left: 120,
                    top: 230,
                    width: 100,
                    height: 50,
                    child: FloatBoundsReporter(
                      id: id,
                      child: Container(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    // localToGlobal = (20,30)，加回 bounds.topLeft (100,200) 后应回到全屏坐标。
    expect(FloatBoundsRegistry.union, const Rect.fromLTWH(120, 230, 100, 50));
  });

  testWidgets('多个独立悬浮窗的并集覆盖所有窗口', (tester) async {
    const a = 'test-float-a';
    const b = 'test-float-b';
    FloatBoundsRegistry.remove(a);
    FloatBoundsRegistry.remove(b);
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 10,
              top: 10,
              width: 50,
              height: 50,
              child: FloatBoundsReporter(
                id: a,
                child: Container(color: Colors.red),
              ),
            ),
            Positioned(
              left: 200,
              top: 300,
              width: 80,
              height: 40,
              child: FloatBoundsReporter(
                id: b,
                child: Container(color: Colors.blue),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(
      FloatBoundsRegistry.union,
      const Rect.fromLTWH(10, 10, 270, 330),
    );
    FloatBoundsRegistry.remove(a);
    FloatBoundsRegistry.remove(b);
  });
}
