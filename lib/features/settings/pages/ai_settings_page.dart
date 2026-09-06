import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/llm_registry_provider.dart';
import '../../../core/theme/glass.dart';
import '../../../core/utils/formatter.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/text_input_dialog.dart';
import '../../ai/models/approval_mode.dart';
import '../../ai/pages/mcp_server_page.dart';
import '../../ai/pages/skill_list_page.dart';
import '../../ai/providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import 'llm_provider_page.dart';

/// AI 详细设置：连接、模型、采样参数、上下文、扩展、悬浮球。
///
/// 从设置页的一个入口跳进来，避免主设置页被 AI 的十几个开关淹没。
class AiSettingsPage extends ConsumerStatefulWidget {
  const AiSettingsPage({super.key});

  @override
  ConsumerState<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends ConsumerState<AiSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final chat = ref.watch(chatProvider);
    final registry = ref.watch(llmRegistryProvider);
    final ready = registry.active.isConfigured;

    return GlassScaffold(
      title: 'AI 设置',
      subtitle: ready
          ? '${registry.active.label} · ${chat.availableModels.length} 个模型'
          : '尚未配置连接',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 54),
        children: [
          const SectionLabel('连接'),
          // Base URL / API Key / 超时 / 透传头体全都搬进"提供商"了：
          // 那几项天生是每家一套，放在全局的时候想同时用两家只能来回改，
          // 改一次模型缓存被覆盖一次。
          _Row(
            icon: Icons.cloud_outlined,
            title: '提供商',
            value: registry.providers.isEmpty
                ? '还没配置，点进去添加'
                : '${registry.active.label} · 共 ${registry.providers.length} 家',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LlmProviderPage()),
            ),
          ),
          _Row(
            icon: Icons.account_tree_outlined,
            title: '子代理',
            value: '并行 ${registry.subAgent.parallel} 个 · '
                '${registry.subAgent.overridesModel ? '${registry.byId(registry.subAgent.providerId)?.label ?? "已删除"} / ${registry.subAgent.model.isEmpty ? "默认模型" : registry.subAgent.model}' : '跟主代理同一个模型'}',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LlmProviderPage()),
            ),
          ),
          _TestRow(
            onTest: () async {
              // 要带上真正的原因。以前统一弹"检查 URL / Key / 模型"，
              // 自签名 HTTPS 的网关会让人照着这句话反复查地址和 Key，
              // 而开关在「设置 → 允许自签名 HTTPS」。
              final (ok, why) =
                  await ref.read(chatProvider.notifier).testConnectionDetail();
              if (!mounted) return;
              _toast(ok ? '连接成功' : '连接失败：$why');
            },
          ),
          const SectionLabel('模型'),
          _ModelSection(onChanged: () => setState(() {})),
          const SectionLabel('推理与采样'),
          _Row(
            icon: Icons.psychology_outlined,
            title: '思考强度',
            value: switch (chat.reasoningEffort) {
              0 => '无（不发 reasoning_effort）',
              1 => '低',
              2 => '中',
              _ => '高',
            },
            onTap: _pickEffort,
          ),
          _Row(
            icon: Icons.thermostat_outlined,
            title: 'temperature',
            value: settings.llmTemperature?.toString() ?? '默认（不发送）',
            onTap: () => _editOptionalDouble(
              title: 'temperature',
              initial: settings.llmTemperature,
              helper: '0~2，越大越随机。留空表示不发这个字段',
              onSave: (v) => _update(
                v == null
                    ? settings.copyWith(clearTemperature: true)
                    : settings.copyWith(llmTemperature: v),
              ),
            ),
          ),
          _Row(
            icon: Icons.pie_chart_outline,
            title: 'top_p',
            value: settings.llmTopP?.toString() ?? '默认（不发送）',
            onTap: () => _editOptionalDouble(
              title: 'top_p',
              initial: settings.llmTopP,
              helper: '0~1。一般只调 temperature 或 top_p 之一',
              onSave: (v) => _update(
                v == null
                    ? settings.copyWith(clearTopP: true)
                    : settings.copyWith(llmTopP: v),
              ),
            ),
          ),
          _Row(
            icon: Icons.short_text,
            title: 'max_tokens',
            value: settings.llmMaxTokens?.toString() ?? '默认（不发送）',
            onTap: () => _editOptionalInt(
              title: 'max_tokens',
              initial: settings.llmMaxTokens,
              helper: '单次回复上限。工具调用多的场景别设太小',
              onSave: (v) => _update(
                v == null
                    ? settings.copyWith(clearMaxTokens: true)
                    : settings.copyWith(llmMaxTokens: v),
              ),
            ),
          ),
          _Row(
            icon: Icons.repeat,
            title: 'frequency_penalty',
            value: settings.llmFrequencyPenalty?.toString() ?? '默认（不发送）',
            onTap: () => _editOptionalDouble(
              title: 'frequency_penalty',
              initial: settings.llmFrequencyPenalty,
              helper: '-2~2，抑制重复用词',
              onSave: (v) => _update(
                v == null
                    ? settings.copyWith(clearFrequencyPenalty: true)
                    : settings.copyWith(llmFrequencyPenalty: v),
              ),
            ),
          ),
          _Row(
            icon: Icons.new_releases_outlined,
            title: 'presence_penalty',
            value: settings.llmPresencePenalty?.toString() ?? '默认（不发送）',
            onTap: () => _editOptionalDouble(
              title: 'presence_penalty',
              initial: settings.llmPresencePenalty,
              helper: '-2~2，鼓励换新话题',
              onSave: (v) => _update(
                v == null
                    ? settings.copyWith(clearPresencePenalty: true)
                    : settings.copyWith(llmPresencePenalty: v),
              ),
            ),
          ),
          const SectionLabel('上下文'),
          _ContextCard(
            threshold: chat.autoCompressThreshold,
            onThreshold: (v) =>
                ref.read(chatProvider.notifier).setAutoCompressThreshold(v),
          ),
          _Row(
            icon: Icons.straighten,
            title: '默认上下文长度',
            value: '${settings.llmDefaultContextLimit} tokens',
            onTap: () => _editNumber(
              title: '默认上下文长度',
              initial: '${settings.llmDefaultContextLimit}',
              helper: '新模型没有实测值时按这个算占用比例',
              onSave: (v) {
                final n = int.tryParse(v);
                if (n == null || n < 1000) return;
                _update(settings.copyWith(llmDefaultContextLimit: n));
              },
            ),
          ),
          const SectionLabel('行为'),
          _Row(
            icon: switch (chat.approvalMode) {
              AiApprovalMode.strict => Icons.lock_outline,
              AiApprovalMode.cautious => Icons.shield_outlined,
              AiApprovalMode.full => Icons.rocket_launch_outlined,
            },
            title: '写操作确认策略',
            value:
                '${chat.approvalMode.label} · ${chat.approvalMode.description}',
            onTap: _pickApproval,
          ),
          const SectionLabel('扩展'),
          _Row(
            icon: Icons.auto_stories_outlined,
            title: '技能库',
            value: '给 AI 装操作手册，遇到对应场景自己读',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SkillListPage()),
            ),
          ),
          _Row(
            icon: Icons.extension_outlined,
            title: 'MCP 扩展',
            value: '接入外部工具服务器（联网搜索、设备控制等）',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const McpServerPage()),
            ),
          ),
        ],
      ),
    );
  }

  void _update(AppSettings next) {
    // 等对话框路由退干净再写，避免失活期间触发重建。
    Future.microtask(() => ref.read(settingsProvider.notifier).update(next));
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _editNumber({
    required String title,
    required String initial,
    String? helper,
    required ValueChanged<String> onSave,
  }) async {
    final result = await showTextInputDialog(
      context,
      title: title,
      initialValue: initial,
      hintText: '整数',
      helperText: helper ?? '',
      keyboardType: TextInputType.number,
      confirmText: '保存',
    );
    if (result != null) onSave(result.trim());
  }

  Future<void> _editOptionalDouble({
    required String title,
    required double? initial,
    String? helper,
    required ValueChanged<double?> onSave,
  }) async {
    final result = await showTextInputDialog(
      context,
      title: title,
      initialValue: initial?.toString() ?? '',
      hintText: '留空 = 不发送',
      helperText: helper ?? '',
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true, signed: true),
      confirmText: '保存',
    );
    if (result == null) return;
    final text = result.trim();
    if (text.isEmpty) {
      onSave(null);
      return;
    }
    final v = double.tryParse(text);
    if (v == null) {
      _toast('不是有效数字');
      return;
    }
    onSave(v);
  }

  Future<void> _editOptionalInt({
    required String title,
    required int? initial,
    String? helper,
    required ValueChanged<int?> onSave,
  }) async {
    final result = await showTextInputDialog(
      context,
      title: title,
      initialValue: initial?.toString() ?? '',
      hintText: '留空 = 不发送',
      helperText: helper ?? '',
      keyboardType: TextInputType.number,
      confirmText: '保存',
    );
    if (result == null) return;
    final text = result.trim();
    if (text.isEmpty) {
      onSave(null);
      return;
    }
    final v = int.tryParse(text);
    if (v == null || v <= 0) {
      _toast('要填正整数');
      return;
    }
    onSave(v);
  }

  Future<void> _pickEffort() async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in const [0, 1, 2, 3])
              ListTile(
                title: Text(switch (e) {
                  0 => '无',
                  1 => '低',
                  2 => '中',
                  _ => '高',
                }),
                subtitle: Text(switch (e) {
                  0 => '不发 reasoning_effort，兼容不支持该字段的接口',
                  1 => '省 token，适合简单问答',
                  2 => '平衡',
                  _ => '复杂排查建议用高',
                }),
                onTap: () => Navigator.pop(context, e),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    ref.read(chatProvider.notifier).setReasoningEffort(chosen);
  }

  Future<void> _pickApproval() async {
    final chosen = await showModalBottomSheet<AiApprovalMode>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in AiApprovalMode.values)
              ListTile(
                leading: Icon(switch (mode) {
                  AiApprovalMode.strict => Icons.lock_outline,
                  AiApprovalMode.cautious => Icons.shield_outlined,
                  AiApprovalMode.full => Icons.rocket_launch_outlined,
                }),
                title: Text(mode.label),
                subtitle: Text(
                  mode.description,
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(context, mode),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    ref.read(chatProvider.notifier).setApprovalMode(chosen);
  }
}

