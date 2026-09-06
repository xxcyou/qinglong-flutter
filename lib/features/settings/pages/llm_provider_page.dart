import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/llm_provider.dart';
import '../../../core/llm/llm_registry_provider.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../core/theme/glass.dart';
import '../../../core/utils/formatter.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/text_input_dialog.dart';
import '../../ai/providers/chat_provider.dart';

/// 提供商管理：一家一条连接配置，外加子代理编队。
///
/// AI 的连接配置（Base URL / API Key / 超时 / 透传头体 / 模型缓存）全部
/// 收进"提供商"这一层。以前是全局一份，想同时用两家只能来回改地址，
/// 改一次模型缓存被覆盖一次。
class LlmProviderPage extends ConsumerWidget {
  const LlmProviderPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(llmRegistryProvider);
    final scheme = Theme.of(context).colorScheme;

    return GlassScaffold(
      title: '提供商',
      subtitle: registry.providers.isEmpty
          ? '还没有提供商，先添加一家'
          : '${registry.providers.length} 家 · 当前 ${registry.active.label}',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 54),
        children: [
          const SectionLabel('提供商'),
          if (registry.providers.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassCard(
                child: Text(
                  '一家提供商 = 一个 OpenAI 兼容端点 + 一把 Key + 它自己的模型列表。'
                  '添加多家之后，选模型时先挑家再挑模型，两边的模型缓存互不影响。',
                  style:
                      TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          for (final provider in registry.providers)
            _ProviderTile(
              provider: provider,
              active: provider.id == registry.active.id,
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassCard(
              onTap: () async {
                final name = await showTextInputDialog(
                  context,
                  title: '添加提供商',
                  hintText: '例如：本地网关 / OpenRouter',
                  helperText: '只是个名字，后面还要填 Base URL 和 Key',
                  confirmText: '添加',
                );
                if (name == null) return;
                final id = await ref
                    .read(llmRegistryProvider.notifier)
                    .addProvider(name: name.trim());
                if (!context.mounted) return;
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => LlmProviderEditPage(providerId: id),
                  ),
                );
              },
              child: Row(
                children: [
                  Icon(Icons.add_circle_outline, color: scheme.primary),
                  const SizedBox(width: 12),
                  const Text(
                    '添加提供商',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          const SectionLabel('主代理'),
          const _MainAgentSection(),
          const SectionLabel('子代理'),
          const _SubAgentSection(),
        ],
      ),
    );
  }
}

/// 主代理轮次预算：默认 200，手动填。
class _MainAgentSection extends ConsumerWidget {
  const _MainAgentSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(llmRegistryProvider);
    final notifier = ref.read(llmRegistryProvider.notifier);
    return _PickRow(
      icon: Icons.loop,
      title: '主代理轮次预算',
      value: '${registry.mainMaxTurns} 轮',
      onTap: () async {
        final v = await showTextInputDialog(
          context,
          title: '主代理轮次预算',
          initialValue: '${registry.mainMaxTurns}',
          helperText: '主 agent 最多跑几轮工具调用。4-1000，默认 200',
          keyboardType: TextInputType.number,
          confirmText: '保存',
        );
        final n = int.tryParse((v ?? '').trim());
        if (n == null) return;
        await notifier.setMainMaxTurns(n);
      },
    );
  }
}

class _ProviderTile extends ConsumerWidget {
  const _ProviderTile({required this.provider, required this.active});

  final LlmProviderConfig provider;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final models = provider.allModels;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        selected: active,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LlmProviderEditPage(providerId: provider.id),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: active ? '当前使用' : '设为当前',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                active
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: active ? scheme.primary : null,
                size: 20,
              ),
              onPressed: active
                  ? null
                  : () => ref
                      .read(llmRegistryProvider.notifier)
                      .setActive(provider.id),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    provider.label,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    provider.isConfigured
                        ? '${provider.baseUrl}\n'
                            '${models.length} 个模型'
                            '${provider.defaultModel.isEmpty ? '' : ' · ${provider.defaultModel}'}'
                        : '还没填 Base URL',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: provider.isConfigured
                          ? scheme.onSurfaceVariant
                          : scheme.error,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

/// 子代理编队：几个人干、用谁的模型、每人几轮。
class _SubAgentSection extends ConsumerWidget {
  const _SubAgentSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(llmRegistryProvider);
    final plan = registry.subAgent;
    final notifier = ref.read(llmRegistryProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final source = plan.overridesModel
        ? (registry.byId(plan.providerId)?.label ?? '（已删除的提供商）')
        : '跟主代理一样';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '并行数量',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'parallel_agents 一次最多同时跑 ${plan.parallel} 个子代理。'
                  '手机上 2-3 个比较稳：再多就是自己抢 CPU 和网络，'
                  '而且终端、浏览器是全机唯一的，用到它们的子代理只会排队。',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Slider(
                  value: plan.parallel.toDouble().clamp(1, 8),
                  min: 1,
                  max: 8,
                  divisions: 7,
                  label: '${plan.parallel}',
                  onChanged: (v) =>
                      notifier.setSubAgent(plan.copyWith(parallel: v.round())),
                ),
              ],
            ),
          ),
        ),
        _PickRow(
          icon: Icons.account_tree_outlined,
          title: '子代理用的模型',
          value: plan.overridesModel
              ? '$source · ${plan.model.isEmpty ? "该家默认模型" : plan.model}'
              : '跟主代理一样',
          onTap: () => _pickWorkerModel(context, ref),
        ),
        _PickRow(
          icon: Icons.loop,
          title: '子代理轮次预算',
          value: '${plan.maxTurns} 轮',
          onTap: () async {
            final v = await showTextInputDialog(
              context,
              title: '子代理轮次预算',
              initialValue: '${plan.maxTurns}',
              helperText: '一个子代理最多跑几轮工具调用。4-200，默认 64',
              keyboardType: TextInputType.number,
              confirmText: '保存',
            );
            final n = int.tryParse((v ?? '').trim());
            if (n == null) return;
            await notifier
                .setSubAgent(plan.copyWith(maxTurns: n.clamp(4, 200)));
          },
        ),
      ],
    );
  }

  Future<void> _pickWorkerModel(BuildContext context, WidgetRef ref) async {
    final registry = ref.read(llmRegistryProvider);
    final plan = registry.subAgent;
    final choice = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 460),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              ListTile(
                leading: const Icon(Icons.link_off),
                title: const Text('跟主代理一样'),
                subtitle: const Text(
                  '主代理换模型，子代理跟着换',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(context, ('', '')),
              ),
              for (final provider in registry.providers) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    provider.label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (provider.allModels.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      '这家还没有模型列表',
                      style: TextStyle(fontSize: 12),
                    ),
                  )
                else
                  for (final model in provider.allModels)
                    ListTile(
                      dense: true,
                      leading:
                          plan.providerId == provider.id && plan.model == model
                              ? const Icon(Icons.check, size: 18)
                              : const SizedBox(width: 18),
                      title: Text(model, style: const TextStyle(fontSize: 13)),
                      onTap: () => Navigator.pop(context, (provider.id, model)),
                    ),
              ],
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    await ref.read(llmRegistryProvider.notifier).setSubAgent(
          plan.copyWith(providerId: choice.$1, model: choice.$2),
        );
  }
}

