import 'package:flutter/material.dart';

/// 跟随尾部滚动的控制器。
///
/// 日志的期望行为：默认贴着底跑，用户一往上滑就停住（他正在看历史，
/// 这时候把他甩回底部非常烦），滑回底部再自动恢复跟随。
///
/// 用法：把 [controller] 交给 ListView，每次数据更新后调 [stick]。
class TailScroll {
  TailScroll({this.threshold = 48}) {
    controller.addListener(_onScroll);
  }

  final ScrollController controller = ScrollController();

  /// 距底部多少像素以内算"在底部"。手指抬起时的惯性会差几像素，留点余量。
  final double threshold;

  final ValueNotifier<bool> following = ValueNotifier<bool>(true);

  bool get isFollowing => following.value;

  void _onScroll() {
    if (!controller.hasClients) return;
    final position = controller.position;
    final distance = position.maxScrollExtent - position.pixels;
    final atBottom = distance <= threshold;
    if (atBottom != following.value) following.value = atBottom;
  }

  /// 数据更新后调用：仍在跟随就贴回底部，否则什么都不做。
  void stick({bool animate = false}) {
    if (!following.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      final target = controller.position.maxScrollExtent;
      if (animate) {
        controller.animateTo(
          target,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        );
      } else {
        controller.jumpTo(target);
      }
    });
  }

  /// 手动回到底部并恢复跟随。
  void resume() {
    following.value = true;
    stick(animate: true);
  }

  void dispose() {
    controller.removeListener(_onScroll);
    controller.dispose();
    following.dispose();
  }
}

/// "已暂停跟随，点一下回到最新"的悬浮按钮。
class FollowTailButton extends StatelessWidget {
  const FollowTailButton({
    super.key,
    required this.tail,
    this.label = '回到最新',
  });

  final TailScroll tail;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: tail.following,
      builder: (context, following, _) {
        if (following) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 96, right: 4),
          child: FloatingActionButton.small(
            heroTag: null,
            tooltip: '$label（已暂停自动滚动）',
            onPressed: tail.resume,
            child: const Icon(Icons.arrow_downward_rounded),
          ),
        );
      },
    );
  }
}
