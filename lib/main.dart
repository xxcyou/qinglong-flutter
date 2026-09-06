import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全面屏：内容铺到状态栏与导航栏之下，系统栏全透明，不留"额头"。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      // 关掉系统自动加的"对比度垫色"。
      // Android 10+ 在 edgeToEdge 下会给状态栏/导航栏悄悄铺一层半透明灰，
      // 于是屏幕上下各留一条灰边——看着就是"贴不到边、白白浪费两条空间"。
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    ),
  );
  // P0: 设置与面板列表在 QingLongApp.initState 中异步加载，避免阻塞首帧。
  runApp(const ProviderScope(child: QingLongApp()));
}
