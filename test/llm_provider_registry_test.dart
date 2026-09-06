import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/llm/llm_provider.dart';
import 'package:qinglong_flutter/core/llm/llm_registry_provider.dart';
import 'package:qinglong_flutter/features/settings/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 多提供商：一家一条连接配置 + 子代理编队。
///
/// 重点是**迁移**：老版本只有一份全局 AI 配置（llmBaseUrl + 一把 Key +
/// 一份模型缓存），升级后必须原样变成一家提供商，否则用户一开 APP
/// 就发现地址、Key、34 个模型缓存全没了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_secure_storage 走原生通道，测试里拿个 Map 顶上。
  final secure = <String, String>{};
  setUp(() {
    secure.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? const {};
        final key = args['key']?.toString() ?? '';
        switch (call.method) {
          case 'write':
            secure[key] = args['value']?.toString() ?? '';
            return null;
          case 'read':
            return secure[key];
          case 'delete':
            secure.remove(key);
            return null;
          case 'readAll':
            return Map<String, String>.from(secure);
          case 'deleteAll':
            secure.clear();
            return null;
        }
        return null;
      },
    );
  });

  Future<ProviderContainer> boot(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).load();
    await container.read(llmRegistryProvider.notifier).load();
    return container;
  }

  group('从老配置迁移', () {
    test('全局 Base URL / 超时 / 透传 / 模型缓存 → 一家提供商', () async {
      secure['llm_api_key'] = 'sk-legacy';
      final container = await boot({
        'llmBaseUrl': 'https://127.0.0.1:8766/v1',
        'llmTimeoutSeconds': 240,
        'llmExtraHeaders': '{"X-Title": "ql"}',
        'llmExtraBody': '{"enable_thinking": true}',
        'cachedModels': <String>['a-model', 'b-model'],
        'ai_settings_v1': jsonEncode({
          'selectedModel': 'b-model',
          'availableModels': ['a-model', 'b-model', 'manual-model'],
          'manualModels': ['manual-model'],
          'modelContextLimits': {'b-model': 64000},
        }),
      });

      final registry = container.read(llmRegistryProvider);
      expect(registry.providers, hasLength(1));
      final p = registry.active;
      expect(p.id, 'default');
      expect(p.baseUrl, 'https://127.0.0.1:8766/v1');
      expect(p.timeoutSeconds, 240);
      expect(p.extraHeaders, contains('X-Title'));
      expect(p.extraBody, contains('enable_thinking'));
      // 选中的模型、手填的模型、实测的上下文长度都要跟过来。
      expect(p.defaultModel, 'b-model');
      expect(p.manualModels, ['manual-model']);
      expect(p.contextLimits['b-model'], 64000);
      expect(p.allModels, containsAll(['a-model', 'b-model', 'manual-model']));
    });

    test('那把全局 API Key 复制到新槽位，老键不动', () async {
      secure['llm_api_key'] = 'sk-legacy';
      await boot({'llmBaseUrl': 'https://x/v1'});
      expect(secure['llm_api_key_default'], 'sk-legacy');
      // 老键留着：万一新格式出问题，用户的 Key 还在。
      expect(secure['llm_api_key'], 'sk-legacy');
    });

    test('已经是新格式就不再迁移', () async {
      final container = await boot({
        'llmBaseUrl': 'https://old/v1',
        'llm_providers_v1': jsonEncode({
          'providers': [
            {'id': 'p1', 'name': '云端', 'baseUrl': 'https://new/v1'},
          ],
          'activeId': 'p1',
        }),
      });
      final registry = container.read(llmRegistryProvider);
      expect(registry.providers, hasLength(1));
      expect(registry.active.baseUrl, 'https://new/v1');
    });

    test('干净安装：没有老配置也不炸，给一家空壳', () async {
      final container = await boot(const {});
      final registry = container.read(llmRegistryProvider);
      expect(registry.loaded, isTrue);
      expect(registry.active.isConfigured, isFalse);
    });
  });

  group('多提供商增删切', () {
    test('新增 / 切换 / 删除，各自的模型缓存互不影响', () async {
      final container = await boot(const {'llmBaseUrl': 'https://a/v1'});
      final notifier = container.read(llmRegistryProvider.notifier);

      final idB =
          await notifier.addProvider(name: '云端', baseUrl: 'https://b/v1');
      await notifier.setModels('default', models: ['a1', 'a2']);
      await notifier.setModels(idB, models: ['b1']);
      expect(container.read(llmRegistryProvider).byId('default')!.models,
          ['a1', 'a2']);
      expect(container.read(llmRegistryProvider).byId(idB)!.models, ['b1']);

      await notifier.setActive(idB);
      expect(container.read(llmRegistryProvider).active.id, idB);
      // 切过去不该动另一家的缓存。
      expect(container.read(llmRegistryProvider).byId('default')!.models,
          ['a1', 'a2']);

      await notifier.removeProvider(idB);
      final after = container.read(llmRegistryProvider);
      expect(after.providers, hasLength(1));
      // 当前那家被删了要自动回落，不能留一个指向空的 activeId。
      expect(after.active.id, 'default');
    });

    test('删掉的那家如果正被子代理引用，引用一起清掉', () async {
      final container = await boot(const {});
      final notifier = container.read(llmRegistryProvider.notifier);
      final id = await notifier.addProvider(name: '便宜的');
      await notifier.setSubAgent(
        const SubAgentPlan(parallel: 2).copyWith(providerId: id, model: 'm'),
      );
      expect(
          container.read(llmRegistryProvider).subAgent.overridesModel, isTrue);
      await notifier.removeProvider(id);
      final plan = container.read(llmRegistryProvider).subAgent;
      // 不清的话子代理会拿着一个不存在的 id 去组装配置，baseUrl 空、直接失败。
      expect(plan.overridesModel, isFalse);
      expect(plan.parallel, 2, reason: '并行度是独立设置，别被连带清掉');
    });

    test('删提供商连它的 API Key 一起删', () async {
      final container = await boot(const {});
      final notifier = container.read(llmRegistryProvider.notifier);
      final id = await notifier.addProvider(name: 'x');
      secure['llm_api_key_$id'] = 'sk-x';
      await notifier.removeProvider(id);
      expect(secure.containsKey('llm_api_key_$id'), isFalse);
    });

    test('重启后读回来还是那些提供商', () async {
      final container = await boot(const {});
      final notifier = container.read(llmRegistryProvider.notifier);
      final id =
          await notifier.addProvider(name: '云端', baseUrl: 'https://b/v1');
      await notifier.setActive(id);
      await notifier.setSubAgent(const SubAgentPlan(parallel: 5));

      // 同一份 prefs 上重开一个容器 = 重启。
      final again = ProviderContainer();
      addTearDown(again.dispose);
      await again.read(settingsProvider.notifier).load();
      await again.read(llmRegistryProvider.notifier).load();
      final registry = again.read(llmRegistryProvider);
      expect(registry.active.id, id);
      expect(registry.subAgent.parallel, 5);
    });
  });

  group('configFor', () {
    test('连接参数跟着提供商，采样参数还是全局的', () async {
      final container = await boot(const {
        'llmTemperature': 0.3,
        'llmMaxTokens': 4096,
      });
      final notifier = container.read(llmRegistryProvider.notifier);
      final id =
          await notifier.addProvider(name: '云端', baseUrl: 'https://b/v1');
      secure['llm_api_key_$id'] = 'sk-b';
      await notifier.updateProvider(
        container.read(llmRegistryProvider).byId(id)!.copyWith(
              timeoutSeconds: 300,
              defaultModel: 'b1',
              extraHeaders: '{"X-Title": "ql"}',
            ),
      );

      final config = await notifier.configFor(id);
      expect(config.baseUrl, 'https://b/v1');
      expect(config.apiKey, 'sk-b');
      expect(config.model, 'b1');
      expect(config.receiveTimeoutSeconds, 300);
      expect(config.extraHeaders['X-Title'], 'ql');
      expect(config.temperature, 0.3);
      expect(config.maxTokens, 4096);
    });

    test('子代理没单独指定就用主代理那份', () async {
      final container = await boot(const {});
      final notifier = container.read(llmRegistryProvider.notifier);
      final id = await notifier.addProvider(baseUrl: 'https://main/v1');
      await notifier.setActive(id);
      final config = await notifier.subAgentConfig();
      expect(config.baseUrl, 'https://main/v1');
    });

    test('子代理指定了另一家 → 用那家的地址和模型', () async {
      final container = await boot(const {});
      final notifier = container.read(llmRegistryProvider.notifier);
      final main = await notifier.addProvider(baseUrl: 'https://main/v1');
      final cheap = await notifier.addProvider(baseUrl: 'https://cheap/v1');
      secure['llm_api_key_$cheap'] = 'sk-cheap';
      await notifier.setActive(main);
      await notifier.setSubAgent(
        SubAgentPlan(parallel: 2, providerId: cheap, model: 'mini'),
      );
      final config = await notifier.subAgentConfig();
      expect(config.baseUrl, 'https://cheap/v1');
      expect(config.model, 'mini');
      expect(config.apiKey, 'sk-cheap');
    });
  });

  group('数据模型', () {
    test('allModels 合并缓存与手填、去重且排序', () {
      const p = LlmProviderConfig(
        id: 'p',
        models: ['b', 'a', 'b'],
        manualModels: ['c', 'a'],
      );
      expect(p.allModels, ['a', 'b', 'c']);
    });

    test('没名字时用主机名兜底', () {
      const p = LlmProviderConfig(id: 'p', baseUrl: 'https://api.foo.com/v1');
      expect(p.label, 'api.foo.com');
      expect(const LlmProviderConfig(id: 'p').label, '未命名提供商');
    });

    test('activeId 指向不存在的家 → 回落第一条', () {
      const registry = LlmRegistry(
        providers: [LlmProviderConfig(id: 'a'), LlmProviderConfig(id: 'b')],
        activeId: 'gone',
      );
      expect(registry.active.id, 'a');
    });

    test('并行度与轮次从 JSON 读回来会被夹住', () {
      final plan = SubAgentPlan.fromJson({'parallel': 99, 'maxTurns': 1});
      expect(plan.parallel, 8);
      expect(plan.maxTurns, 4);
    });

    test('提供商 JSON 往返不丢字段', () {
      final p = LlmProviderConfig(
        id: 'p1',
        name: '云端',
        baseUrl: 'https://b/v1',
        models: const ['m1'],
        manualModels: const ['m2'],
        contextLimits: const {'m1': 32000},
        defaultModel: 'm1',
        timeoutSeconds: 200,
        extraHeaders: '{"a":"b"}',
        extraBody: '{"c":1}',
        modelsFetchedAt: DateTime.parse('2026-01-02T03:04:05.000'),
      );
      final back =
          LlmProviderConfig.fromJson(jsonDecode(jsonEncode(p.toJson())));
      expect(back.name, '云端');
      expect(back.contextLimits['m1'], 32000);
      expect(back.timeoutSeconds, 200);
      expect(back.modelsFetchedAt, p.modelsFetchedAt);
      expect(back.extraBody, '{"c":1}');
    });
  });
}
