/// 悬浮球快问：长按悬浮球伸出输入框，问一句，结果弹一个无边小窗。
///
/// 和悬浮聊天窗是两件事：那个是"坐下来聊"，这个是"站着问一句"——
/// 拿个数字、看一眼状态、要一条通告。所以它没有历史、没有附件栏、
/// 没有工具时间线，只有一行输入和一个结果窗。
library;

/// 一个结果窗。位置尺寸都按屏幕比例存，横竖屏切换不会跑到屏幕外。
class QuickResultWindow {
  const QuickResultWindow({
    required this.id,
    required this.question,
    required this.answer,
    this.failed = false,
    this.x = 0.06,
    this.y = 0.2,
    this.w = 0.86,
    this.h = 0.3,
  });

  /// 窗口尺寸下限（占屏比例）：再小就看不见字了。
  static const minW = 0.36;
  static const minH = 0.12;

  final String id;

  /// 当时问的那句话，显示在结果上方一行小字里——
  /// 一屏上开着三个结果窗时，不写清楚就分不出哪个答的是哪句。
  final String question;

  final String answer;

  /// 这一轮是失败收场（没发出去 / 报错）。失败也要弹窗：
  /// 悄悄失败的话，用户会一直等一个永远不来的结果。
  final bool failed;

  final double x;
  final double y;
  final double w;
  final double h;

  QuickResultWindow copyWith({
    String? question,
    String? answer,
    bool? failed,
    double? x,
    double? y,
    double? w,
    double? h,
  }) {
    return QuickResultWindow(
      id: id,
      question: question ?? this.question,
      answer: answer ?? this.answer,
      failed: failed ?? this.failed,
      x: x ?? this.x,
      y: y ?? this.y,
      w: w ?? this.w,
      h: h ?? this.h,
    );
  }

  /// 第 [index] 个窗口的默认位置：层叠着放，别正好压住上一个的关闭按钮。
  static ({double x, double y, double w, double h}) layoutFor(int index) {
    final step = (index % 5) * 0.035;
    return (x: 0.05 + step, y: 0.16 + step, w: 0.86, h: 0.3);
  }
}

/// 快问附件：只记路径，不读正文。
///
/// 用户要的是"把文件路径给 AI，AI 自己调工具去读"——正文在提问那一刻
/// 读出来既浪费 token，文件后来变了还会给 AI 一份过期内容。
class QuickFileRef {
  const QuickFileRef({required this.path, required this.name});

  final String path;
  final String name;
}
