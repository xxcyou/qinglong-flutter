import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../debug/api_debug_log.dart';
import '../network/api_exception.dart';
import '../network/dio_client.dart';
import '../network/error_handler.dart';
import '../utils/logger.dart';
import 'llm_provider.dart';
import 'tool_call_recovery.dart';

class LlmMessage {
  const LlmMessage({
    required this.role,
    this.content = '',
    this.images = const [],
    this.toolCalls = const [],
    this.toolCallId,
    this.name,
  });

  final String role;
  final String content;

  /// 多模态图片，每项是 `data:image/...;base64,...`。
  /// 非空时 `content` 会序列化成 OpenAI 风格的 content 数组。
  final List<String> images;
  final List<LlmToolCall> toolCalls;

  /// role == 'tool' 时必须回填对应的 tool_call.id，否则严格实现的服务端会 400。
  final String? toolCallId;

  /// role == 'tool' 时的工具名（部分服务端要求）。
  final String? name;

  Map<String, dynamic> toJson() => {
        'role': role,
        if (images.isNotEmpty)
          'content': [
            if (content.isNotEmpty) {'type': 'text', 'text': content},
            for (final url in images)
              {
                'type': 'image_url',
                'image_url': {'url': url}
              },
          ]
        else if (content.isNotEmpty || role == 'tool')
          'content': content,
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (name != null) 'name': name,
        if (toolCalls.isNotEmpty)
          'tool_calls': [
            for (final t in toolCalls)
              {
                'id': t.id,
                'type': 'function',
                'function': {
                  'name': t.name,
                  'arguments': jsonEncode(t.arguments),
                },
              },
          ],
      };
}

class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    this.arguments = const {},
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

class LlmFunctionSpec {
  const LlmFunctionSpec({
    required this.name,
    required this.description,
    this.parameters = const {},
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

class LlmConfig {
  const LlmConfig({
    this.baseUrl = '',
    this.model = '',
    this.apiKey = '',
    this.reasoningEffort = 0,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.frequencyPenalty,
    this.presencePenalty,
    this.extraHeaders = const {},
    this.extraBody = const {},
    this.receiveTimeoutSeconds = 180,
    this.protocol = LlmProtocol.openai,
  });

  final String baseUrl;
  final String model;
  final String apiKey;

  /// 0=无/1=低/2=中/3=高，兼容支持 reasoning_effort 的接口。
  final int reasoningEffort;

  /// 采样参数：留 null 表示"不发这个字段"，交给服务端默认值。
  /// 显式发 0 和不发是两回事，所以这里必须可空，不能用 0 当哨兵。
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final double? frequencyPenalty;
  final double? presencePenalty;

  /// 额外请求头（例如某些网关要 X-Title / HTTP-Referer）。
  final Map<String, String> extraHeaders;

  /// 额外 body 字段（透传厂商私有参数，例如 enable_thinking）。
  final Map<String, dynamic> extraBody;

  final int receiveTimeoutSeconds;

  /// 接入协议：OpenAI 兼容还是 Anthropic 原生。
  final LlmProtocol protocol;

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty;
}

class LlmUsage {
  const LlmUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.cacheHitTokens = 0,
    this.cacheMissTokens = 0,
    this.reasoningTokens = 0,
  });

  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  /// DeepSeek / 部分兼容网关会报告提示词缓存命中量。
  /// 命中部分按 1/10 左右计价，是省钱的关键指标，所以单独记账。
  final int cacheHitTokens;
  final int cacheMissTokens;

  /// 思维链消耗（部分厂商在 completion_tokens_details 里给）。
  final int reasoningTokens;

  bool get isEmpty =>
      totalTokens == 0 && promptTokens == 0 && completionTokens == 0;

  /// 缓存命中率，用于界面提示"这轮省了多少"。
  double get cacheRate {
    final base = cacheHitTokens + cacheMissTokens;
    if (base <= 0) return 0;
    return cacheHitTokens / base;
  }

  LlmUsage operator +(LlmUsage other) => LlmUsage(
        promptTokens: promptTokens + other.promptTokens,
        completionTokens: completionTokens + other.completionTokens,
        totalTokens: totalTokens + other.totalTokens,
        cacheHitTokens: cacheHitTokens + other.cacheHitTokens,
        cacheMissTokens: cacheMissTokens + other.cacheMissTokens,
        reasoningTokens: reasoningTokens + other.reasoningTokens,
      );

  factory LlmUsage.fromJson(Map<dynamic, dynamic> json) {
    int pick(List<String> keys) {
      for (final k in keys) {
        final v = json[k];
        if (v is num) return v.toInt();
      }
      return 0;
    }

    final details = json['prompt_tokens_details'];
    final cached =
        details is Map ? (details['cached_tokens'] as num?)?.toInt() ?? 0 : 0;
    final completionDetails = json['completion_tokens_details'];
    final reasoning = completionDetails is Map
        ? (completionDetails['reasoning_tokens'] as num?)?.toInt() ?? 0
        : 0;
    final hit = pick(['prompt_cache_hit_tokens']) != 0
        ? pick(['prompt_cache_hit_tokens'])
        : cached;
    final prompt = pick(['prompt_tokens']);
    return LlmUsage(
      promptTokens: prompt,
      completionTokens: pick(['completion_tokens']),
      totalTokens: pick(['total_tokens']),
      cacheHitTokens: hit,
      cacheMissTokens: pick(['prompt_cache_miss_tokens']) != 0
          ? pick(['prompt_cache_miss_tokens'])
          : (prompt - hit).clamp(0, prompt),
      reasoningTokens: reasoning,
    );
  }
}

class LlmResponse {
  const LlmResponse({
    this.content = '',
    this.reasoningContent = '',
    this.toolCalls = const [],
    this.finishReason = '',
    this.usage = const LlmUsage(),
    this.recoveredToolCalls = false,
    this.brokenToolMarkup = false,
  });

  final String content;
  final String reasoningContent;
  final List<LlmToolCall> toolCalls;
  final String finishReason;
  final LlmUsage usage;

  /// 这些 tool_calls 是从正文里捞回来的（服务端没解析成结构化字段）。
  ///
  /// 排障时要能一眼看出"这轮走的是兜底路径"，否则同一个 bug 只会重新变成
  /// "有时候调用有时候不调用"的玄学。
  final bool recoveredToolCalls;

  /// 正文里有工具调用标记，但一个也没解析出来——格式坏得连兜底都救不回。
  /// 这种轮次绝不能当成"模型答完了"，否则会拿着幻觉输出收工。
  final bool brokenToolMarkup;

  LlmResponse copyWith({
    String? content,
    String? reasoningContent,
    List<LlmToolCall>? toolCalls,
    bool? recoveredToolCalls,
    bool? brokenToolMarkup,
  }) =>
      LlmResponse(
        content: content ?? this.content,
        reasoningContent: reasoningContent ?? this.reasoningContent,
        toolCalls: toolCalls ?? this.toolCalls,
        finishReason: finishReason,
        usage: usage,
        recoveredToolCalls: recoveredToolCalls ?? this.recoveredToolCalls,
        brokenToolMarkup: brokenToolMarkup ?? this.brokenToolMarkup,
      );
}

/// 流式增量：一次 SSE 片段带来的新内容。
///
/// 思考和正文分开送，界面才能把"想"和"说"画成两块；
/// [reset] 表示前面吐出来的那些字作废（重试/降级时用），
/// 否则重试后两次的残句会拼在一起，读起来像模型精神分裂。
class LlmDelta {
  const LlmDelta({
    this.content = '',
    this.reasoning = '',
    this.toolName = '',
    this.reset = false,
  });

  final String content;
  final String reasoning;

  /// 这一片里模型刚开口要调的工具名（拿到函数名那一刻就报，不等参数收完）。
  final String toolName;
  final bool reset;

  bool get isEmpty =>
      !reset && content.isEmpty && reasoning.isEmpty && toolName.isEmpty;
}

/// SSE 分片拼装器：一行一行喂进来，拼出完整的一轮回复。
///
/// 单独成类是为了能被单元测试直接喂假数据——流式最容易碎在
/// "工具参数被切成好几片""index 乱序""delta 里混着 role"这些边角上，
/// 而这些用真实网关根本复现不了。
class LlmStreamAssembler {
  LlmStreamAssembler({this.onDelta});

  final void Function(LlmDelta delta)? onDelta;

  final StringBuffer _content = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();

  /// index → 累积中的工具调用。流式的 arguments 是一串碎片，得按 index 归堆。
  final Map<int, _ToolAccum> _tools = {};

  String _finishReason = '';
  LlmUsage _usage = const LlmUsage();
  bool _sawData = false;
  bool _done = false;

  String get content => _content.toString();
  String get reasoning => LlmClient.sanitizeReasoning(_reasoning.toString());
  String get finishReason => _finishReason;
  LlmUsage get usage => _usage;

  /// 收到过至少一片合法 SSE 数据。false = 对面根本没在流式回话。
  bool get sawData => _sawData;

  /// 见到 `[DONE]`，可以停止读取。
  bool get done => _done;

