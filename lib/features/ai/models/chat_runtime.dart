import 'dart:convert';

import 'agent_event.dart';
import 'ai_message.dart';

/// 排队中的一条待发消息。
class QueuedMessage {
  QueuedMessage({
    required this.id,
    required this.text,
    this.images = const [],
    this.sessionId = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String text;
  final List<AiImageAttachment> images;

  /// 这条消息属于哪个会话；空表示旧数据/全局。并发跑时每个会话各自排各的队。
  final String sessionId;
  final DateTime createdAt;

  factory QueuedMessage.create(
    String text, {
    String sessionId = '',
    List<AiImageAttachment> images = const [],
  }) =>
      QueuedMessage(
        id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        text: text,
        images: images,
        sessionId: sessionId,
      );

  QueuedMessage copyWith({
    String? text,
    List<AiImageAttachment>? images,
    String? sessionId,
  }) =>
      QueuedMessage(
        id: id,
        text: text ?? this.text,
        images: images ?? this.images,
        sessionId: sessionId ?? this.sessionId,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (images.isNotEmpty)
          'images': [for (final img in images) img.toJson()],
        'sessionId': sessionId,
        'createdAt': createdAt.toIso8601String(),
      };

  factory QueuedMessage.fromJson(Map<String, dynamic> json) => QueuedMessage(
        id: json['id']?.toString() ??
            DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        text: json['text']?.toString() ?? '',
        images: [
          for (final img in (json['images'] as List? ?? const []))
            if (img is Map<String, dynamic>) AiImageAttachment.fromJson(img),
        ],
        sessionId: json['sessionId']?.toString() ?? '',
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
      );
}

/// 被中断的运行快照。
///
/// APP 被系统杀掉或闪退时，正在跑的思考与工具链会连同内存一起消失，
/// 用户重开只看到"什么都没发生"。这个快照把「哪个会话、问了什么、已经
/// 做到哪一步」落盘，重开后可以接着继续，而不是从零再问一遍。
class InterruptedRun {
  const InterruptedRun({
    required this.sessionId,
    required this.userInput,
    required this.events,
    required this.startedAt,
    this.confirmedKeys = const [],
  });

  final String sessionId;

  /// 触发这次运行的用户输入（继续时重新发它）。
  final String userInput;

  /// 已经产生的思考/工具事件，用来在界面上还原过程。
  final List<AgentEvent> events;
  final DateTime startedAt;

  /// 已确认过的写操作键，继续时不必再问一遍。
  final List<String> confirmedKeys;

  bool get isEmpty => userInput.trim().isEmpty && events.isEmpty;

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'userInput': userInput,
        'events': [for (final e in events) e.toJson()],
        'startedAt': startedAt.toIso8601String(),
        'confirmedKeys': confirmedKeys,
      };

  factory InterruptedRun.fromJson(Map<String, dynamic> json) => InterruptedRun(
        sessionId: json['sessionId']?.toString() ?? '',
        userInput: json['userInput']?.toString() ?? '',
        events: [
          for (final e in (json['events'] as List? ?? const []))
            if (e is Map<String, dynamic>) AgentEvent.fromJson(e),
        ],
        startedAt: DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
            DateTime.now(),
        confirmedKeys: [
          for (final k in (json['confirmedKeys'] as List? ?? const []))
            k.toString(),
        ],
      );

  static String encode(InterruptedRun run) => jsonEncode(run.toJson());

  static InterruptedRun? decode(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final run = InterruptedRun.fromJson(decoded);
      return run.isEmpty ? null : run;
    } catch (_) {
      return null;
    }
  }
}
