import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qinglong_flutter/features/external/external_float_shell.dart';
import 'package:qinglong_flutter/features/external/external_overlay_controller.dart';
import 'package:qinglong_flutter/features/floating/app_float_layer.dart';
import 'package:qinglong_flutter/features/floating/float_bounds_registry.dart';
import 'package:qinglong_flutter/features/terminal/docker/ssh_floating_host.dart';

/// 回归：容器终端/日志/文件夹窗是在 `build()` 里直接登记矩形的。
/// 如果只是普通 `ValueNotifier` 自增，这次通知会淹没在 build 阶段，
/// 原生覆盖窗口就只按 AI 球的旧并集大小，窗口被裁成“只显示一半”。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('build 期登记的容器窗口并集也会撑大原生覆盖窗', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('qinglong/external_overlay');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);

    final c = ExternalOverlayController.instance;
    c.devicePixelRatio = 3.0;
    c.noteFullScreen(const MediaQueryData(
      size: Size(400, 800),
      devicePixelRatio: 3.0,
    ));
    c.active.value = true;
    c.appliedBounds.value = const Rect.fromLTWH(0, 0, 400, 800);

    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      c.active.value = false;
      c.fullScreenSize = Size.zero;
      c.appliedBounds.value = Rect.zero;
      c.bounds.value = Rect.zero;
    });

    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(
        builder: _shell,
        home: Scaffold(body: SizedBox()),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    final ctx = tester.element(find.byType(AppFloatLayer));
    final id = SshFloatingHost.add(
      ctx,
      group: 'regression',
      title: '终端',
      icon: Icons.terminal,
      builder: (_) {
        // 模拟 SshFloatingHostLayer 里窗口 build 时直接 report。
        FloatBoundsRegistry.report(
          'regression-ssh',
          const Rect.fromLTWH(40, 120, 300, 200),
        );
        return const SizedBox.expand();
      },
    );

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(
      c.bounds.value.contains(const Offset(200, 200)),
      isTrue,
      reason: '原生覆盖窗必须把容器悬浮窗并集算进去，'
          '否则容器终端/日志/文件夹窗只显示一半',
    );

    SshFloatingHost.close(id);
    FloatBoundsRegistry.remove('regression-ssh');
    // 关掉常驻帧泵和 bounds 防抖，别把定时器留给 flutter_test。
    c.active.value = false;
    c.fullScreenSize = Size.zero;
    c.appliedBounds.value = Rect.zero;
    c.bounds.value = Rect.zero;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
  });
}

Widget _shell(BuildContext context, Widget? child) => const ExternalFloatShell();