/// 单家提供商的编辑页。
class LlmProviderEditPage extends ConsumerStatefulWidget {
  const LlmProviderEditPage({required this.providerId, super.key});

  final String providerId;

  @override
  ConsumerState<LlmProviderEditPage> createState() =>
      _LlmProviderEditPageState();
}

class _LlmProviderEditPageState extends ConsumerState<LlmProviderEditPage> {
  bool _hasKey = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _refreshKeyState();
  }

  Future<void> _refreshKeyState() async {
    final key =
        await SecureStorage.readLlmApiKey(providerId: widget.providerId);
    if (!mounted) return;
    setState(() => _hasKey = (key ?? '').isNotEmpty);
  }

  Future<void> _save(LlmProviderConfig next) =>
      ref.read(llmRegistryProvider.notifier).updateProvider(next);

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(llmRegistryProvider);
    final provider = registry.byId(widget.providerId);
    if (provider == null) {
      return const GlassScaffold(
        title: '提供商',
        body: Center(child: Text('这家已经被删除了')),
      );
    }
    final active = registry.active.id == provider.id;
    final models = provider.allModels;
    final scheme = Theme.of(context).colorScheme;

    return GlassScaffold(
      title: provider.label,
      subtitle: provider.isConfigured
          ? '${models.length} 个模型${active ? ' · 当前使用' : ''}'
          : '未配置',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 54),
        children: [
          const SectionLabel('连接'),
          _PickRow(
            icon: Icons.badge_outlined,
            title: '名称',
            value: provider.name.isEmpty ? '未命名' : provider.name,
            onTap: () async {
              final v = await showTextInputDialog(
                context,
                title: '提供商名称',
                initialValue: provider.name,
                confirmText: '保存',
              );
              if (v == null) return;
              await _save(provider.copyWith(name: v.trim()));
            },
          ),
          _PickRow(
            icon: Icons.link,
            title: 'Base URL',
            value: provider.baseUrl.isEmpty ? '未配置' : provider.baseUrl,
            onTap: () async {
              final v = await showTextInputDialog(
                context,
                title: 'Base URL',
                initialValue: provider.baseUrl,
                hintText: 'https://api.openai.com/v1',
                helperText: '兼容 OpenAI 的 /chat/completions 接口，填到 /v1 即可',
                confirmText: '保存',
              );
              if (v == null) return;
              await _save(provider.copyWith(baseUrl: v.trim()));
            },
          ),
          _PickRow(
            icon: Icons.key_outlined,
            title: 'API Key',
            value: _hasKey ? '已保存（安全存储）' : '未配置',
            onTap: _editApiKey,
          ),
          _PickRow(
            icon: Icons.timer_outlined,
            title: '请求超时',
            value: '${provider.timeoutSeconds} 秒',
            onTap: () async {
              final v = await showTextInputDialog(
                context,
                title: '请求超时（秒）',
                initialValue: '${provider.timeoutSeconds}',
                helperText: 'Agent 一轮可能长时间思考，建议不低于 120',
                keyboardType: TextInputType.number,
                confirmText: '保存',
              );
              final n = int.tryParse((v ?? '').trim());
              if (n == null || n < 10) return;
              await _save(provider.copyWith(timeoutSeconds: n));
            },
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassCard(
              onTap: _testing ? null : () => _test(provider),
              child: Row(
                children: [
                  if (_testing)
                    const SizedBox(
                      width: 21,
                      height: 21,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Icon(Icons.network_check, size: 21),
                  const SizedBox(width: 12),
                  Text(
                    _testing ? '测试中…' : '测试连接',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          if (!active)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassCard(
                onTap: () async {
                  await ref
                      .read(llmRegistryProvider.notifier)
                      .setActive(provider.id);
                  _toast('已切换到 ${provider.label}');
                },
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: scheme.primary),
                    const SizedBox(width: 12),
                    const Text(
                      '设为当前使用',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          const SectionLabel('模型'),
          _ProviderModels(providerId: provider.id),
          const SectionLabel('高级透传'),
          _PickRow(
            icon: Icons.data_object,
            title: '额外 body 字段',
            value: provider.extraBody.isEmpty
                ? '未配置'
                : provider.extraBody.replaceAll('\n', ' '),
            onTap: () => _editJson(
              title: '额外 body 字段',
              initial: provider.extraBody,
              helper: 'JSON 对象。透传厂商私有参数，例如 {"enable_thinking": true}',
              onSave: (v) => _save(provider.copyWith(extraBody: v)),
            ),
          ),
          _PickRow(
            icon: Icons.http,
            title: '额外请求头',
            value: provider.extraHeaders.isEmpty
                ? '未配置'
                : provider.extraHeaders.replaceAll('\n', ' '),
            onTap: () => _editJson(
              title: '额外请求头',
              initial: provider.extraHeaders,
              helper: 'JSON 对象。例如 {"HTTP-Referer": "https://example.com"}',
              onSave: (v) => _save(provider.copyWith(extraHeaders: v)),
            ),
          ),
          const SectionLabel('危险操作'),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassCard(
              onTap: () async {
                final ok = await showConfirmDialog(
                  context,
                  title: '删除提供商',
                  message: '删掉「${provider.label}」？'
                      '它的 API Key 和模型缓存会一起删除，这一步不可撤销。',
                  confirmText: '删除',
                  destructive: true,
                );
                if (ok != true) return;
                await ref
                    .read(llmRegistryProvider.notifier)
                    .removeProvider(provider.id);
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
              child: Row(
                children: [
                  Icon(Icons.delete_outline, color: scheme.error),
                  const SizedBox(width: 12),
                  Text(
                    '删除这家提供商',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: scheme.error,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _test(LlmProviderConfig provider) async {
    setState(() => _testing = true);
    try {
      final (ok, why) =
          await ref.read(chatProvider.notifier).testProviderDetail(provider.id);
      _toast(ok ? '连接成功' : '连接失败：$why');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _editApiKey() async {
    final current =
        await SecureStorage.readLlmApiKey(providerId: widget.providerId);
    if (!mounted) return;
    final result = await showTextInputDialog(
      context,
      title: 'API Key',
      initialValue: current ?? '',
      hintText: 'sk-...',
      helperText: '仅保存在本机安全存储，不写日志',
      obscureText: true,
      confirmText: '保存',
    );
    if (result == null) return;
    if (result.isEmpty) {
      await SecureStorage.deleteLlmApiKey(providerId: widget.providerId);
    } else {
      await SecureStorage.saveLlmApiKey(
        result,
        providerId: widget.providerId,
      );
    }
    // 只重算配置，**不能** invalidate 提供商总表：
    // invalidate 一个 NotifierProvider 会把 notifier 整个丢掉重建，
    // 状态回到空表、`load()` 也不会自动再跑一次，界面上提供商会全部消失。
    ref.invalidate(llmConfigProvider);
    await _refreshKeyState();
  }

  Future<void> _editJson({
    required String title,
    required String initial,
    required String helper,
    required Future<void> Function(String) onSave,
  }) async {
    final v = await showTextInputDialog(
      context,
      title: title,
      initialValue: initial,
      helperText: helper,
      maxLines: 4,
      confirmText: '保存',
    );
    if (v == null) return;
    final text = v.trim();
    if (text.isNotEmpty) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is! Map) {
          _toast('要填 JSON 对象（大括号包起来）');
          return;
        }
      } catch (_) {
        _toast('JSON 格式不对，没保存');
        return;
      }
    }
    await onSave(text);
  }
}

/// 某一家的模型列表：获取 / 手填 / 选默认。
class _ProviderModels extends ConsumerWidget {
  const _ProviderModels({required this.providerId});

  final String providerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(llmRegistryProvider);
    final provider = registry.byId(providerId);
    if (provider == null) return const SizedBox.shrink();
    final chat = ref.watch(chatProvider);
    final notifier = ref.read(chatProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final models = provider.allModels;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GlassPanel(
            radius: 18,
            blur: 14,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  provider.modelsFetchedAt == null
                      ? '还没获取过模型列表'
                      : '已缓存 ${models.length} 个 · '
                          '${Formatter.dateTime(provider.modelsFetchedAt!)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    GlassPill(
                      icon: Icons.refresh,
                      label: chat.isLoadingModels ? '获取中…' : '获取并缓存模型',
                      dense: true,
                      onTap: chat.isLoadingModels
                          ? null
                          : () async {
                              await notifier.loadModelsFor(providerId);
                              if (!context.mounted) return;
                              final err = ref.read(chatProvider).modelsError;
                              final n = ref
                                      .read(llmRegistryProvider)
                                      .byId(providerId)
                                      ?.allModels
                                      .length ??
                                  0;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    err != null && err.isNotEmpty
                                        ? '获取失败：$err'
                                        : '获取到 $n 个模型',
                                  ),
                                  duration:
                                      Duration(seconds: err == null ? 2 : 8),
                                ),
                              );
                            },
                    ),
                    GlassPill(
                      icon: Icons.add,
                      label: '手动添加',
                      dense: true,
                      onTap: () async {
                        final name = await showTextInputDialog(
                          context,
                          title: '手动添加模型',
                          hintText: 'deepseek-chat',
                          helperText: '接口不返回列表时可以自己填，刷新也不会丢',
                          confirmText: '添加',
                        );
                        if (name == null || name.trim().isEmpty) return;
                        await notifier.addManualModelTo(
                          providerId,
                          name.trim(),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (models.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassCard(
              child: Text(
                '还没有模型。先填好 Base URL 与 API Key 再点「获取并缓存模型」，'
                '或者直接手动添加模型名。',
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            ),
          )
        else
          for (final m in models)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassCard(
                selected: m == provider.defaultModel,
                onTap: () => ref
                    .read(llmRegistryProvider.notifier)
                    .setDefaultModel(providerId, m),
                child: Row(
                  children: [
                    Icon(
                      m == provider.defaultModel
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: m == provider.defaultModel ? scheme.primary : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '上下文 ${provider.contextLimits[m] ?? 8000} tokens',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '设置上下文长度',
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        final v = await showTextInputDialog(
                          context,
                          title: '$m 的上下文长度',
                          initialValue: '${provider.contextLimits[m] ?? 8000}',
                          hintText: '8000',
                          helperText: '用于计算上下文占用比例与自动压缩时机',
                          keyboardType: TextInputType.number,
                          confirmText: '保存',
                        );
                        final n = int.tryParse((v ?? '').trim());
                        if (n == null || n < 1000) return;
                        await ref
                            .read(llmRegistryProvider.notifier)
                            .updateProvider(
                              provider.copyWith(
                                contextLimits: {
                                  ...provider.contextLimits,
                                  m: n,
                                },
                              ),
                            );
                      },
                      icon: const Icon(Icons.straighten, size: 18),
                    ),
                    IconButton(
                      tooltip: '移除',
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        final ok = await showConfirmDialog(
                          context,
                          title: '移除模型',
                          message: '从这家的列表里移除 $m？'
                              '下次获取若接口仍返回它会回来。',
                          confirmText: '移除',
                        );
                        if (ok != true) return;
                        final rest = <String>{
                          ...provider.models.where((x) => x != m),
                          ...provider.manualModels.where((x) => x != m),
                        }.toList()
                          ..sort();
                        await ref
                            .read(llmRegistryProvider.notifier)
                            .updateProvider(
                              provider.copyWith(
                                models: provider.models
                                    .where((x) => x != m)
                                    .toList(growable: false),
                                manualModels: provider.manualModels
                                    .where((x) => x != m)
                                    .toList(growable: false),
                                contextLimits: {...provider.contextLimits}
                                  ..remove(m),
                                defaultModel: provider.defaultModel == m
                                    ? (rest.isEmpty ? '' : rest.first)
                                    : provider.defaultModel,
                              ),
                            );
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

/// 一行"点进去改"的设置项。
class _PickRow extends StatelessWidget {
  const _PickRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        onTap: onTap,
        child: Row(
          children: [
            Icon(icon, size: 21),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
