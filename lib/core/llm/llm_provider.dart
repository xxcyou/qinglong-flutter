/// 多提供商 LLM 配置的数据模型。
///
/// ## 为什么要有"提供商"这一层
///
/// 之前全局只有一份 AI 连接配置（`llmBaseUrl` + 一个 API Key + 一份模型缓存）。
/// 想同时用两家（比如本机自建的那个 + 云上的官方接口），只能来回改 Base URL
/// 和 Key，改一次模型缓存就被覆盖一次，来回切等于每次重配。
///
/// 现在一家一条 [LlmProviderConfig]：地址、密钥、超时、透传头/透传体、
/// 自己那份模型列表和每个模型的上下文长度，全都跟着这家走。
/// 切提供商只是换一个 id，两边的模型缓存互不影响。
///
/// API Key **不在这里**：它进 `flutter_secure_storage`，键是
/// `llm_api_key_<id>`。这个类会被 jsonEncode 写进 shared_preferences，
/// 明文密钥绝不能放进来。
library;

/// 一家提供商（一个 OpenAI 兼容端点）。
class LlmProviderConfig {
  const LlmProviderConfig({
    required this.id,
    this.name = '',
    this.baseUrl = '',
    this.models = const [],
    this.manualModels = const [],
    this.contextLimits = const {},
    this.defaultModel = '',
    this.timeoutSeconds = 180,
    this.extraHeaders = '',
    this.extraBody = '',
    this.modelsFetchedAt,
    this.outputPluginPath = '',
    this.outputPluginPaths = const [],
  });

  /// 稳定 id。子代理配置、活动提供商都按 id 引用，改名字不会失联。
  final String id;

  /// 显示名。留空时界面回落显示主机名。
  final String name;

  /// OpenAI 兼容 Base URL，填到 `/v1` 即可。
  final String baseUrl;

  /// 这家的模型缓存（`/v1/models` 拉到的）。
  final List<String> models;

  /// 手填的模型名。有些网关不实现 `/v1/models`，或者只列一部分；
  /// 手填的这批要能活过一次"重新获取"，所以单独记来源。
  final List<String> manualModels;

  /// 每个模型的上下文长度上限。跟着提供商存：同名模型在不同网关上
  /// 开放的上下文经常不一样。
  final Map<String, int> contextLimits;

  /// 这家默认用哪个模型（切回这家时自动选中它）。
  final String defaultModel;

  /// 接收超时。慢的自建网关和快的云端差很远，所以按家配。
  final int timeoutSeconds;

  /// 额外请求头（JSON 对象文本）。OpenRouter 要 HTTP-Referer / X-Title
  /// 这类东西，天生是"每家不一样"，所以不该是全局设置。
  final String extraHeaders;

  /// 额外 body 字段（JSON 对象文本），透传厂商私有参数。
  final String extraBody;

  /// 上次拉模型列表的时间，界面上显示"缓存于 …"。
  final DateTime? modelsFetchedAt;

  /// 输出整理插件 .js 文件的 PRoot 路径（旧的单插件字段，兼容老数据）。
  final String outputPluginPath;

  /// 多个输出整理插件，按数组顺序依次执行。
  ///
  /// 用户在文件管理里写的 JS 插件，负责把模型原始输出整理成展示文本
  /// （例如清理泄露的 `<｜tool｜ calls>` 内部调用标记）。空 = 不启用。
  final List<String> outputPluginPaths;

  /// 实际生效的插件路径：优先新字段，老数据回落单插件。
  List<String> get effectiveOutputPlugins {
    if (outputPluginPaths.isNotEmpty) return outputPluginPaths;
    if (outputPluginPath.trim().isNotEmpty) return [outputPluginPath];
    return const [];
  }

  /// 界面上显示用的名字。
  String get label {
    if (name.trim().isNotEmpty) return name.trim();
    final host = Uri.tryParse(baseUrl.trim())?.host ?? '';
    return host.isEmpty ? '未命名提供商' : host;
  }

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  /// 缓存 + 手填，去重后排序：界面上就按这个列。
  List<String> get allModels {
    final set = <String>{...models, ...manualModels};
    final list = set.where((m) => m.trim().isNotEmpty).toList()..sort();
    return list;
  }

