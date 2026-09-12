import 'dart:async';

import '../models/ai_message.dart';

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
    this.attachments,
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

  /// 可选：这次工具执行后产生的图片附件。
  ///
  /// 主要用于截屏/截图工具：tool 返回文字给模型看，同时把图片交给
  /// AgentLoop 做“图片注入”（主模型支持图片时直接看图）和聊天展示。
  final Future<List<AiImageAttachment>> Function(Map<String, dynamic> args)?
      attachments;
}