class _Row extends StatelessWidget {
  const _Row({
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

class _TestRow extends StatefulWidget {
  const _TestRow({required this.onTest});

  final Future<void> Function() onTest;

  @override
  State<_TestRow> createState() => _TestRowState();
}

class _TestRowState extends State<_TestRow> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        onTap: _busy
            ? null
            : () async {
                setState(() => _busy = true);
                try {
                  await widget.onTest();
                } finally {
                  if (mounted) setState(() => _busy = false);
                }
              },
        child: Row(
          children: [
            if (_busy)
              const SizedBox(
                width: 21,
                height: 21,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.network_check, size: 21),
            const SizedBox(width: 12),
            Text(
              _busy ? '测试中…' : '测试连接',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// 模型区：自动获取 + 手动添加 + 单个模型的上下文长度与连通性。
class _ModelSection extends ConsumerWidget {
  const _ModelSection({required this.onChanged});

  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final chat = ref.watch(chatProvider);
    final notifier = ref.read(chatProvider.notifier);

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
                  '当前使用：${chat.selectedModel.isEmpty ? "未选择" : chat.selectedModel}',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Builder(
                  builder: (context) {
                    final provider = ref.watch(llmRegistryProvider).active;
                    final at = provider.modelsFetchedAt;
                    return Text(
                      at == null
                          ? '还没缓存模型列表，点下面「获取并缓存模型」'
                          : '${provider.label} 已缓存 '
                              '${provider.allModels.length} 个模型 · '
                              '${Formatter.dateTime(at)}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    );
                  },
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
                      tooltip: 'AI 页只读这份缓存，不会自己去拉列表',
                      onTap: chat.isLoadingModels
                          ? null
                          : () async {
                              await notifier.loadModels();
                              if (!context.mounted) return;
                              final n =
                                  ref.read(chatProvider).availableModels.length;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('获取到 $n 个模型')),
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
                        notifier.addManualModel(name.trim());
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (chat.availableModels.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassCard(
              child: Text(
                '还没有模型。先填好 Base URL 与 API Key 再点「自动获取」，或直接手动添加模型名。',
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            ),
          )
        else
          for (final m in chat.availableModels)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassCard(
                selected: m == chat.selectedModel,
                onTap: () => notifier.setModel(m),
                child: Row(
                  children: [
                    Icon(
                      m == chat.selectedModel
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: m == chat.selectedModel ? scheme.primary : null,
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
                            '上下文 ${chat.modelContextLimits[m] ?? 8000} tokens'
                            '${chat.modelTestResults[m] == null ? '' : (chat.modelTestResults[m]! ? ' · 连通' : ' · 不通')}',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: chat.modelTestResults[m] == false
                                  ? scheme.error
                                  : scheme.onSurfaceVariant,
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
                          initialValue: '${chat.modelContextLimits[m] ?? 8000}',
                          hintText: '8000',
                          helperText: '用于计算上下文占用比例与自动压缩时机',
                          keyboardType: TextInputType.number,
                          confirmText: '保存',
                        );
                        final n = int.tryParse((v ?? '').trim());
                        if (n == null || n < 1000) return;
                        notifier.setModelContextLimit(m, n);
                      },
                      icon: const Icon(Icons.straighten, size: 18),
                    ),
                    IconButton(
                      tooltip: '测试该模型',
                      visualDensity: VisualDensity.compact,
                      onPressed: chat.testingModel == m
                          ? null
                          : () => notifier.testModel(m),
                      icon: chat.testingModel == m
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bolt, size: 18),
                    ),
                    IconButton(
                      tooltip: '移除',
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        final ok = await showConfirmDialog(
                          context,
                          title: '移除模型',
                          message: '从列表里移除 $m？下次自动获取若接口仍返回它会回来。',
                          confirmText: '移除',
                        );
                        if (ok != true) return;
                        notifier.removeModel(m);
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

class _ContextCard extends StatelessWidget {
  const _ContextCard({required this.threshold, required this.onThreshold});

  final double threshold;
  final ValueChanged<double> onThreshold;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '自动压缩阈值',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              '上下文用到 ${(threshold * 100).round()}% 时自动总结压缩历史',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            Slider(
              value: threshold.clamp(0.3, 1.0),
              min: 0.3,
              max: 1.0,
              divisions: 14,
              label: '${(threshold * 100).round()}%',
              onChanged: onThreshold,
            ),
          ],
        ),
      ),
    );
  }
}
