import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_debug_log.dart';

/// 暴露全局 [ApiDebugLog]，Debug 页 watch 后会自动更新。
final apiDebugProvider =
    ChangeNotifierProvider<ApiDebugLog>((ref) => ApiDebugLog.instance);
