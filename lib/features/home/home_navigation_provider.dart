import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 底部导航当前标签页，供任意管理页一键跳到 AI 等 Tab。
final homeTabIndexProvider = StateProvider<int>((ref) => 0);