  List<LlmToolCall> get toolCalls {
    final keys = _tools.keys.toList()..sort();
    final out = <LlmToolCall>[];
    for (final k in keys) {
      final t = _tools[k]!;
      if (t.name.isEmpty) continue;
      out.add(
        LlmToolCall(
          id: t.id,
          name: t.name,
          arguments: LlmClient.decodeToolArguments(t.args.toString()),
        ),
      );
    }
    return out;
  }

  /// 喂一行。返回 true = 这是一行 SSE 数据（已处理），false = 与流式无关。
  bool addLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return false;
    if (text.startsWith(':')) return true; // 心跳注释，忽略但算 SSE 流量
    if (!text.startsWith('data:')) return false;
    final payload = text.substring(5).trim();
    if (payload == '[DONE]') {
      _sawData = true;
      _done = true;
      return true;
    }
    Object? json;
    try {
      json = jsonDecode(payload);
    } catch (_) {
      return true; // 是 data 行但内容坏了：跳过，别让一片碎数据毁掉整轮
    }
    if (json is! Map<String, dynamic>) return true;
    _sawData = true;
    _absorb(json);
    return true;
  }

  void _absorb(Map<String, dynamic> json) {
    final usage = json['usage'];
    if (usage is Map) {
      final parsed = LlmUsage.fromJson(usage);
      if (!parsed.isEmpty) _usage = parsed;
    }
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) return;
    final first = choices.first;
    if (first is! Map) return;
    final reason = first['finish_reason']?.toString() ?? '';
    if (reason.isNotEmpty && reason != 'null') _finishReason = reason;

    // 有的网关最后一片给的是完整 message 而不是 delta。
    final delta = first['delta'] ?? first['message'];
    if (delta is! Map) return;

    var content = '';
    var reasoning = '';
    var newTool = '';

    final c = delta['content'];
    if (c is String && c.isNotEmpty) {
      content = c;
      _content.write(c);
    } else if (c is List) {
      // 多模态分片：[{type: text, text: ...}]
      for (final part in c) {
        if (part is Map && part['text'] is String) {
          content += part['text'] as String;
          _content.write(part['text']);
        }
      }
    }

    // 思考字段各家名字不一样：DeepSeek 用 reasoning_content，
    // 有些网关转成 reasoning，Qwen 系还会塞在 thinking 里。
    for (final key in const ['reasoning_content', 'reasoning', 'thinking']) {
      final r = delta[key];
      if (r is String && r.isNotEmpty) {
        // 第一个分片里如果带了 "thinking"/"思考内容" 这类网关标签，先剥掉。
        if (_reasoning.isEmpty) {
          reasoning = LlmClient.sanitizeReasoning(r);
          if (reasoning.isNotEmpty) _reasoning.write(reasoning);
        } else {
          reasoning = r;
          _reasoning.write(r);
        }
        break;
      }
    }

    final calls = delta['tool_calls'];
    if (calls is List) {
      for (final raw in calls) {
        if (raw is! Map) continue;
        // index 缺省时按出现顺序兜底：某些网关只在第一片给 index。
        final idx = (raw['index'] as num?)?.toInt() ?? _tools.length;
        final t = _tools.putIfAbsent(idx, _ToolAccum.new);
        final id = raw['id']?.toString();
        if (id != null && id.isNotEmpty) t.id = id;
        final fn = raw['function'];
        if (fn is! Map) continue;
        final name = fn['name']?.toString();
        if (name != null && name.isNotEmpty && t.name != name) {
          t.name = name;
          newTool = name;
        }
        final args = fn['arguments'];
        if (args is String && args.isNotEmpty) t.args.write(args);
      }
    }

    final event = LlmDelta(
      content: content,
      reasoning: reasoning,
      toolName: newTool,
    );
    if (!event.isEmpty) onDelta?.call(event);
  }
}

class _ToolAccum {
  String id = '';
  String name = '';
  final StringBuffer args = StringBuffer();
}

/// Anthropic 流式事件装配器。
///
/// 事件形状和 OpenAI 完全不同：没有 `choices[].delta`，而是一串
/// `content_block_delta` / `message_delta`，文本、思考、工具参数分别走
/// `text_delta` / `thinking_delta` / `input_json_delta`。
class AnthropicStreamAssembler {
  AnthropicStreamAssembler({this.onDelta});

  final void Function(LlmDelta delta)? onDelta;

  final StringBuffer _content = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();

  /// index → 累积中的工具调用。Anthropic 按 block index 给分片。
  final Map<int, _ToolAccum> _tools = {};

  String _finishReason = '';
  LlmUsage _usage = const LlmUsage();
  bool _sawData = false;
  bool _done = false;

  String get content => _content.toString();
  String get reasoning => LlmClient.sanitizeReasoning(_reasoning.toString());
  String get finishReason => _finishReason;
  LlmUsage get usage => _usage;
  bool get sawData => _sawData;
  bool get done => _done;

  List<LlmToolCall> get toolCalls {
    final keys = _tools.keys.toList()..sort();
    final out = <LlmToolCall>[];
    for (final k in keys) {
      final t = _tools[k]!;
      if (t.name.isEmpty) continue;
      out.add(
        LlmToolCall(
          id: t.id,
          name: t.name,
          arguments: LlmClient.decodeToolArguments(t.args.toString()),
        ),
      );
    }
    return out;
  }

  bool addLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return false;
    if (text.startsWith(':')) return true;
    if (!text.startsWith('data:')) return false;
    final payload = text.substring(5).trim();
    if (payload.isEmpty || payload == '[DONE]') {
      if (payload == '[DONE]') {
        _sawData = true;
        _done = true;
      }
      return true;
    }
    Object? json;
    try {
      json = jsonDecode(payload);
    } catch (_) {
      return true;
    }
    if (json is! Map<String, dynamic>) return true;
    _sawData = true;
    _absorb(json);
    return true;
  }

  void _absorb(Map<String, dynamic> json) {
    final type = json['type']?.toString();
    switch (type) {
      case 'message_start':
        final msg = json['message'];
        if (msg is Map) {
          final usageRaw = msg['usage'];
          if (usageRaw is Map) _usage = _parseUsage(usageRaw);
        }
        break;
      case 'content_block_start':
        final block = json['content_block'];
        if (block is Map) {
          final index = (json['index'] as num?)?.toInt() ?? _tools.length;
          final blockType = block['type']?.toString();
          if (blockType == 'tool_use') {
            final t = _tools.putIfAbsent(index, _ToolAccum.new);
            t.id = block['id']?.toString() ?? t.id;
            t.name = block['name']?.toString() ?? t.name;
          }
        }
        break;
      case 'content_block_delta':
        final delta = json['delta'];
        if (delta is Map) {
          final index = (json['index'] as num?)?.toInt();
          final deltaType = delta['type']?.toString();
          if (deltaType == 'text_delta') {
            final text = delta['text']?.toString() ?? '';
            if (text.isNotEmpty) {
              _content.write(text);
              onDelta?.call(LlmDelta(content: text));
            }
          } else if (deltaType == 'thinking_delta') {
            final text = delta['thinking']?.toString() ?? '';
            if (text.isNotEmpty) {
              _reasoning.write(text);
              onDelta?.call(LlmDelta(reasoning: text));
            }
          } else if (deltaType == 'input_json_delta') {
            final partial = delta['partial_json']?.toString() ?? '';
            if (partial.isNotEmpty && index != null) {
              _tools.putIfAbsent(index, _ToolAccum.new).args.write(partial);
            }
          }
        }
        break;
      case 'message_delta':
        final delta = json['delta'];
        if (delta is Map) {
          final reason = delta['stop_reason']?.toString() ?? '';
          if (reason.isNotEmpty) _finishReason = reason;
        }
        final usageRaw = json['usage'];
        if (usageRaw is Map) _usage = _parseUsage(usageRaw);
        break;
      case 'message_stop':
        _done = true;
        break;
      case 'error':
        // 错误事件不往外冒，沿用"静默跳过"策略；真正的 HTTP 错误已经在上面拦了。
        break;
    }
  }

  LlmUsage _parseUsage(Map raw) {
    int pick(String key) => (raw[key] as num?)?.toInt() ?? 0;
    final input = pick('input_tokens');
    final output = pick('output_tokens');
    final cacheRead = pick('cache_read_input_tokens');
    final cacheCreation = pick('cache_creation_input_tokens');
    return LlmUsage(
      promptTokens: input,
      completionTokens: output,
      totalTokens: input + output,
      cacheHitTokens: cacheRead,
      cacheMissTokens: cacheCreation,
    );
  }
}


/// Google Gemini 流式事件装配器。
///
/// 每次 SSE data 里是一个 candidate 片段，text 直接给增量，
/// functionCall 一般整块出现，usage 在最后的 usageMetadata 里。
class GoogleStreamAssembler {
  GoogleStreamAssembler({this.onDelta});

  final void Function(LlmDelta delta)? onDelta;

  final StringBuffer _content = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();
  final Map<String, _ToolAccum> _tools = {};
  String _finishReason = '';
  LlmUsage _usage = const LlmUsage();
  bool _sawData = false;
  bool _done = false;

  String get content => _content.toString();
  String get reasoning => LlmClient.sanitizeReasoning(_reasoning.toString());
  String get finishReason => _finishReason;
  LlmUsage get usage => _usage;
  bool get sawData => _sawData;
  bool get done => _done;

