import 'dart:async';

/// 运行期注入的外部工具（MCP 服务器工具、技能读取等）。
///
/// AgentLoop 不关心它从哪来，只需要名字、schema 和怎么执行。
/// 这样以后接任何扩展（联网搜索、家庭自动化、第三方 API）都不用改循环。
class ExternalTool {
  const ExternalTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.invoke,
    this.isWrite = false,
    this.danger = false,
    this.origin = '',
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final Future<String> Function(Map<String, dynamic> args) invoke;

  /// 是否算写操作（参与确认策略）。
  final bool isWrite;

  /// 是否危险（"仅危险"策略会拦它）。
  final bool danger;

  /// 来源描述，出错时告诉用户是哪个服务器。
  final String origin;
}