  LlmProviderConfig copyWith({
    String? name,
    String? baseUrl,
    List<String>? models,
    List<String>? manualModels,
    Map<String, int>? contextLimits,
    String? defaultModel,
    int? timeoutSeconds,
    String? extraHeaders,
    String? extraBody,
    DateTime? modelsFetchedAt,
    String? outputPluginPath,
    List<String>? outputPluginPaths,
  }) {
    return LlmProviderConfig(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      models: models ?? this.models,
      manualModels: manualModels ?? this.manualModels,
      contextLimits: contextLimits ?? this.contextLimits,
      defaultModel: defaultModel ?? this.defaultModel,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      extraHeaders: extraHeaders ?? this.extraHeaders,
      extraBody: extraBody ?? this.extraBody,
      modelsFetchedAt: modelsFetchedAt ?? this.modelsFetchedAt,
      outputPluginPath: outputPluginPath ?? this.outputPluginPath,
      outputPluginPaths: outputPluginPaths ?? this.outputPluginPaths,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'models': models,
        'manualModels': manualModels,
        'contextLimits': contextLimits,
        'defaultModel': defaultModel,
        'timeoutSeconds': timeoutSeconds,
        'extraHeaders': extraHeaders,
        'extraBody': extraBody,
        'modelsFetchedAt': modelsFetchedAt?.toIso8601String(),
        'outputPluginPath': outputPluginPath,
        'outputPluginPaths': outputPluginPaths,
      };

  static LlmProviderConfig fromJson(Map<String, dynamic> json) {
    final limits = json['contextLimits'];
    return LlmProviderConfig(
      id: json['id']?.toString() ?? 'p0',
      name: json['name']?.toString() ?? '',
      baseUrl: json['baseUrl']?.toString() ?? '',
      models: [
        for (final m in (json['models'] as List? ?? const [])) m.toString(),
      ],
      manualModels: [
        for (final m in (json['manualModels'] as List? ?? const []))
          m.toString(),
      ],
      contextLimits: limits is Map
          ? {
              for (final e in limits.entries)
                e.key.toString(): (e.value as num?)?.toInt() ?? 8000,
            }
          : const {},
      defaultModel: json['defaultModel']?.toString() ?? '',
      timeoutSeconds: (json['timeoutSeconds'] as num?)?.toInt() ?? 180,
      extraHeaders: json['extraHeaders']?.toString() ?? '',
      extraBody: json['extraBody']?.toString() ?? '',
      modelsFetchedAt:
          DateTime.tryParse(json['modelsFetchedAt']?.toString() ?? ''),
      outputPluginPath: json['outputPluginPath']?.toString() ?? '',
      outputPluginPaths: [
        for (final p in (json['outputPluginPaths'] as List? ?? const []))
          p.toString(),
      ],
    );
  }
}

/// 子代理编队：几个人干、用谁的模型。
///
/// 子代理（`task_worker` / `parallel_agents` 派出去的那些）以前硬绑主代理的
/// 模型和一个写死的并行度 3。实际上这两件事该分开：
/// 派出去查资料的活用便宜快的模型更划算，主代理留着贵的做判断；
/// 并行度取决于机器和网络，手机上 2 个就够、桌面代理转发可以更多。
class SubAgentPlan {
  const SubAgentPlan({
    this.parallel = 3,
    this.providerId = '',
    this.model = '',
    this.maxTurns = 64,
  });

  /// `parallel_agents` 默认同时跑几个，也是它的上限。
  final int parallel;

  /// 子代理用哪家。留空 = 跟主代理同一家。
  final String providerId;

  /// 子代理用哪个模型。留空 = 跟主代理同一个。
  final String model;

  /// 子代理的轮次预算。
  final int maxTurns;

  /// 有没有单独指定过模型来源。
  bool get overridesModel => providerId.trim().isNotEmpty;

  SubAgentPlan copyWith({
    int? parallel,
    String? providerId,
    String? model,
    int? maxTurns,
  }) =>
      SubAgentPlan(
        parallel: parallel ?? this.parallel,
        providerId: providerId ?? this.providerId,
        model: model ?? this.model,
        maxTurns: maxTurns ?? this.maxTurns,
      );

  Map<String, dynamic> toJson() => {
        'parallel': parallel,
        'providerId': providerId,
        'model': model,
        'maxTurns': maxTurns,
      };

  static SubAgentPlan fromJson(Map<String, dynamic> json) => SubAgentPlan(
        parallel: ((json['parallel'] as num?)?.toInt() ?? 3).clamp(1, 8),
        providerId: json['providerId']?.toString() ?? '',
        model: json['model']?.toString() ?? '',
        maxTurns: ((json['maxTurns'] as num?)?.toInt() ?? 64).clamp(4, 200),
      );
}

/// 提供商总表：一串提供商 + 当前用哪个 + 子代理编队。
class LlmRegistry {
  const LlmRegistry({
    this.providers = const [],
    this.activeId = '',
    this.subAgent = const SubAgentPlan(),
    this.mainMaxTurns = 200,
    this.loaded = false,
  });

  final List<LlmProviderConfig> providers;
  final String activeId;
  final SubAgentPlan subAgent;

  /// 主 agent 的轮次预算。手动在设置里调，默认 200。
  final int mainMaxTurns;

  /// 磁盘读完了没有。没读完之前界面不该显示"未配置"——
  /// 那会让人以为设置丢了。
  final bool loaded;

  /// 当前提供商。activeId 失效（被删了）时回落到第一条；一条都没有时
  /// 返回一个空壳，调用方按 `isConfigured` 判断。
  LlmProviderConfig get active {
    for (final p in providers) {
      if (p.id == activeId) return p;
    }
    return providers.isEmpty
        ? const LlmProviderConfig(id: '')
        : providers.first;
  }

  LlmProviderConfig? byId(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  LlmRegistry copyWith({
    List<LlmProviderConfig>? providers,
    String? activeId,
    SubAgentPlan? subAgent,
    int? mainMaxTurns,
    bool? loaded,
  }) =>
      LlmRegistry(
        providers: providers ?? this.providers,
        activeId: activeId ?? this.activeId,
        subAgent: subAgent ?? this.subAgent,
        mainMaxTurns: mainMaxTurns ?? this.mainMaxTurns,
        loaded: loaded ?? this.loaded,
      );

  Map<String, dynamic> toJson() => {
        'providers': [for (final p in providers) p.toJson()],
        'activeId': activeId,
        'subAgent': subAgent.toJson(),
        'mainMaxTurns': mainMaxTurns,
      };

  static LlmRegistry fromJson(Map<String, dynamic> json) {
    final list = json['providers'];
    final sub = json['subAgent'];
    return LlmRegistry(
      providers: [
        for (final item in (list as List? ?? const []))
          if (item is Map<String, dynamic>) LlmProviderConfig.fromJson(item),
      ],
      activeId: json['activeId']?.toString() ?? '',
      subAgent: sub is Map<String, dynamic>
          ? SubAgentPlan.fromJson(sub)
          : const SubAgentPlan(),
      mainMaxTurns:
          ((json['mainMaxTurns'] as num?)?.toInt() ?? 200).clamp(4, 1000),
      loaded: true,
    );
  }
}
