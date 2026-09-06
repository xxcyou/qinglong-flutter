import 'dart:io';

import 'proot_bridge.dart';

class ShellDetector {
  const ShellDetector();

  bool get isAndroid {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  Future<ShellProbeResult> probe() async {
    if (!isAndroid) {
      return const ShellProbeResult(
        available: false,
        installed: false,
        reason: '仅 Android 支持 PRoot Debian',
      );
    }
    try {
      final status = await ProotBridge().status();
      return ShellProbeResult(
        available: status.installed,
        installed: status.installed,
        reason: status.installed ? null : 'Runtime V2 尚未安装',
        status: status,
      );
    } catch (e) {
      return ShellProbeResult(
        available: false,
        installed: false,
        reason: '探测失败：$e',
      );
    }
  }
}

class ShellProbeResult {
  const ShellProbeResult({
    required this.available,
    required this.installed,
    this.reason,
    this.status,
  });

  final bool available;
  final bool installed;
  final String? reason;
  final PreruntimeStatus? status;
}
