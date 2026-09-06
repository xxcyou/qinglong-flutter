/// 写操作确认策略。
enum AiApprovalMode {
  /// 严格：任何写操作（改任务、改环境变量、跑命令…）都要用户点确认。
  strict,

  /// 平衡（默认）：只有危险操作才要确认——删除、覆盖既有内容、
  /// 触发真实执行（运行任务/脚本）、执行任意 shell 命令、面板自更新。
  /// 新建、启停开关这类可逆动作直接执行。
  cautious,

  /// 全部放行：AI 可以直接执行任何工具，不再中途停下等确认。
  full;

  String get label => switch (this) {
        AiApprovalMode.strict => '严格',
        AiApprovalMode.cautious => '仅危险',
        AiApprovalMode.full => '全部放行',
      };

  String get description => switch (this) {
        AiApprovalMode.strict => '所有写操作都要你点确认，最安全但最啰嗦',
        AiApprovalMode.cautious => '删除、覆盖、运行任务、执行命令才要确认；新建改开关直接做',
        AiApprovalMode.full => 'AI 可以直接动手，不再询问。请只在信任的场景使用',
      };

  static AiApprovalMode fromName(String? name) {
    for (final mode in AiApprovalMode.values) {
      if (mode.name == name) return mode;
    }
    return AiApprovalMode.cautious;
  }
}
