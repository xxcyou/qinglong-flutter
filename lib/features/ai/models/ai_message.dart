import 'agent_event.dart';
import 'agent_task_plan.dart';

class AiToolCall {
  const AiToolCall({
    required this.name,
    this.arguments = const {},
  });

  final String name;
  final Map<String, dynamic> arguments;
}

/// 聊天里的一张图片附件。
///
/// [dataUri] 是 `data:image/png;base64,...`，既用来发给识别模型，也用来
/// 在气泡/悬浮窗里直接展示。路径/作用域只作来源记录，方便排查文件在哪。
class AiImageAttachment {
  const AiImageAttachment({
    required this.name,
    required this.mime,
    required this.dataUri,
    this.path = '',
    this.scope = 'shell',
  });

  final String name;
  final String mime;
  final String dataUri;
  final String path;
  final String scope;

  AiImageAttachment copyWith({
    String? name,
    String? mime,
    String? dataUri,
    String? path,
    String? scope,
  }) =>
      AiImageAttachment(
        name: name ?? this.name,
        mime: mime ?? this.mime,
        dataUri: dataUri ?? this.dataUri,
        path: path ?? this.path,
        scope: scope ?? this.scope,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'mime': mime,
        'dataUri': dataUri,
        if (path.isNotEmpty) 'path': path,
        if (scope != 'shell') 'scope': scope,
      };

  factory AiImageAttachment.fromJson(Map<String, dynamic> json) =>
      AiImageAttachment(
        name: json['name']?.toString() ?? 'image',
        mime: json['mime']?.toString() ?? 'image/png',
        dataUri: json['dataUri']?.toString() ?? '',
        path: json['path']?.toString() ?? '',
        scope: json['scope']?.toString() ?? 'shell',
      );
}

class AiChatMessage {
  const AiChatMessage({
    required this.role,
    this.content = '',
    this.images = const [],
    this.toolCalls = const [],
    this.createdAt,
    this.agentEvents = const [],
    this.outcome = '',
    this.turns = 0,
    this.totalTokens = 0,
    this.promptTokens = 0,
    this.cachedTokens = 0,
    this.taskPlan = const AgentTaskPlan(),
    this.canvases = const [],
    this.sendError = '',
  });

  final String role;
  final String content;
  final List<AiImageAttachment> images;
  final List<AiToolCall> toolCalls;
  final DateTime? createdAt;

  /// 本条回复对应的完整执行过程（思考 + 工具调用），随会话一起持久化，
  /// 这样退出重进后仍能展开看到这次任务是怎么做的。
  final List<AgentEvent> agentEvents;

  /// AgentOutcome.name：completed / failed / awaitingConfirm / cancelled / exhausted。
  final String outcome;
  final int turns;

  /// 整轮 Agent 的累计计费 token（每一轮都要重发历史，所以远大于上下文本身）。
  final int totalTokens;

  /// 最后一次请求的上下文实际占用。
  final int promptTokens;

  /// 命中提示词缓存的 token 数（DeepSeek 等按 1/10 计价）。
  final int cachedTokens;

  /// 本条回复对应的任务清单（AI 拆的步骤 + 最终状态），随会话持久化。
  final AgentTaskPlan taskPlan;

  /// 本条回复生成的 HTML 互动卡片。弹窗关掉后靠这份数据重新打开。
  final List<AiCanvas> canvases;

  /// 这条消息**没发出去**：模型调用本身失败了（网络、鉴权、限流、网关报错）。
  ///
  /// 只会出现在 user 消息上，内容是给用户看的错误原因。
  /// 关键约束：带着它的消息**不进上下文**——把"发送失败"当成一次真实对话
  /// 塞进历史，会让模型以为自己回过话，下一轮开始围绕一条不存在的回复推理；
  /// 之前那种"出错了：xxx"的 assistant 消息就是这么污染上下文的。
  final String sendError;

  bool get failedToSend => sendError.isNotEmpty;

