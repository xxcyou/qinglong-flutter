import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../features/ai/models/ai_message.dart';

/// 一次附件/图片悬浮预览的状态。
class AttachmentPreviewState {
  AttachmentPreviewState({this.image, this.networkUrl}) : key = UniqueKey();

  final AiImageAttachment? image;
  final String? networkUrl;
  final Key key;
  final Completer<void> completer = Completer<void>();
}

/// 附件预览改成全局悬浮窗（而不是 Navigator Dialog）的控制器。
///
/// 外部悬浮模式下 `MaterialApp.builder` 不再构建 Navigator，Dialog 没有
/// 挂载点；统一走这里，附件在 APP 内和 APP 外都是同一个可拖动/可关闭的
/// 悬浮窗。
class AttachmentPreviewController {
  AttachmentPreviewController._();

  static final AttachmentPreviewController instance =
      AttachmentPreviewController._();

  final ValueNotifier<AttachmentPreviewState?> state =
      ValueNotifier<AttachmentPreviewState?>(null);

  Future<void> showImage(AiImageAttachment image) {
    return _show(AttachmentPreviewState(image: image));
  }

  Future<void> showNetwork(String url) {
    return _show(AttachmentPreviewState(
      image: const AiImageAttachment(
        name: 'network_image',
        mime: 'image/png',
        dataUri: '',
      ),
      networkUrl: url,
    ));
  }

  Future<void> _show(AttachmentPreviewState next) {
    _finishCurrent();
    state.value = next;
    return next.completer.future;
  }

  void close() {
    final current = state.value;
    state.value = null;
    if (current != null && !current.completer.isCompleted) {
      current.completer.complete();
    }
  }

  void _finishCurrent() {
    final current = state.value;
    if (current != null && !current.completer.isCompleted) {
      current.completer.complete();
    }
  }
}
