/// 子任务：AI 把复杂需求拆成的一条待办。
class AgentSubtask {
  const AgentSubtask({
    required this.id,
    required this.title,
    this.status = SubtaskStatus.pending,
    this.note = '',
  });

  final String id;
  final String title;
  final SubtaskStatus status;

  /// 完成/失败时的一句说明。
  final String note;

  AgentSubtask copyWith({
    String? title,
    SubtaskStatus? status,
    String? note,
  }) {
    return AgentSubtask(
      id: id,
      title: title ?? this.title,
      status: status ?? this.status,
      note: note ?? this.note,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'status': status.name,
        if (note.isNotEmpty) 'note': note,
      };

  factory AgentSubtask.fromJson(Map<String, dynamic> json) {
    final raw = json['status']?.toString() ?? 'pending';
    return AgentSubtask(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      status: SubtaskStatus.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => SubtaskStatus.pending,
      ),
      note: json['note']?.toString() ?? '',
    );
  }
}

enum SubtaskStatus { pending, running, done, failed, skipped }

extension SubtaskStatusLabel on SubtaskStatus {
  String get label => switch (this) {
        SubtaskStatus.pending => '待办',
        SubtaskStatus.running => '进行中',
        SubtaskStatus.done => '完成',
        SubtaskStatus.failed => '失败',
        SubtaskStatus.skipped => '跳过',
      };
}

/// 一次运行的任务清单。
class AgentTaskPlan {
  const AgentTaskPlan({this.goal = '', this.items = const []});

  final String goal;
  final List<AgentSubtask> items;

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;

  int get doneCount =>
      items.where((i) => i.status == SubtaskStatus.done).length;

  int get failedCount =>
      items.where((i) => i.status == SubtaskStatus.failed).length;

  AgentSubtask? get current {
    for (final i in items) {
      if (i.status == SubtaskStatus.running) return i;
    }
    for (final i in items) {
      if (i.status == SubtaskStatus.pending) return i;
    }
    return null;
  }

  /// 给模型看的紧凑文本：它每轮都要知道自己走到哪一步了。
  String promptLines() {
    if (items.isEmpty) return '';
    final buffer = StringBuffer('当前任务清单');
    if (goal.isNotEmpty) buffer.write('（目标：$goal）');
    buffer.writeln('：');
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final mark = switch (item.status) {
        SubtaskStatus.done => '[x]',
        SubtaskStatus.failed => '[!]',
        SubtaskStatus.running => '[>]',
        SubtaskStatus.skipped => '[-]',
        SubtaskStatus.pending => '[ ]',
      };
      buffer.writeln(
        '$mark ${i + 1}. ${item.title}'
        '${item.note.isEmpty ? '' : ' —— ${item.note}'}',
      );
    }
    return buffer.toString().trimRight();
  }

  AgentTaskPlan copyWith({String? goal, List<AgentSubtask>? items}) =>
      AgentTaskPlan(goal: goal ?? this.goal, items: items ?? this.items);

  Map<String, dynamic> toJson() => {
        'goal': goal,
        'items': [for (final i in items) i.toJson()],
      };

  factory AgentTaskPlan.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    return AgentTaskPlan(
      goal: json['goal']?.toString() ?? '',
      items: raw is List
          ? [
              for (final item in raw)
                if (item is Map<String, dynamic>) AgentSubtask.fromJson(item),
            ]
          : const [],
    );
  }
}

/// AI 生成的交互画布：一份自包含的 HTML 页面。
///
/// 用来做小游戏、图表、可点的演示——凡是聊天气泡表达不了的东西。
/// 内容跑在 WebView 里，与 APP 数据完全隔离（没有 JS 通道能读面板数据）。
class AiCanvas {
  const AiCanvas({
    required this.id,
    required this.title,
    required this.html,
    this.description = '',
    this.expectResult = false,
    this.resultHint = '',
    this.createdAt,
    this.window = '',
    this.chromeless = false,
    this.position = '',
    this.rect,
  });

  final String id;
  final String title;
  final String description;

  /// 窗口名。悬浮模式下同名窗口原地替换内容（游戏窗、操作窗、成绩窗各占一个）。
  ///
  /// 空 = 每次都开一个新窗口。这是"多窗口"的钥匙：AI 想更新哪个窗口，
  /// 就用同一个 window 名再发一次 ui_canvas，而不是又叠一个新窗口上来。
  final String window;

  /// 无边框：不画标题栏，内容直接贴到窗口边缘，右上角只留一个淡淡的关闭点。
  /// 游戏、全幅仪表盘这种"标题栏纯属浪费"的内容用它。
  final bool chromeless;

  /// 位置预设：center/top/bottom/left/right/topleft/topright/
  /// bottomleft/bottomright/full。空 = 自动错开摆放。
  final String position;

  /// 精确位置（占屏比例 left/top/width/height），优先级高于 [position]。
  final List<double>? rect;

  /// 完整的 HTML（可内联 <style>/<script>）。
  final String html;

  /// 是否等用户操作结果回传（滑块验证、填表、选择器都属于这种）。
  final bool expectResult;

  /// 提示用户要做什么，例如"拖动滑块完成验证后点提交"。
  final String resultHint;
  final DateTime? createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'html': html,
        if (expectResult) 'expectResult': true,
        if (resultHint.isNotEmpty) 'resultHint': resultHint,
        'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
        if (window.isNotEmpty) 'window': window,
        if (chromeless) 'chromeless': true,
        if (position.isNotEmpty) 'position': position,
        if (rect != null) 'rect': rect,
      };

  factory AiCanvas.fromJson(Map<String, dynamic> json) => AiCanvas(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '互动卡片',
        description: json['description']?.toString() ?? '',
        html: json['html']?.toString() ?? '',
        expectResult: json['expectResult'] == true,
        resultHint: json['resultHint']?.toString() ?? '',
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
        window: json['window']?.toString() ?? '',
        chromeless: json['chromeless'] == true,
        position: json['position']?.toString() ?? '',
        rect: json['rect'] is List
            ? [
                for (final v in json['rect'] as List)
                  (v as num?)?.toDouble() ?? 0,
              ]
            : null,
      );
}