  List<LlmToolCall> get toolCalls {
    final out = <LlmToolCall>[];
    for (final t in _tools.values) {
      if (t.name.isEmpty) continue;
      out.add(
        LlmToolCall(
          id: t.id.isEmpty ? 'google_${out.length}' : t.id,
          name: t.name,
          arguments: LlmClient.decodeToolArguments(t.args.toString()),
        ),
      );
    }
    return out;
  }

  bool addLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return false;
    if (text.startsWith(':')) return true;
    if (!text.startsWith('data:')) return false;
    final payload = text.substring(5).trim();
    if (payload.isEmpty) return true;
    Object? json;
    try {
      json = jsonDecode(payload);
    } catch (_) {
      return true;
    }
    if (json is! Map<String, dynamic>) return true;
    _sawData = true;
    _absorb(json);
    return true;
  }

  void _absorb(Map<String, dynamic> json) {
    final candidates = json['candidates'];
    if (candidates is List && candidates.isNotEmpty && candidates.first is Map) {
      final cand = candidates.first as Map;
      final reason = cand['finishReason']?.toString() ?? '';
      if (reason.isNotEmpty && reason != 'null') _finishReason = reason;
      final c = cand['content'];
      if (c is Map) {
        final parts = c['parts'];
        if (parts is List) {
          for (final part in parts) {
            if (part is! Map) continue;
            final text = part['text']?.toString() ?? '';
            if (text.isNotEmpty) {
              _content.write(text);
              onDelta?.call(LlmDelta(content: text));
            }
            final thought = part['thought']?.toString() ?? '';
            if (thought.isNotEmpty) {
              _reasoning.write(thought);
              onDelta?.call(LlmDelta(reasoning: thought));
            }
            final fc = part['functionCall'];
            if (fc is Map) {
              final name = fc['name']?.toString() ?? '';
              if (name.isNotEmpty) {
                final t = _tools.putIfAbsent(name, _ToolAccum.new);
                t.name = name;
                final args = fc['args'];
                if (args is Map || args is List) {
                  t.args.write(jsonEncode(args));
                } else if (args != null) {
                  t.args.write(args.toString());
                }
              }
            }
          }
        }
      }
    }
    final usage = json['usageMetadata'];
    if (usage is Map) {
      final parsed = LlmClient._fromGoogleUsage(usage);
      if (!parsed.isEmpty) _usage = parsed;
    }
  }
}

class LlmClient {
  LlmClient._();

  /// 剥掉网关/模型在 reasoning_content 前面硬塞的标签前缀。
  ///
  /// 常见形态：`thinking\n...`、`thinking 思考内容...`、`Thought: ...`、
  /// `思考\n...`。只剥开头，不影响正文里的同类词。
  /// AI 调试日志：请求体转字符串，避免把整包几 MB 的图片 base64 全塞进内存日志。
  static String _debugDumpBody(Object? body) {
    try {
      final text = jsonEncode(body);
      if (text.length <= 40000) return text;
      return '${text.substring(0, 40000)}\n...[已截断，原长 ${text.length}]';
    } catch (_) {
      return '$body';
    }
  }

  /// AI 调试日志：流式响应把“读到的工具调用”原样拼出来，方便排查上游解析。
  static String _debugDumpResponse({
    required String content,
    required String reasoning,
    required List<LlmToolCall> toolCalls,
    required String finishReason,
  }) {
    final buffer = StringBuffer('finishReason=$finishReason\n');
    if (reasoning.isNotEmpty) {
      buffer.writeln('\n--- 思考 ---\n$reasoning');
    }
    if (content.isNotEmpty) {
      buffer.writeln('\n--- 正文 ---\n$content');
    }
    if (toolCalls.isNotEmpty) {
      buffer.writeln('\n--- 工具调用 ---');
      for (var i = 0; i < toolCalls.length; i++) {
        final c = toolCalls[i];
        buffer.writeln(
            '[$i] name=${c.name} id=${c.id} args=${_debugDumpBody(c.arguments)}');
      }
    } else {
      buffer.writeln('\n--- 工具调用 --- (空)');
    }
    final text = buffer.toString();
    if (text.length <= 40000) return text;
    return '${text.substring(0, 40000)}\n...[已截断，原长 ${text.length}]';
  }

  static String sanitizeReasoning(String raw) {
    var text = raw.trimLeft();
    final label = RegExp(
      r'^(thinking|thought|reasoning|思考|思考内容|推理过程|推理内容)',
      caseSensitive: false,
    );
    var guard = 0;
    while (text.isNotEmpty && guard++ < 8) {
      final m = label.firstMatch(text);
      if (m == null) break;
      final after = text.substring(m.end);
      if (after.isEmpty) {
        text = '';
        break;
      }
      final next = after.codeUnitAt(0);
      final isSep = RegExp(r'[\s:：\-_，,、.。!！?？]').hasMatch(after[0]);
      final isCjk = next >= 0x4E00 && next <= 0x9FFF;
      if (!isSep && !isCjk) break; // 后面紧跟英文字母，不是标签
      text = after.replaceFirst(RegExp(r'^[\s:：\-_，,、.。]+'), '');
    }
    return text;
  }

