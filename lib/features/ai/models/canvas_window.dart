import 'agent_task_plan.dart';

/// 悬浮模式下的一个画布窗口：内容 + 几何 + 外观。
///
/// 为什么要它：`ui_canvas` 以前只能同时存在一张卡片，AI 想同时摆"游戏窗 +
/// 操作窗 + 成绩窗"就只能三张挤成一张。窗口数量不设上限，靠 [name] 区分：
/// 同名再发一次就是更新那个窗口，不同名就是新开一个。
class CanvasWindow {
  const CanvasWindow({
    required this.canvas,
    required this.name,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.chromeless = false,
  });

  final AiCanvas canvas;

  /// 窗口标识。AI 指定（game/score/control…），没指定时用画布 id。
  final String name;

  /// 几何：占可用区域的比例，和聊天窗一套算法，横竖屏切换都不会跑出屏幕。
  final double x;
  final double y;
  final double w;
  final double h;

  /// 无边框：不画标题栏，内容贴边，只留一个淡淡的关闭点。
  final bool chromeless;

  CanvasWindow copyWith({
    AiCanvas? canvas,
    double? x,
    double? y,
    double? w,
    double? h,
    bool? chromeless,
  }) {
    return CanvasWindow(
      canvas: canvas ?? this.canvas,
      name: name,
      x: x ?? this.x,
      y: y ?? this.y,
      w: w ?? this.w,
      h: h ?? this.h,
      chromeless: chromeless ?? this.chromeless,
    );
  }

  /// 尺寸下限（占屏比例）。画布不需要装输入框，所以比聊天窗宽松得多。
  static const minW = 0.18;
  static const minH = 0.10;

  /// 按预设位置算几何。
  ///
  /// [index] 是当前已有窗口数：没给位置时按它错开摆放，
  /// 不然连开三个窗口会精准叠在一起，用户以为只弹了一个。
  static ({double x, double y, double w, double h}) layoutFor(
    AiCanvas canvas,
    int index,
  ) {
    final rect = canvas.rect;
    if (rect != null && rect.length >= 4) {
      return (
        x: rect[0].clamp(0.0, 0.95),
        y: rect[1].clamp(0.0, 0.95),
        w: rect[2].clamp(minW, 1.0),
        h: rect[3].clamp(minH, 1.0),
      );
    }
    switch (canvas.position.trim().toLowerCase()) {
      case 'full':
      case 'fullscreen':
      case '全屏':
        return (x: 0, y: 0, w: 1, h: 1);
      case 'top':
      case '顶部':
        return (x: 0.02, y: 0, w: 0.96, h: 0.34);
      case 'bottom':
      case '底部':
        return (x: 0.02, y: 0.62, w: 0.96, h: 0.38);
      case 'left':
      case '左':
        return (x: 0, y: 0.16, w: 0.48, h: 0.6);
      case 'right':
      case '右':
        return (x: 0.52, y: 0.16, w: 0.48, h: 0.6);
      case 'topleft':
      case '左上':
        return (x: 0, y: 0, w: 0.5, h: 0.36);
      case 'topright':
      case '右上':
        return (x: 0.5, y: 0, w: 0.5, h: 0.36);
      case 'bottomleft':
      case '左下':
        return (x: 0, y: 0.6, w: 0.5, h: 0.36);
      case 'bottomright':
      case '右下':
        return (x: 0.5, y: 0.6, w: 0.5, h: 0.36);
      case 'center':
      case '居中':
        return (x: 0.08, y: 0.24, w: 0.84, h: 0.44);
      default:
        // 层叠摆放：每多一个窗口右下偏移一点，四个一循环。
        final step = (index % 4) * 0.05;
        return (x: 0.06 + step, y: 0.12 + step, w: 0.84, h: 0.42);
    }
  }
}
