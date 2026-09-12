enum AgentEventKind {
  thinking,
  toolStart,
  toolEnd,
  toolImage,
  planPending,

  /// 模型向用户提问，等待回答。
  question,

  /// AI 拆出/更新了任务清单。
  taskPlan,

  /// AI 生成了一张 HTML 互动卡片。
  canvas,

  /// 模型这一轮写给用户看的**正文**（不是内部思考）。
  ///
  /// 边调工具边解释的那几段话以前只在最后汇总时露一次脸，中间过程全被
  /// 吞掉了——用户看时间线只能看到一串工具名，不知道它在跟自己说什么。
  answer,
  error,
  done,
}

/// 一轮回复的流式增量：模型吐一点，界面就多一点。
///
/// 和 [AgentEvent] 分开是因为两者的生命周期完全不同：事件是"已经发生的一步"，
/// 会写进消息里永久留存；增量是"正在发生"的碎片，只活到这一轮结束，
/// 拼完就被对应的 [AgentEvent]/正文取代。混在一起的话，光是把每个 token
/// 都塞进事件列表就能让时间线涨到几千行。
class AgentDelta {
  const AgentDelta({
    this.reasoning = '',
    this.content = '',
    this.toolName = '',
    this.reset = false,
    this.turn = 0,
  });

  /// 思考（reasoning_content）增量。
  final String reasoning;

  /// 正文增量。
  final String content;

  /// 这一片里模型刚开口要调的工具名。
  final String toolName;

  /// 前面吐出来的作废：新一轮开始、或者上一次请求失败重发。
  final bool reset;

  final int turn;
}

/// Agent 运行过程中的实时事件，用于在界面上展示“思考/工具调用/结果”。
class AgentEvent {
  const AgentEvent({
    required this.kind,
    required this.message,
    this.toolName,
    this.args,
    this.result,
    this.fullResult,
    this.imageDataUri,
    this.durationMs,
    this.ok = true,
    this.turn = 0,
    this.isWrite = false,
  });

  final AgentEventKind kind;
  final String message;
  final String? toolName;
  final Map<String, dynamic>? args;
  final String? result;

  /// 工具链里要立即展示的图片（data URI），例如 show_image 一加载完就推送。
  final String? imageDataUri;

  /// 未截断的原始返回。
  ///
  /// [result] 是"喂给模型的那份"——超过上限会被砍掉中段，所以排障时经常正好
  /// 缺了要看的那几行。这里另留一份完整的给人看：工具详情页展示的是它。
  final String? fullResult;

  /// 这次工具调用耗时，毫秒。排查"哪一步慢"时有用。
  final int? durationMs;

  final bool ok;
  final int turn;

  /// 这次工具调用是不是写操作。会话缓存据此判断：写操作之后，
  /// 之前的只读缓存一律失效，不能再让 AI 读到旧快照。
  final bool isWrite;

  /// 人看的那份返回：有完整的就用完整的。
  String get displayResult =>
      (fullResult?.isNotEmpty ?? false) ? fullResult! : (result ?? '');

  /// 完整返回比喂给模型的那份长多少字符（0 = 没被截断）。
  int get omittedChars {
    final full = fullResult?.length ?? 0;
    final short = result?.length ?? 0;
    return full > short ? full - short : 0;
  }

  /// 落盘时给完整返回留的上限。
  ///
  /// 会话是整体序列化进本地存储的，一次抓包动辄几十万字符的原始返回会把
  /// 存储撑爆、还拖慢每次读写。人排障看前 3 万字符够了。
  static const persistedFullResultLimit = 30000;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'message': message,
        if (toolName != null) 'toolName': toolName,
        if (args != null) 'args': args,
        if (result != null) 'result': result,
        if (imageDataUri != null) 'imageDataUri': imageDataUri,
        if (fullResult != null && fullResult != result)
          'fullResult': fullResult!.length > persistedFullResultLimit
              ? '${fullResult!.substring(0, persistedFullResultLimit)}'
                  '\n…（完整内容过长，落盘时截断）'
              : fullResult,
        if (durationMs != null) 'durationMs': durationMs,
        'ok': ok,
        'turn': turn,
        if (isWrite) 'isWrite': true,
      };

  factory AgentEvent.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind']?.toString() ?? 'thinking';
    return AgentEvent(
      kind: AgentEventKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => AgentEventKind.thinking,
      ),
      message: json['message']?.toString() ?? '',
      toolName: json['toolName']?.toString(),
      args: json['args'] is Map
          ? (json['args'] as Map).map((k, v) => MapEntry(k.toString(), v))
          : null,
      result: json['result']?.toString(),
      fullResult: json['fullResult']?.toString(),
      imageDataUri: json['imageDataUri']?.toString(),
      durationMs: (json['durationMs'] as num?)?.toInt(),
      ok: json['ok'] != false,
      turn: (json['turn'] as num?)?.toInt() ?? 0,
      isWrite: json['isWrite'] == true,
    );
  }
}