  static String _base(String baseUrl) {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/chat/completions')) {
      return base.replaceAll(RegExp(r'/chat/completions$'), '');
    }
    // 有的厂商不是 /v1：智谱是 /api/paas/v4，阿里兼容是 /compatible-mode/v1，
    // 已经带 v1/v2/v3/v4 版本号时不要再硬拼 /v1。
    if (RegExp(r'/(v\d+)$').hasMatch(base)) return base;
    return '$base/v1';
  }

  static String _endpoint(String baseUrl) {
    final base = _base(baseUrl);
    return '$base/chat/completions';
  }

  /// Anthropic Messages API 端点。
  static String _anthropicEndpoint(String baseUrl) {
    final raw = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (raw.endsWith('/v1/messages')) return raw;
    if (raw.endsWith('/messages')) return raw;
    if (raw.endsWith('/v1')) return '$raw/messages';
    return '$raw/v1/messages';
  }

  static Map<String, String> _anthropicHeaders(LlmConfig config) => {
        'x-api-key': config.apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
        ...config.extraHeaders,
      };

  /// Google Gemini 端点。baseUrl 一般已带版本（如 /v1beta）。
  static String _googleGenerateEndpoint(
    String baseUrl,
    String model, {
    bool stream = false,
  }) {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final path = '/models/${Uri.encodeComponent(model)}'
        ':${stream ? 'streamGenerateContent' : 'generateContent'}'
        '${stream ? '?alt=sse' : ''}';
    return '$base$path';
  }

  static Map<String, String> _googleHeaders(LlmConfig config) => {
        'x-goog-api-key': config.apiKey,
        'content-type': 'application/json',
        ...config.extraHeaders,
      };

  static Future<LlmResponse> complete({
    required LlmConfig config,
    required List<LlmMessage> messages,
    List<LlmFunctionSpec>? tools,
    int maxRetries = 2,
    CancelToken? cancelToken,
    void Function(LlmDelta delta)? onDelta,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        // 重试前先让界面把上一次吐出来的残句擦掉，否则两次的文字会接在一起。
        if (attempt > 0) onDelta?.call(const LlmDelta(reset: true));
        return await _completeOnce(
          config: config,
          messages: messages,
          tools: tools,
          cancelToken: cancelToken,
          onDelta: onDelta,
        );
      } on ApiException catch (e) {
        lastError = e;
        // 鉴权、参数、DNS 解析失败重试都没意义；只对超时、5xx、429 这类瞬时故障重试。
        final code = e.statusCode;
        // 手机端刚从后台切回来时 DNS/连接常有一次瞬时失败，网络类错误也值得重试。
        // 用户主动取消不能重试，否则"停止"要等好几轮才生效。
        if (cancelToken?.isCancelled ?? false) rethrow;
        final retryable = e.type == ApiExceptionType.timeout ||
            e.type == ApiExceptionType.network ||
            code == 429 ||
            (code != null && code >= 500);
        if (!retryable || attempt == maxRetries) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 800 * (attempt + 1)));
      }
    }
    throw lastError is ApiException
        ? lastError
        : const ApiException(message: 'LLM 请求失败');
  }

  /// 每个端点的流式能力：0 = 流式 + usage，1 = 流式但不带 stream_options，
  /// 2 = 只能非流式。网关五花八门，探到不支持就降级并记住，
  /// 别每一轮都去撞同一面墙（每次撞墙都是一次真实计费请求）。
  static final Map<String, int> _streamMode = {};

  static Future<LlmResponse> _completeOnce({
    required LlmConfig config,
    required List<LlmMessage> messages,
    List<LlmFunctionSpec>? tools,
    CancelToken? cancelToken,
    void Function(LlmDelta delta)? onDelta,
  }) async {
    if (!config.isConfigured) {
      throw const ApiException(
          message: '请先在设置中配置 LLM Base URL / Model / API Key');
    }
    if (config.protocol == LlmProtocol.anthropic) {
      final endpoint = _anthropicEndpoint(config.baseUrl);
      if (onDelta == null) {
        return _anthropicJsonOnce(
          config: config,
          messages: messages,
          tools: tools,
          cancelToken: cancelToken,
          endpoint: endpoint,
        );
      }
      return _anthropicStreamOnce(
        config: config,
        messages: messages,
        tools: tools,
        cancelToken: cancelToken,
        endpoint: endpoint,
        onDelta: onDelta,
      );
    }
    if (config.protocol == LlmProtocol.google) {
      return _googleComplete(
        config: config,
        messages: messages,
        tools: tools,
        cancelToken: cancelToken,
        onDelta: onDelta,
      );
    }
    final endpoint = _endpoint(config.baseUrl);
    if (onDelta == null) {
      return _jsonOnce(
        config: config,
        messages: messages,
        tools: tools,
        cancelToken: cancelToken,
        endpoint: endpoint,
      );
    }
    final modeKey = '$endpoint|${config.model}';
    while ((_streamMode[modeKey] ?? 0) < 2) {
      final mode = _streamMode[modeKey] ?? 0;
      try {
        return await _streamOnce(
          config: config,
          messages: messages,
          tools: tools,
          cancelToken: cancelToken,
          endpoint: endpoint,
          modeKey: modeKey,
          includeUsage: mode == 0,
          onDelta: onDelta,
        );
      } on ApiException catch (e) {
        if (cancelToken?.isCancelled ?? false) rethrow;
        // 只有"参数不认"这类确定性失败才降级。超时/限流/5xx 是抖动，
        // 降级成非流式并不会让它变好，还会把流式能力永久误判成不支持。
        final code = e.statusCode;
        final paramIssue = code != null &&
            code >= 400 &&
            code < 500 &&
            code != 401 &&
            code != 403 &&
            code != 429;
        if (!paramIssue) rethrow;
        _streamMode[modeKey] = mode + 1;
        ApiDebugLog.instance.add(
          kind: ApiDebugKind.error,
          method: 'POST',
          uri: endpoint,
          message: mode == 0
              ? '流式请求被拒（HTTP $code），去掉 stream_options 再试'
              : '流式请求不被支持（HTTP $code），本端点降级为非流式',
          detail: e.message,
        );
        onDelta(const LlmDelta(reset: true));
      }
    }
    return _jsonOnce(
      config: config,
      messages: messages,
      tools: tools,
      cancelToken: cancelToken,
      endpoint: endpoint,
    );
  }

  /// 请求体。流式与非流式只差 stream 相关字段，其余必须一模一样，
  /// 否则降级那一轮的行为会和平时不一致——这种差异最难查。
  static Map<String, dynamic> _requestBody({
    required LlmConfig config,
    required List<LlmMessage> messages,
    List<LlmFunctionSpec>? tools,
    bool stream = false,
    bool includeUsage = false,
  }) {
    final imageMessages = messages.where((m) => m.images.isNotEmpty).length;
    if (imageMessages > 0) {
      final first = messages.firstWhere((m) => m.images.isNotEmpty);
      final firstUri = first.images.first;
      Logger.d(
          'llm',
          'multimodal request model=${config.model} '
              'imageMessages=$imageMessages dataUriLength=${firstUri.length}');
    }
    return {
      'model': config.model,
      if (config.reasoningEffort > 0)
        'reasoning_effort': switch (config.reasoningEffort) {
          1 => 'low',
          2 => 'medium',
          _ => 'high',
        },
      if (config.temperature != null) 'temperature': config.temperature,
      if (config.topP != null) 'top_p': config.topP,
      if (config.maxTokens != null) 'max_tokens': config.maxTokens,
      if (config.frequencyPenalty != null)
        'frequency_penalty': config.frequencyPenalty,
      if (config.presencePenalty != null)
        'presence_penalty': config.presencePenalty,
      ...config.extraBody,
      'messages': [for (final m in messages) m.toJson()],
      if (tools != null && tools.isNotEmpty)
        'tools': [
          for (final t in tools)
            {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.parameters,
              },
            },
        ],
      if (stream) 'stream': true,
      // 流式默认不报 usage，得显式要一份，否则计费和上下文占用全是 0。
      if (stream && includeUsage) 'stream_options': {'include_usage': true},
    };
  }

  /// Anthropic Messages API 请求体。
  static Map<String, dynamic> _anthropicRequestBody({
    required LlmConfig config,
    required List<LlmMessage> messages,
    List<LlmFunctionSpec>? tools,
    bool stream = false,
  }) {
    final system = <String>[];
    final converted = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m.role == 'system') {
        if (m.content.trim().isNotEmpty) system.add(m.content.trim());
        continue;
      }
      final blocks = <Map<String, dynamic>>[];
      if (m.role == 'tool') {
        blocks.add({
          'type': 'tool_result',
          'tool_use_id': m.toolCallId ?? '',
          'content': m.content,
        });
        converted.add({'role': 'user', 'content': blocks});
        continue;
      }
      for (final uri in m.images) {
        final parsed = _parseDataUri(uri);
        if (parsed != null) {
          blocks.add({
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': parsed[0],
              'data': parsed[1],
            },
          });
        }
      }
      if (m.content.trim().isNotEmpty) {
        blocks.add({'type': 'text', 'text': m.content});
      }
      for (final t in m.toolCalls) {
        blocks.add({
          'type': 'tool_use',
          'id': t.id,
          'name': t.name,
          'input': t.arguments,
        });
      }
      if (blocks.isEmpty) continue;
      converted.add({
        'role': m.role == 'assistant' ? 'assistant' : 'user',
        'content': blocks,
      });
    }
    // Anthropic 严格要求 user/assistant 交替；连续同角色消息合并成一条。
    final messagesOut = <Map<String, dynamic>>[];
    for (final msg in converted) {
      if (messagesOut.isNotEmpty && messagesOut.last['role'] == msg['role']) {
        final prev = messagesOut.last['content'] as List;
        messagesOut.last['content'] = [...prev, ...(msg['content'] as List)];
      } else {
        messagesOut.add(msg);
      }
    }
    return {
      'model': config.model,
      'max_tokens': config.maxTokens ?? 4096,
      if (config.temperature != null) 'temperature': config.temperature,
      if (config.topP != null) 'top_p': config.topP,
      ...config.extraBody,
      if (system.isNotEmpty) 'system': system.join('\n\n'),
      'messages': messagesOut,
      if (tools != null && tools.isNotEmpty)
        'tools': [
          for (final t in tools)
            {
              'name': t.name,
              'description': t.description,
              'input_schema': t.parameters,
            },
        ],
      if (stream) 'stream': true,
    };
  }

  /// Google Gemini 请求体。
  static Map<String, dynamic> _googleRequestBody({
    required LlmConfig config,
    required List<LlmMessage> messages,
    List<LlmFunctionSpec>? tools,
  }) {
    final systemParts = <Map<String, dynamic>>[];
    final contents = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m.role == 'system') {
        if (m.content.trim().isNotEmpty) {
          systemParts.add({'text': m.content});
        }
        continue;
      }
      final parts = <Map<String, dynamic>>[];
      if (m.role == 'tool') {
        parts.add({
          'functionResponse': {
            'name': m.name ?? '',
            'response': {'result': m.content},
          },
        });
      } else {
        for (final uri in m.images) {
          final parsed = _parseDataUri(uri);
          if (parsed != null) {
            parts.add({
              'inlineData': {
                'mimeType': parsed[0],
                'data': parsed[1],
              },
            });
          }
        }
        if (m.content.trim().isNotEmpty) {
          parts.add({'text': m.content});
        }
        for (final t in m.toolCalls) {
          parts.add({
            'functionCall': {
              'name': t.name,
              'args': t.arguments,
            },
          });
        }
      }
      if (parts.isEmpty) continue;
      contents.add({
        'role': m.role == 'assistant' ? 'model' : 'user',
        'parts': parts,
      });
    }
    return {
      if (systemParts.isNotEmpty) 'systemInstruction': {'parts': systemParts},
      'contents': contents,
      if (tools != null && tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': [
              for (final t in tools)
                {
                  'name': t.name,
                  'description': t.description,
                  'parameters': t.parameters,
                },
            ],
          },
        ],
      'generationConfig': {
        if (config.temperature != null) 'temperature': config.temperature,
        if (config.topP != null) 'topP': config.topP,
        if (config.maxTokens != null)
          'maxOutputTokens': config.maxTokens,
        ...config.extraBody,
      },
    };
  }

  /// data:image/png;base64,xxx → [mediaType, data]。
  static List<String>? _parseDataUri(String uri) {
    if (!uri.startsWith('data:')) return null;
    final comma = uri.indexOf(',');
    if (comma < 0) return null;
    final meta = uri.substring(5, comma);
    final data = uri.substring(comma + 1);
    final semicolon = meta.indexOf(';');
    final mime = semicolon >= 0 ? meta.substring(0, semicolon) : meta;
    if (mime.isEmpty || data.isEmpty) return null;
    return [mime, data];
  }

  /// 流式一轮：边收边把增量交给 [onDelta]，收完拼成完整回复。
  ///
  /// 这是"思考过程要冒多少显示多少"的地基：非流式下整轮几十秒界面全无动静，
  /// 用户只能看到最后一次性刷出来的结果。
  static Future<LlmResponse> _streamOnce({
    required LlmConfig config,
    required List<LlmMessage> messages,
    required String endpoint,
    required String modeKey,
    required bool includeUsage,
    required void Function(LlmDelta delta) onDelta,
    List<LlmFunctionSpec>? tools,
    CancelToken? cancelToken,
  }) async {
    final Response<ResponseBody> response;
    final requestBody = _requestBody(
      config: config,
      messages: messages,
      tools: tools,
      stream: true,
      includeUsage: includeUsage,
    );
    if (ApiDebugLog.enabled) {
      ApiDebugLog.instance.add(
        kind: ApiDebugKind.request,
        method: 'POST',
        uri: endpoint,
        message: 'AI 请求（流式）${config.model}',
        detail: _debugDumpBody(requestBody),
      );
    }
    try {
      response = await DioClient.dio.post<ResponseBody>(
        endpoint,
        cancelToken: cancelToken,
        options: Options(
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Accept': 'text/event-stream',
            ...config.extraHeaders,
          },
          extra: {'isAuthRequest': true},
          responseType: ResponseType.stream,
          sendTimeout: const Duration(seconds: 30),
          // 流式下 receiveTimeout 是"两片之间"的静默上限，不是整轮上限，
          // 所以这个值可以照旧用配置里的秒数。
          receiveTimeout: Duration(seconds: config.receiveTimeoutSeconds),
          // 4xx 的原因写在响应体里，而流式响应体是个 stream：
          // 交给 Dio 直接抛异常，手上就只剩一个 ResponseBody，读不出错误详情。
          validateStatus: (_) => true,
        ),
        data: requestBody,
      );
    } on DioException catch (e) {
      throw _mapLlmError(e);
    }
    final body = response.data;
    if (body == null) {
      throw const ApiException(
        message: 'AI 服务没有返回响应体',
        type: ApiExceptionType.network,
      );
    }
    final status = response.statusCode ?? 0;
    Logger.d('llm', 'stream open: mode=${includeUsage ? 0 : 1} http=$status');
    if (status < 200 || status >= 300) {
      throw _statusException(status, _errorDetail(await _drain(body)));
    }

    final assembler = LlmStreamAssembler(onDelta: onDelta);
    final raw = StringBuffer();
    // 只数条数、不记内容：流式一旦悄悄退化成"整轮结束才出字"，
    // 有这两个数就能立刻分清是网关没流、还是界面没刷。
    var sseLines = 0;
    var otherLines = 0;
    try {
      final lines =
          utf8.decoder.bind(body.stream).transform(const LineSplitter());
      await for (final line in lines) {
        if (!assembler.addLine(line)) {
          // 不是 SSE 数据行：留着。万一网关压根没理 stream 参数，
          // 收尾时还能把它当普通 JSON body 解析回来。
          otherLines++;
          if (raw.length < 200000) raw.write(line);
          continue;
        }
        sseLines++;
        if (assembler.done) break;
      }
    } on DioException catch (e) {
      throw _mapLlmError(e);
    }
    Logger.d(
      'llm',
      'stream done: sse=$sseLines other=$otherLines '
          'reasoning=${assembler.reasoning.length} '
          'content=${assembler.content.length} '
          'tools=${assembler.toolCalls.length}',
    );

    if (!assembler.sawData) {
      // 网关无视了 stream 参数，回了一整个 JSON。记下来别再走流式；
      // 这一轮用普通解析救回来，不能让用户白等一轮再看到空回复。
      _streamMode[modeKey] = 2;
      try {
        return _fromJsonBody(jsonDecode(raw.toString()), endpoint);
      } catch (_) {
        return _jsonOnce(
          config: config,
          messages: messages,
          tools: tools,
          cancelToken: cancelToken,
          endpoint: endpoint,
        );
      }
    }
    final result = _finalize(
      endpoint: endpoint,
      content: assembler.content,
      reasoningContent: assembler.reasoning,
      toolCalls: assembler.toolCalls,
      finishReason: assembler.finishReason,
      usage: assembler.usage,
    );
    if (ApiDebugLog.enabled) {
      ApiDebugLog.instance.add(
        kind: ApiDebugKind.response,
        method: 'POST',
        uri: endpoint,
        statusCode: status,
        message: 'AI 响应（流式）${config.model}',
        detail: _debugDumpResponse(
          content: result.content,
          reasoning: result.reasoningContent,
          toolCalls: result.toolCalls,
          finishReason: result.finishReason,
        ),
      );
    }
    return result;
  }

  /// 非流式一轮。流式不被支持、或调用方不需要增量时走这里。
  static Future<LlmResponse> _jsonOnce({
    required LlmConfig config,
    required List<LlmMessage> messages,
    required String endpoint,
    List<LlmFunctionSpec>? tools,
    CancelToken? cancelToken,
  }) async {
    final requestBody = _requestBody(
      config: config,
      messages: messages,
      tools: tools,
    );
    if (ApiDebugLog.enabled) {
      ApiDebugLog.instance.add(
        kind: ApiDebugKind.request,
        method: 'POST',
        uri: endpoint,
        message: 'AI 请求 ${config.model}',
        detail: _debugDumpBody(requestBody),
      );
    }
    try {
      final response = await DioClient.dio.post<dynamic>(
        endpoint,
        // 带上 CancelToken：点"停止"必须能把正在飞的这次请求直接掐掉，
        // 否则最长要等一次 180 秒的 receiveTimeout 才会有反应。
        cancelToken: cancelToken,
        options: Options(
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            ...config.extraHeaders,
          },
          extra: {'isAuthRequest': true},
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: Duration(seconds: config.receiveTimeoutSeconds),
        ),
        data: requestBody,
      );
      if (ApiDebugLog.enabled) {
        ApiDebugLog.instance.add(
          kind: ApiDebugKind.response,
          method: 'POST',
          uri: endpoint,
          statusCode: response.statusCode,
          message: 'AI 响应 ${config.model}',
          detail: _debugDumpBody(response.data),
        );
      }
      return _fromJsonBody(response.data, endpoint);
    } on DioException catch (e) {
      throw _mapLlmError(e);
    }
  }

  /// Anthropic 非流式一轮。
  static Future<LlmResponse> _anthropicJsonOnce({
    required LlmConfig config,
    required List<LlmMessage> messages,
    required String endpoint,
    List<LlmFunctionSpec>? tools,
    CancelToken? cancelToken,
  }) async {
    final requestBody = _anthropicRequestBody(
      config: config,
      messages: messages,
      tools: tools,
    );
    if (ApiDebugLog.enabled) {
      ApiDebugLog.instance.add(
        kind: ApiDebugKind.request,
        method: 'POST',
        uri: endpoint,
        message: 'AI 请求（Anthropic）${config.model}',
        detail: _debugDumpBody(requestBody),
      );
    }
    try {
      final response = await DioClient.dio.post<dynamic>(
        endpoint,
        cancelToken: cancelToken,
        options: Options(
          headers: _anthropicHeaders(config),
          extra: {'isAuthRequest': true},
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: Duration(seconds: config.receiveTimeoutSeconds),
        ),
        data: requestBody,
      );
      if (ApiDebugLog.enabled) {
        ApiDebugLog.instance.add(
          kind: ApiDebugKind.response,
          method: 'POST',
          uri: endpoint,
          statusCode: response.statusCode,
          message: 'AI 响应（Anthropic）${config.model}',
          detail: _debugDumpBody(response.data),
        );
      }
      return _fromAnthropicJsonBody(response.data, endpoint);
    } on DioException catch (e) {
      throw _mapLlmError(e);
    }
  }

  /// Anthropic 流式一轮。
  static Future<LlmResponse> _anthropicStreamOnce({
    required LlmConfig config,
    required List<LlmMessage> messages,
    required String endpoint,
    required void Function(LlmDelta delta) onDelta,
    List<LlmFunctionSpec>? tools,
    CancelToken? cancelToken,
  }) async {
    final requestBody = _anthropicRequestBody(
      config: config,
      messages: messages,
      tools: tools,
      stream: true,
    );
    if (ApiDebugLog.enabled) {
      ApiDebugLog.instance.add(
        kind: ApiDebugKind.request,
        method: 'POST',
        uri: endpoint,
        message: 'AI 请求（Anthropic 流式）${config.model}',
        detail: _debugDumpBody(requestBody),
      );
    }
    final Response<ResponseBody> response;
    try {
      response = await DioClient.dio.post<ResponseBody>(
        endpoint,
        cancelToken: cancelToken,
        options: Options(
          headers: {
            ..._anthropicHeaders(config),
            'Accept': 'text/event-stream',
          },
          extra: {'isAuthRequest': true},
          responseType: ResponseType.stream,
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: Duration(seconds: config.receiveTimeoutSeconds),
          validateStatus: (_) => true,
        ),
        data: requestBody,
      );
    } on DioException catch (e) {
      throw _mapLlmError(e);
    }
    final body = response.data;
    if (body == null) {
      throw const ApiException(
        message: 'AI 服务没有返回响应体',
        type: ApiExceptionType.network,
      );
    }
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw _statusException(status, _errorDetail(await _drain(body)));
    }

    final assembler = AnthropicStreamAssembler(onDelta: onDelta);
    final raw = StringBuffer();
    try {
      final lines =
          utf8.decoder.bind(body.stream).transform(const LineSplitter());
      await for (final line in lines) {
        if (!assembler.addLine(line)) {
          if (raw.length < 200000) raw.write(line);
          continue;
        }
        if (assembler.done) break;
      }
    } on DioException catch (e) {
      throw _mapLlmError(e);
    }

    if (!assembler.sawData) {
      try {
        return _fromAnthropicJsonBody(jsonDecode(raw.toString()), endpoint);
      } catch (_) {
        return _anthropicJsonOnce(
          config: config,
          messages: messages,
          tools: tools,
          cancelToken: cancelToken,
          endpoint: endpoint,
        );
      }
    }
    final result = _finalize(
      endpoint: endpoint,
      content: assembler.content,
      reasoningContent: assembler.reasoning,
      toolCalls: assembler.toolCalls,
      finishReason: assembler.finishReason,
      usage: assembler.usage,
    );
    if (ApiDebugLog.enabled) {
      ApiDebugLog.instance.add(
        kind: ApiDebugKind.response,
        method: 'POST',
        uri: endpoint,
        statusCode: status,
        message: 'AI 响应（Anthropic 流式）${config.model}',
        detail: _debugDumpResponse(
          content: result.content,
          reasoning: result.reasoningContent,
          toolCalls: result.toolCalls,
          finishReason: result.finishReason,
        ),
      );
    }
    return result;
  }

  /// Google Gemini 统一入口：按是否需要增量选流式/非流式。
  static Future<LlmResponse> _googleComplete({
    required LlmConfig config,
    required List<LlmMessage> messages,
    required List<LlmFunctionSpec>? tools,
    CancelToken? cancelToken,
    void Function(LlmDelta delta)? onDelta,
  }) async {
    final endpoint = _googleGenerateEndpoint(
      config.baseUrl,
      config.model,
      stream: onDelta != null,
    );
    if (onDelta == null) {
      return _googleJsonOnce(
        config: config,
        messages: messages,
        tools: tools,
        cancelToken: cancelToken,
        endpoint: endpoint,
      );
    }
    return _googleStreamOnce(
      config: config,
      messages: messages,
      tools: tools,
      cancelToken: cancelToken,
      endpoint: endpoint,
      onDelta: onDelta,
    );
  }

  static Future<LlmResponse> _googleJsonOnce({
    required LlmConfig config,
    required List<LlmMessage> messages,
    required String endpoint,
    List<LlmFunctionSpec>? tools,
    CancelToken? cancelToken,
  }) async {
    final requestBody = _googleRequestBody(
      config: config,
      messages: messages,
      tools: tools,
    );
    if (ApiDebugLog.enabled) {
      ApiDebugLog.instance.add(
        kind: ApiDebugKind.request,
        method: 'POST',
        uri: endpoint,
        message: 'AI 请求（Google）${config.model}',
        detail: _debugDumpBody(requestBody),
      );
    }
    try {
      final response = await DioClient.dio.post<dynamic>(
        endpoint,
        cancelToken: cancelToken,
        options: Options(
          headers: _googleHeaders(config),
          extra: {'isAuthRequest': true},
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: Duration(seconds: config.receiveTimeoutSeconds),
        ),
        data: requestBody,
      );
      if (ApiDebugLog.enabled) {
        ApiDebugLog.instance.add(
          kind: ApiDebugKind.response,
          method: 'POST',
          uri: endpoint,
          statusCode: response.statusCode,
          message: 'AI 响应（Google）${config.model}',
          detail: _debugDumpBody(response.data),
        );
      }
      return _fromGoogleJsonBody(response.data, endpoint);
    } on DioException catch (e) {
      throw _mapLlmError(e);
    }
  }

  static Future<LlmResponse> _googleStreamOnce({
    required LlmConfig config,
    required List<LlmMessage> messages,
    required String endpoint,
    required void Function(LlmDelta delta) onDelta,
    List<LlmFunctionSpec>? tools,
    CancelToken? cancelToken,
  }) async {
    final requestBody = _googleRequestBody(
      config: config,
      messages: messages,
      tools: tools,
    );
    if (ApiDebugLog.enabled) {
      ApiDebugLog.instance.add(
        kind: ApiDebugKind.request,
        method: 'POST',
        uri: endpoint,
        message: 'AI 请求（Google 流式）${config.model}',
        detail: _debugDumpBody(requestBody),
      );
    }
    final Response<ResponseBody> response;
    try {
      response = await DioClient.dio.post<ResponseBody>(
        endpoint,
        cancelToken: cancelToken,
        options: Options(
          headers: {
            ..._googleHeaders(config),
            'Accept': 'text/event-stream',
          },
          extra: {'isAuthRequest': true},
          responseType: ResponseType.stream,
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: Duration(seconds: config.receiveTimeoutSeconds),
          validateStatus: (_) => true,
        ),
        data: requestBody,
      );
    } on DioException catch (e) {
      throw _mapLlmError(e);
    }
    final body = response.data;
    if (body == null) {
      throw const ApiException(
        message: 'AI 服务没有返回响应体',
        type: ApiExceptionType.network,
      );
    }
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw _statusException(status, _errorDetail(await _drain(body)));
    }
    final assembler = GoogleStreamAssembler(onDelta: onDelta);
    final raw = StringBuffer();
    try {
      final lines =
          utf8.decoder.bind(body.stream).transform(const LineSplitter());
      await for (final line in lines) {
        if (!assembler.addLine(line)) {
          if (raw.length < 200000) raw.write(line);
          continue;
        }
        if (assembler.done) break;
      }
    } on DioException catch (e) {
      throw _mapLlmError(e);
    }
    if (!assembler.sawData) {
      try {
        return _fromGoogleJsonBody(jsonDecode(raw.toString()), endpoint);
      } catch (_) {
        return _googleJsonOnce(
          config: config,
          messages: messages,
          tools: tools,
          cancelToken: cancelToken,
          endpoint: endpoint,
        );
      }
    }
    final result = _finalize(
      endpoint: endpoint,
      content: assembler.content,
      reasoningContent: assembler.reasoning,
      toolCalls: assembler.toolCalls,
      finishReason: assembler.finishReason,
      usage: assembler.usage,
    );
    if (ApiDebugLog.enabled) {
      ApiDebugLog.instance.add(
        kind: ApiDebugKind.response,
        method: 'POST',
        uri: endpoint,
        statusCode: status,
        message: 'AI 响应（Google 流式）${config.model}',
        detail: _debugDumpResponse(
          content: result.content,
          reasoning: result.reasoningContent,
          toolCalls: result.toolCalls,
          finishReason: result.finishReason,
        ),
      );
    }
    return result;
  }

  /// 解析 Google Gemini 非流式响应体。
  static LlmResponse _fromGoogleJsonBody(Object? data, String endpoint) {
    final body = data is Map<String, dynamic> ? data : null;
    final candidates = body?['candidates'];
    final content = StringBuffer();
    final reasoning = StringBuffer();
    final toolCalls = <LlmToolCall>[];
    if (candidates is List && candidates.isNotEmpty && candidates.first is Map) {
      final cand = candidates.first as Map;
      final finish = cand['finishReason']?.toString() ?? '';
      final c = cand['content'];
      if (c is Map) {
        final parts = c['parts'];
        if (parts is List) {
          for (final part in parts) {
            if (part is! Map) continue;
            final text = part['text']?.toString() ?? '';
            if (text.isNotEmpty) content.write(text);
            final thought = part['thought']?.toString() ?? '';
            if (thought.isNotEmpty) reasoning.write(thought);
            final fc = part['functionCall'];
            if (fc is Map) {
              final args = fc['args'];
              toolCalls.add(
                LlmToolCall(
                  id: 'google_${toolCalls.length}',
                  name: fc['name']?.toString() ?? '',
                  arguments: args is Map<String, dynamic>
                      ? args
                      : decodeToolArguments(args?.toString() ?? '{}'),
                ),
              );
            }
          }
        }
      }
      final usageRaw = body?['usageMetadata'];
      final usage = _fromGoogleUsage(usageRaw);
      return _finalize(
        endpoint: endpoint,
        content: content.toString(),
        reasoningContent: LlmClient.sanitizeReasoning(reasoning.toString()),
        toolCalls: toolCalls,
        finishReason: finish,
        usage: usage,
      );
    }
    return const LlmResponse();
  }

  static LlmUsage _fromGoogleUsage(Object? raw) {
    if (raw is! Map) return const LlmUsage();
    int pick(String key) => (raw[key] as num?)?.toInt() ?? 0;
    final prompt = pick('promptTokenCount');
    final completion = pick('candidatesTokenCount');
    return LlmUsage(
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: pick('totalTokenCount'),
      cacheHitTokens: pick('cachedContentTokenCount'),
    );
  }

  /// 解析非流式响应体。
  static LlmResponse _fromJsonBody(Object? data, String endpoint) {
    final choices =
        data is Map<String, dynamic> ? data['choices'] as List? : null;
    if (choices == null || choices.isEmpty) return const LlmResponse();
    final first = choices.first;
    if (first is! Map<String, dynamic>) return const LlmResponse();
    final message = first['message'] as Map<String, dynamic>?;
    if (message == null) return const LlmResponse();
    final usageRaw = (data as Map)['usage'];
    return _finalize(
      endpoint: endpoint,
      content: message['content']?.toString() ?? '',
      reasoningContent: LlmClient.sanitizeReasoning(
        message['reasoning_content']?.toString() ??
            message['reasoning']?.toString() ??
            '',
      ),
      toolCalls: parseToolCalls(message['tool_calls']),
      finishReason: first['finish_reason']?.toString() ?? '',
      usage: usageRaw is Map ? LlmUsage.fromJson(usageRaw) : const LlmUsage(),
    );
  }

  /// 解析 Anthropic Messages API 非流式响应体。
  static LlmResponse _fromAnthropicJsonBody(Object? data, String endpoint) {
    final body = data is Map<String, dynamic> ? data : null;
    final contentRaw = body?['content'];
    final content = StringBuffer();
    final reasoning = StringBuffer();
    final toolCalls = <LlmToolCall>[];
    if (contentRaw is List) {
      for (final item in contentRaw) {
        if (item is! Map) continue;
        final type = item['type']?.toString();
        if (type == 'text') {
          final text = item['text']?.toString() ?? '';
          if (text.isNotEmpty) content.write(text);
        } else if (type == 'thinking') {
          final text = item['thinking']?.toString() ?? '';
          if (text.isNotEmpty) reasoning.write(text);
        } else if (type == 'tool_use') {
          final input = item['input'];
          toolCalls.add(
            LlmToolCall(
              id: item['id']?.toString() ?? '',
              name: item['name']?.toString() ?? '',
              arguments: input is Map<String, dynamic>
                  ? input
                  : decodeToolArguments(input?.toString() ?? '{}'),
            ),
          );
        }
      }
    }
    final usageRaw = body?['usage'];
    final usage = _fromAnthropicUsage(usageRaw);
    return _finalize(
      endpoint: endpoint,
      content: content.toString(),
      reasoningContent: LlmClient.sanitizeReasoning(reasoning.toString()),
      toolCalls: toolCalls,
      finishReason: _mapAnthropicStopReason(body?['stop_reason']?.toString() ?? ''),
      usage: usage,
    );
  }

  static LlmUsage _fromAnthropicUsage(Object? raw) {
    if (raw is! Map) return const LlmUsage();
    int pick(String key) => (raw[key] as num?)?.toInt() ?? 0;
    final input = pick('input_tokens');
    final output = pick('output_tokens');
    final cacheRead = pick('cache_read_input_tokens');
    final cacheCreation = pick('cache_creation_input_tokens');
    return LlmUsage(
      promptTokens: input,
      completionTokens: output,
      totalTokens: input + output,
      cacheHitTokens: cacheRead,
      cacheMissTokens: cacheCreation,
    );
  }

  static String _mapAnthropicStopReason(String reason) => switch (reason) {
        'tool_use' => 'tool_calls',
        'max_tokens' => 'length',
        'stop_sequence' => 'stop',
        _ => 'stop',
      };

  /// 解析结构化 tool_calls（非流式那份；流式的分片拼装在 [LlmStreamAssembler]）。
  static List<LlmToolCall> parseToolCalls(Object? raw) {
    final toolCalls = <LlmToolCall>[];
    if (raw is! List) return toolCalls;
    for (final item in raw) {
      if (item is! Map) continue;
      final fn = item['function'];
      if (fn is! Map) continue;
      toolCalls.add(
        LlmToolCall(
          id: item['id']?.toString() ?? '',
          name: fn['name']?.toString() ?? '',
          arguments: decodeToolArguments(fn['arguments']?.toString() ?? '{}'),
        ),
      );
    }
    return toolCalls;
  }

  /// 工具参数是一段 JSON 文本。解析不了也不能丢——原样塞进 `_raw`，
  /// 工具那层至少能报出"参数坏了"，而不是拿着空 map 静默跑偏。
  static Map<String, dynamic> decodeToolArguments(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return {};
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // 落到下面的 _raw。
    }
    return {'_raw': trimmed};
  }

  /// 把一轮的原始产出收成 [LlmResponse]，顺带跑一遍坏格式工具调用的兜底解析。
  /// 流式与非流式共用：兜底逻辑只能有一份，否则修了一边另一边照旧犯病。
  static LlmResponse _finalize({
    required String endpoint,
    required String content,
    required String reasoningContent,
    required List<LlmToolCall> toolCalls,
    required String finishReason,
    required LlmUsage usage,
  }) {
    final text = content;
    // 兜底：服务端没给结构化 tool_calls，但正文里带着工具调用标记。
    //
    // DeepSeek 系模型的工具调用底层是一串特殊 token，正常由服务端翻译成
    // tool_calls 字段；这个翻译会偶发失效（少发起始 token、流式拼接错位、
    // 模型自己把标记当正文吐出来），失效那一轮就变成"没调工具、直接给正文"，
    // 于是循环判定答完收工，用户看到的是幻觉出来的工具输出。
    // 这就是"工具调用像薛定谔的猫"的根因，所以必须自己再解析一遍。
    if (toolCalls.isEmpty && text.isNotEmpty) {
      final recovered = LlmToolCallRecovery.scan(text);
      if (recovered.calls.isNotEmpty) {
        ApiDebugLog.instance.add(
          kind: ApiDebugKind.response,
          method: 'POST',
          uri: endpoint,
          message: '从正文里恢复了 ${recovered.calls.length} 个工具调用',
          detail: '工具：${recovered.calls.map((c) => c.name).join(', ')}',
        );
        return LlmResponse(
          content: recovered.content,
          reasoningContent: reasoningContent,
          toolCalls: recovered.calls,
          finishReason: finishReason,
          usage: usage,
          recoveredToolCalls: true,
        );
      }
      if (recovered.sawMarkup) {
        ApiDebugLog.instance.add(
          kind: ApiDebugKind.error,
          method: 'POST',
          uri: endpoint,
          message: '正文里有工具调用标记但解析失败',
          detail: text.length > 400 ? text.substring(0, 400) : text,
        );
        return LlmResponse(
          content: recovered.content,
          reasoningContent: reasoningContent,
          finishReason: finishReason,
          usage: usage,
          brokenToolMarkup: true,
        );
      }
    }
    return LlmResponse(
      content: text,
      reasoningContent: reasoningContent,
      toolCalls: toolCalls,
      finishReason: finishReason,
      usage: usage,
    );
  }

  /// 把出错时的流式响应体读成文本，用来给用户看真正的错误原因。
  static Future<String> _drain(ResponseBody body) async {
    try {
      final bytes = <int>[];
      await for (final chunk in body.stream) {
        bytes.addAll(chunk);
        if (bytes.length > 16000) break;
      }
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  /// HTTP 状态码 → 带类型的异常。流式和非流式两条路要给出同样的话术。
  static ApiException _statusException(int status, String detail) =>
      ApiException(
        message: switch (status) {
          401 || 403 => 'AI 服务鉴权失败（HTTP $status），请检查 API Key',
          404 => 'AI 接口不存在（HTTP 404），请检查 Base URL 的版本路径是否正确（如 /v1、/v4）',
          429 => 'AI 服务限流（HTTP 429），稍后再试',
          _ => 'AI 服务返回错误（HTTP $status）${detail.isEmpty ? '' : '：$detail'}',
        },
        statusCode: status,
        type: status == 401 || status == 403
            ? ApiExceptionType.unauthorized
            : ApiExceptionType.business,
      );

  /// 把 Dio 异常翻译成带类型的 ApiException，供重试判定与界面提示使用。
  static ApiException _mapLlmError(DioException e) {
    if (e.type == DioExceptionType.cancel) {
      return const ApiException(
        message: '请求已取消',
        type: ApiExceptionType.cancelled,
      );
    }
    final status = e.response?.statusCode;
    if (status != null) {
      return _statusException(status, _errorDetail(e.response?.data));
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return const ApiException(
          message: 'AI 服务响应超时，可以重试或换更快的模型',
          type: ApiExceptionType.timeout,
        );
      case DioExceptionType.connectionError:
        final text = e.message ?? '';
        if (text.contains('Failed host lookup')) {
          return const ApiException(
            message: 'AI 服务域名解析失败，请检查手机网络与设置里的 Base URL',
            type: ApiExceptionType.network,
          );
        }
        return const ApiException(
          message: '连不上 AI 服务，请检查网络与 Base URL',
          type: ApiExceptionType.network,
        );
      case DioExceptionType.cancel:
        return const ApiException(message: '请求已取消');
      default:
        return ApiException(
          message: 'AI 请求失败：${e.message ?? e.type.name}',
          type: ApiExceptionType.network,
        );
    }
  }

  static String _errorDetail(Object? data) {
    if (data is Map) {
      final error = data['error'];
      if (error is Map) return error['message']?.toString() ?? '';
      return data['message']?.toString() ?? '';
    }
    if (data is String && data.isNotEmpty) {
      return data.length > 200 ? '${data.substring(0, 200)}…' : data;
    }
    return '';
  }

  /// 获取 OpenAI 兼容接口的模型列表。
  ///
  /// 各家网关差异很大，这里按容错顺序处理：
  /// 1. 端点：先 `<base>/v1/models`，404/405 再退回 `<base>/models`
  ///    （有些自建网关不带 /v1，有些反过来）；
  /// 2. 响应形状：`{data:[...]}`、`{models:[...]}`、裸数组、甚至纯文本换行列表；
  /// 3. 元素形状：`{id}`、`{name}`、`{model}`，或直接是字符串。
  ///
  /// 任何一步拿不到都抛带原因的异常——之前是静默 `return []`，
  /// 界面上只会显示「获取到 0 个模型」，完全不知道为什么。
  static Future<List<String>> listModels({
    required LlmConfig config,
  }) async {
    if (config.baseUrl.trim().isEmpty || config.apiKey.trim().isEmpty) {
      throw const ApiException(message: '请先配置 LLM Base URL 和 API Key');
    }
    if (config.protocol == LlmProtocol.anthropic) {
      return _listAnthropicModels(config);
    }
    if (config.protocol == LlmProtocol.google) {
      return _listGoogleModels(config);
    }
    final candidates = _modelsEndpoints(config.baseUrl);
    Object? lastError;
    for (final url in candidates) {
      try {
        final response = await DioClient.dio.get<dynamic>(
          url,
          options: Options(
            headers: {
              'Authorization': 'Bearer ${config.apiKey}',
              ...config.extraHeaders,
            },
            extra: {'isAuthRequest': true},
            // 网关列模型有时很慢，10s 容易假超时。
            sendTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 20),
            // 自己判断状态码，才能在 404 时换下一个端点。
            validateStatus: (_) => true,
            responseType: ResponseType.json,
          ),
        );
        final code = response.statusCode ?? 0;
        if (code == 404 || code == 405) {
          lastError = ApiException(
            message: '$url 返回 $code',
            statusCode: code,
          );
          continue;
        }
        if (code < 200 || code >= 300) {
          throw ApiException(
            message: '获取模型列表失败（HTTP $code）'
                '${_errorDetail(response.data).isEmpty ? "" : "：${_errorDetail(response.data)}"}',
            statusCode: code,
            type: code == 401
                ? ApiExceptionType.unauthorized
                : ApiExceptionType.business,
          );
        }
        final models = _parseModelList(response.data);
        if (models.isNotEmpty) return models;
        lastError = const ApiException(message: '接口返回的列表是空的');
      } on DioException catch (e) {
        // 证书不被信任要单独说清楚：自建 LLM 网关几乎都是自签 HTTPS，
        // 报一句"获取模型列表失败：null"没人能猜到是证书的事。
        if (isCertError(e)) {
          throw const ApiException(message: '获取模型列表失败。$certHint');
        }
        if (isPlaintextToTlsError(e)) {
          throw const ApiException(message: '获取模型列表失败。$schemeHint');
        }
        lastError = ApiException(
          message: '获取模型列表失败：${e.response?.statusCode ?? e.message}',
          statusCode: e.response?.statusCode,
          type: e.response?.statusCode == 401
              ? ApiExceptionType.unauthorized
              : ApiExceptionType.business,
        );
      }
    }
    if (lastError is ApiException) throw lastError;
    throw ApiException(message: '获取模型列表失败：$lastError');
  }

  /// Anthropic 模型列表：官方端点需要 x-api-key 而不是 Bearer。
  static Future<List<String>> _listAnthropicModels(LlmConfig config) async {
    final candidates = _anthropicModelsEndpoints(config.baseUrl);
    Object? lastError;
    for (final url in candidates) {
      try {
        final response = await DioClient.dio.get<dynamic>(
          url,
          options: Options(
            headers: _anthropicHeaders(config),
            extra: {'isAuthRequest': true},
            sendTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 20),
            validateStatus: (_) => true,
            responseType: ResponseType.json,
          ),
        );
        final code = response.statusCode ?? 0;
        if (code == 404 || code == 405) {
          lastError = ApiException(
            message: '$url 返回 $code',
            statusCode: code,
          );
          continue;
        }
        if (code < 200 || code >= 300) {
          throw ApiException(
            message: '获取模型列表失败（HTTP $code）'
                '${_errorDetail(response.data).isEmpty ? "" : "：${_errorDetail(response.data)}"}',
            statusCode: code,
            type: code == 401
                ? ApiExceptionType.unauthorized
                : ApiExceptionType.business,
          );
        }
        final models = _parseModelList(response.data);
        if (models.isNotEmpty) return models;
        lastError = const ApiException(message: '接口返回的列表是空的');
      } on DioException catch (e) {
        if (isCertError(e)) {
          throw const ApiException(message: '获取模型列表失败。$certHint');
        }
        if (isPlaintextToTlsError(e)) {
          throw const ApiException(message: '获取模型列表失败。$schemeHint');
        }
        lastError = ApiException(
          message: '获取模型列表失败：${e.response?.statusCode ?? e.message}',
          statusCode: e.response?.statusCode,
          type: e.response?.statusCode == 401
              ? ApiExceptionType.unauthorized
              : ApiExceptionType.business,
        );
      }
    }
    if (lastError is ApiException) throw lastError;
    throw ApiException(message: '获取模型列表失败：$lastError');
  }

  static Future<List<String>> _listGoogleModels(LlmConfig config) async {
    final raw = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final url = '$raw/models';
    try {
      final response = await DioClient.dio.get<dynamic>(
        url,
        options: Options(
          headers: _googleHeaders(config),
          extra: {'isAuthRequest': true},
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 20),
          validateStatus: (_) => true,
          responseType: ResponseType.json,
        ),
      );
      final code = response.statusCode ?? 0;
      if (code < 200 || code >= 300) {
        throw ApiException(
          message: '获取模型列表失败（HTTP $code）'
              '${_errorDetail(response.data).isEmpty ? "" : "：${_errorDetail(response.data)}"}',
          statusCode: code,
          type: code == 401
              ? ApiExceptionType.unauthorized
              : ApiExceptionType.business,
        );
      }
      final body = response.data;
      if (body is Map) {
        final models = body['models'];
        if (models is List) {
          final out = <String>[];
          for (final m in models) {
            if (m is Map) {
              final name = m['name']?.toString().trim() ?? '';
              if (name.isEmpty) continue;
              out.add(name.startsWith('models/')
                  ? name.substring('models/'.length)
                  : name);
            } else if (m is String) {
              out.add(m.trim());
            }
          }
          if (out.isNotEmpty) return out;
        }
      }
      throw const ApiException(message: '接口返回的列表是空的');
    } on DioException catch (e) {
      if (isCertError(e)) {
        throw const ApiException(message: '获取模型列表失败。$certHint');
      }
      if (isPlaintextToTlsError(e)) {
        throw const ApiException(message: '获取模型列表失败。$schemeHint');
      }
      throw ApiException(
        message: '获取模型列表失败：${e.response?.statusCode ?? e.message}',
        statusCode: e.response?.statusCode,
        type: e.response?.statusCode == 401
            ? ApiExceptionType.unauthorized
            : ApiExceptionType.business,
      );
    }
  }

  static List<String> _anthropicModelsEndpoints(String baseUrl) {
    final raw = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final withV1 = raw.endsWith('/v1')
        ? '$raw/models'
        : '$raw/v1/models';
    final without = '$raw/models';
    return without == withV1 ? [withV1] : [withV1, without];
  }

  /// 候选 models 端点：带 /v1 与不带 /v1 各试一次。
  static List<String> _modelsEndpoints(String baseUrl) {
    final withV1 = '${_base(baseUrl)}/models';
    final raw = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final bare = raw.endsWith('/chat/completions')
        ? raw.replaceAll(RegExp(r'/chat/completions$'), '')
        : raw;
    final without = '$bare/models';
    return without == withV1 ? [withV1] : [withV1, without];
  }

  static List<String> _parseModelList(dynamic data) {
    List<dynamic>? rows;
    if (data is List) {
      rows = data;
    } else if (data is Map) {
      for (final key in const ['data', 'models', 'result', 'items']) {
        final value = data[key];
        if (value is List) {
          rows = value;
          break;
        }
      }
    } else if (data is String) {
      // 少数网关把 JSON 当 text/plain 返回，Dio 不会解析。
      final trimmed = data.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          return _parseModelList(jsonDecode(trimmed));
        } catch (_) {
          // 落到按行解析。
        }
      }
      return trimmed
          .split(RegExp(r'[\r\n,]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !e.contains(' '))
          .toList();
    }
    if (rows == null) return const [];
    final result = <String>[];
    for (final row in rows) {
      if (row is String) {
        if (row.trim().isNotEmpty) result.add(row.trim());
        continue;
      }
      if (row is Map) {
        final id = row['id'] ?? row['name'] ?? row['model'];
        final text = id?.toString().trim() ?? '';
        if (text.isNotEmpty) result.add(text);
      }
    }
    return result;
  }

  /// 连通性测试：发一条最小请求，能拿到 2xx/JSON 即视为通过。
  static Future<void> testConnection({
    required LlmConfig config,
  }) async {
    await complete(
      config: config,
      messages: const [LlmMessage(role: 'user', content: 'ping')],
    );
  }
}
