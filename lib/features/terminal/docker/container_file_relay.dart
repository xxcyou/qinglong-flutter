import 'dart:typed_data';

/// 容器文件管理 ↔ 外部文件管理器（本地/SSH）之间的复制剪切中转。
///
/// 统一把源文件先读成字节放到这里，再从目标侧写出去；
/// 剪切会在目标写成功后删除源文件。
enum ContainerRelaySourceType { container, shell, app, ssh, adb }

class ContainerRelayItem {
  const ContainerRelayItem({
    required this.name,
    required this.bytes,
    required this.cut,
    required this.sourceType,
    required this.sourcePath,
    this.sourceSshId,
    this.sourceAdbId,
    this.sourceContainerId,
  });

  final String name;
  final Uint8List bytes;
  final bool cut;
  final ContainerRelaySourceType sourceType;
  final String sourcePath;

  /// sourceType 为 ssh/container 时对应的 SSH 会话 id。
  final String? sourceSshId;

  /// sourceType 为 adb 时对应的 ADB 会话 id。
  final String? sourceAdbId;

  /// sourceType 为 container 时对应的容器 id。
  final String? sourceContainerId;
}

class ContainerFileRelay {
  ContainerFileRelay._();

  static ContainerRelayItem? _item;

  static bool get hasValue => _item != null;

  static ContainerRelayItem? get item => _item;

  static void set(ContainerRelayItem item) => _item = item;

  static void clear() => _item = null;
}
