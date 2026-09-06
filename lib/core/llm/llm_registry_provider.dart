import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/settings/providers/settings_provider.dart';
import '../storage/secure_storage.dart';
import '../utils/logger.dart';
import 'llm_client.dart';
import 'llm_provider.dart';

/// 提供商总表的读写入口。
///
/// 这里是**唯一**的真相来源：提供商列表、当前用哪家、每家的模型缓存、
/// 每个模型的上下文长度、子代理编队。聊天页里的 `availableModels`
/// / `selectedModel` 只是这张表当前那一家的投影，改动一律走这里，
/// 免得两处各存一份、切一次提供商就对不上。
class LlmRegistryNotifier extends Notifier<LlmRegistry> {
  static const _key = 'llm_providers_v1';

  /// 迁移时要读的老键。
  static const _legacyAiSettingsKey = 'ai_settings_v1';

  bool _loaded = false;

  @override
  LlmRegistry build() => const LlmRegistry();

  /// 从磁盘读。没有新格式数据时，把老的单份 AI 配置迁移成一家提供商。
  ///
  /// 迁移只做一次，且**不删老数据**：万一新格式哪里出错，老键还在，
  /// 用户的 Base URL 和模型缓存不会凭空消失。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          state = LlmRegistry.fromJson(decoded);
          return;
        }
      }
      state = await _migrateFromLegacy(prefs);
      await _save();
    } catch (e) {
      Logger.e('llm', 'load providers failed', e);
      state = state.copyWith(loaded: true);
    }
  }

  /// 老配置 → 一家提供商。
  ///
  /// 老数据散在三处：设置里的 `llmBaseUrl` / 超时 / 透传头体 / `cachedModels`，
  /// 聊天设置里的 `selectedModel` / `modelContextLimits` / `manualModels`，
  /// 安全存储里那把全局 API Key。都归到 id 为 `default` 的这一家名下。
  Future<LlmRegistry> _migrateFromLegacy(SharedPreferences prefs) async {
    final settings = ref.read(settingsProvider);
    var models = settings.cachedModels;
    var manual = const <String>[];
    var limits = const <String, int>{};
    var selected = '';
    final aiRaw = prefs.getString(_legacyAiSettingsKey);
    if (aiRaw != null && aiRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(aiRaw);
        if (decoded is Map<String, dynamic>) {
          selected = decoded['selectedModel']?.toString() ?? '';
          final saved = decoded['availableModels'];
          if (saved is List && saved.isNotEmpty) {
            models = [for (final m in saved) m.toString()];
          }
          final savedManual = decoded['manualModels'];
          if (savedManual is List) {
            manual = [for (final m in savedManual) m.toString()];
          }
          final savedLimits = decoded['modelContextLimits'];
          if (savedLimits is Map) {
            limits = {
              for (final e in savedLimits.entries)
                e.key.toString(): (e.value as num?)?.toInt() ?? 8000,
            };
          }
        }
      } catch (_) {
        // 老数据坏了就当没有，别把整次迁移拖死。
      }
    }

    // 把全局那把 Key 复制到新槽位。老键留着不删。
    final legacyKey = await SecureStorage.readLlmApiKey();
    if ((legacyKey ?? '').isNotEmpty) {
      await SecureStorage.saveLlmApiKey(legacyKey!, providerId: 'default');
    }

    final provider = LlmProviderConfig(
      id: 'default',
      name: settings.llmBaseUrl.trim().isEmpty ? '默认' : '默认配置',
      baseUrl: settings.llmBaseUrl,
      models: models,
      manualModels: manual,
      contextLimits: limits,
      defaultModel: selected.isNotEmpty ? selected : settings.llmModel,
      timeoutSeconds: settings.llmTimeoutSeconds,
      extraHeaders: settings.llmExtraHeaders,
      extraBody: settings.llmExtraBody,
      modelsFetchedAt: settings.modelsFetchedAt,
    );
    return LlmRegistry(
      providers: [provider],
      activeId: 'default',
      loaded: true,
    );
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(state.toJson()));
    } catch (e) {
      Logger.e('llm', 'persist providers failed', e);
    }
  }

  /// 新增一家，返回它的 id。第一家自动设为当前。
  Future<String> addProvider({String name = '', String baseUrl = ''}) async {
    // 毫秒时间戳单独用会撞：连着加两家（或者脚本里连着调两次）落在同一毫秒，
    // 两家就顶着同一个 id——按 id 找永远只能找到第一家，
    // 子代理指到第二家会静默拿到第一家的地址。
    final stamp = DateTime.now().millisecondsSinceEpoch;
    var id = 'p$stamp';
    var seq = 1;
    while (state.byId(id) != null) {
      id = 'p$stamp-$seq';
      seq++;
    }
    final next = LlmProviderConfig(id: id, name: name, baseUrl: baseUrl);
    state = state.copyWith(
      providers: [...state.providers, next],
      activeId: state.providers.isEmpty ? id : state.activeId,
      loaded: true,
    );
    await _save();
    return id;
  }

  Future<void> updateProvider(LlmProviderConfig next) async {
    state = state.copyWith(
      providers: [
        for (final p in state.providers)
          if (p.id == next.id) next else p,
      ],
    );
    await _save();
  }

  /// 删一家。连它的 API Key 一起删——留着一把指向不存在提供商的密钥没意义。
  Future<void> removeProvider(String id) async {
    final rest =
        state.providers.where((p) => p.id != id).toList(growable: false);
    final sub = state.subAgent.providerId == id
        ? state.subAgent.copyWith(providerId: '', model: '')
        : state.subAgent;
    state = state.copyWith(
      providers: rest,
      activeId: state.activeId == id
          ? (rest.isEmpty ? '' : rest.first.id)
          : state.activeId,
      subAgent: sub,
    );
    await SecureStorage.deleteLlmApiKey(providerId: id);
    await _save();
  }

  Future<void> setActive(String id) async {
    if (state.byId(id) == null || state.activeId == id) return;
    state = state.copyWith(activeId: id);
    await _save();
  }

  Future<void> setSubAgent(SubAgentPlan plan) async {
    state = state.copyWith(subAgent: plan);
    await _save();
  }

  /// 记下某家的模型缓存（"重新获取"之后调用）。
  Future<void> setModels(
    String providerId, {
    required List<String> models,
    List<String>? manualModels,
    Map<String, int>? contextLimits,
  }) async {
    final target = state.byId(providerId);
    if (target == null) return;
    await updateProvider(target.copyWith(
      models: models,
      manualModels: manualModels,
      contextLimits: contextLimits,
      modelsFetchedAt: DateTime.now(),
    ));
  }

  /// 记住某家当前选中的模型。
  Future<void> setDefaultModel(String providerId, String model) async {
    final target = state.byId(providerId);
    if (target == null || target.defaultModel == model) return;
    await updateProvider(target.copyWith(defaultModel: model));
  }

  /// 组装某家的 [LlmConfig]。
  ///
  /// 连接类参数（地址、密钥、超时、透传头体）跟着提供商；
  /// 采样类参数（温度、top_p、惩罚项）仍然是全局的——那是"我想要什么风格"，
  /// 不是"这家怎么连"。
  Future<LlmConfig> configFor(String providerId, {String model = ''}) async {
    final target = state.byId(providerId) ?? state.active;
    final settings = ref.read(settingsProvider);
    final apiKey = await SecureStorage.readLlmApiKey(providerId: target.id);
    return LlmConfig(
      baseUrl: target.baseUrl,
      model: model.isNotEmpty ? model : target.defaultModel,
      apiKey: apiKey ?? '',
      temperature: settings.llmTemperature,
      topP: settings.llmTopP,
      maxTokens: settings.llmMaxTokens,
      frequencyPenalty: settings.llmFrequencyPenalty,
      presencePenalty: settings.llmPresencePenalty,
      extraBody: _decodeBody(target.extraBody),
      extraHeaders: _decodeHeaders(target.extraHeaders),
      receiveTimeoutSeconds: target.timeoutSeconds,
    );
  }

  /// 当前提供商的配置。
  Future<LlmConfig> activeConfig({String model = ''}) =>
      configFor(state.active.id, model: model);

  /// 子代理该用的配置。没单独指定就返回主代理那份。
  Future<LlmConfig> subAgentConfig() async {
    final plan = state.subAgent;
    if (!plan.overridesModel) return activeConfig();
    return configFor(plan.providerId, model: plan.model);
  }

  static Map<String, dynamic> _decodeBody(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const {};
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  static Map<String, String> _decodeHeaders(String raw) => {
        for (final e in _decodeBody(raw).entries) e.key: e.value.toString(),
      };
}

final llmRegistryProvider =
    NotifierProvider<LlmRegistryNotifier, LlmRegistry>(LlmRegistryNotifier.new);

/// 当前提供商组装出来的 LLM 配置。
///
/// 这里 watch 总表，所以改任何连接参数都会自动重算——**不能**反过来让
/// 总表去 invalidate 这个 provider：那是"被依赖方去动依赖方"，
/// Riverpod 直接抛 CircularDependencyError。
/// 唯一需要手动 invalidate 的是改 API Key（密钥在安全存储里，
/// 总表的 state 没变），那一下由界面发起。
///
/// 保留这个 provider 名字是为了不动所有调用点；内容已经从"全局那一份设置"
/// 换成"当前提供商 + 全局采样参数"。
final llmConfigProvider = FutureProvider<LlmConfig>((ref) async {
  // watch 两边：换提供商、改采样参数都要重算。
  ref.watch(llmRegistryProvider);
  ref.watch(settingsProvider);
  return ref.read(llmRegistryProvider.notifier).activeConfig();
});