  AiChatMessage copyWith({
    String? sendError,
    List<AgentEvent>? agentEvents,
    List<AiImageAttachment>? images,
  }) =>
      AiChatMessage(
        role: role,
        content: content,
        images: images ?? this.images,
        toolCalls: toolCalls,
        createdAt: createdAt,
        agentEvents: agentEvents ?? this.agentEvents,
        outcome: outcome,
        turns: turns,
        totalTokens: totalTokens,
        promptTokens: promptTokens,
        cachedTokens: cachedTokens,
        taskPlan: taskPlan,
        canvases: canvases,
        sendError: sendError ?? this.sendError,
      );

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (images.isNotEmpty)
          'images': [for (final img in images) img.toJson()],
        'toolCalls': [
          for (final t in toolCalls) {'name': t.name, 'arguments': t.arguments},
        ],
        'createdAt': createdAt?.toIso8601String(),
        if (agentEvents.isNotEmpty)
          'agentEvents': [for (final e in agentEvents) e.toJson()],
        if (outcome.isNotEmpty) 'outcome': outcome,
        if (turns > 0) 'turns': turns,
        if (totalTokens > 0) 'totalTokens': totalTokens,
        if (promptTokens > 0) 'promptTokens': promptTokens,
        if (cachedTokens > 0) 'cachedTokens': cachedTokens,
        if (taskPlan.isNotEmpty) 'taskPlan': taskPlan.toJson(),
        if (canvases.isNotEmpty)
          'canvases': [for (final c in canvases) c.toJson()],
        if (sendError.isNotEmpty) 'sendError': sendError,
      };

  factory AiChatMessage.fromJson(Map<String, dynamic> json) {
    return AiChatMessage(
      role: json['role']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      sendError: json['sendError']?.toString() ?? '',
      images: [
        for (final img in (json['images'] as List? ?? const []))
          if (img is Map<String, dynamic>) AiImageAttachment.fromJson(img),
      ],
      toolCalls: [
        for (final t in (json['toolCalls'] as List? ?? const []))
          if (t is Map<String, dynamic>)
            AiToolCall(
              name: t['name']?.toString() ?? '',
              arguments: t['arguments'] is Map<String, dynamic>
                  ? t['arguments'] as Map<String, dynamic>
                  : const {},
            ),
      ],
      createdAt: json['createdAt'] is String
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      agentEvents: [
        for (final e in (json['agentEvents'] as List? ?? const []))
          if (e is Map<String, dynamic>) AgentEvent.fromJson(e),
      ],
      taskPlan: json['taskPlan'] is Map<String, dynamic>
          ? AgentTaskPlan.fromJson(json['taskPlan'] as Map<String, dynamic>)
          : const AgentTaskPlan(),
      canvases: [
        for (final c in (json['canvases'] as List? ?? const []))
          if (c is Map<String, dynamic>) AiCanvas.fromJson(c),
      ],
      outcome: json['outcome']?.toString() ?? '',
      turns: (json['turns'] as num?)?.toInt() ?? 0,
      totalTokens: (json['totalTokens'] as num?)?.toInt() ?? 0,
      promptTokens: (json['promptTokens'] as num?)?.toInt() ?? 0,
      cachedTokens: (json['cachedTokens'] as num?)?.toInt() ?? 0,
    );
  }
}

/// AI 会话。
class AiSession {
  AiSession({
    required this.id,
    this.title = '新会话',
    this.messages = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String title;
  final List<AiChatMessage> messages;
  final DateTime createdAt;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'messages': [for (final m in messages) m.toJson()],
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory AiSession.fromJson(Map<String, dynamic> json) {
    return AiSession(
      id: json['id']?.toString() ?? '${DateTime.now().millisecondsSinceEpoch}',
      title: json['title']?.toString() ?? '新会话',
      messages: [
        for (final m in (json['messages'] as List? ?? const []))
          if (m is Map<String, dynamic>) AiChatMessage.fromJson(m),
      ],
      createdAt: json['createdAt'] is String
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : null,
      updatedAt: json['updatedAt'] is String
          ? DateTime.tryParse(json['updatedAt'] as String) ?? DateTime.now()
          : null,
    );
  }
}
