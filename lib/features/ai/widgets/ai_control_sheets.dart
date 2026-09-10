import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatter.dart';
import '../../../core/llm/llm_registry_provider.dart';
import '../models/approval_mode.dart';
import '../providers/chat_provider.dart';

/// AI 控制条上四个胶囊对应的底部弹窗。
///
/// AI 页和悬浮窗共用同一套输入区（`AiComposer`），所以这些弹窗也必须共用，
/// 否则两处行为会漂移。悬浮窗调用时传根 Navigator 的 context。
class AiControlSheets {
  const AiControlSheets._();

  /// 当前上下文占用（和输入行上的百分比同一套算法）。
  ///
  /// 有服务端报回来的 prompt_tokens 就用它——那是唯一准确的数字；
  /// 还没跑过一轮时才退回字符估算。
  static int estimateUsedTokens(ChatState state) {
    // 服务端数值优先；如果它明显低于本地按真实 history 的估算
    // （常见于网关只报了“增量/其他”token），就取较大者，避免显示成几百 token。
    final lastContext = Formatter.serverContextTokens(
        state.lastPromptTokens, state.lastCacheHitTokens);
    if (lastContext > 0) {
      return lastContext > state.estimatedContextTokens
          ? lastContext
          : state.estimatedContextTokens;
    }
    if (state.estimatedContextTokens > 0) return state.estimatedContextTokens;
    final chars = state.messages.fold<int>(
      0,
      (sum, m) => sum + m.content.length + m.toolCalls.length * 80 + 20,
    );
    return (chars / 3.5).ceil();
  }

  /// 写操作确认策略：严格 / 仅危险 / 全部放行。
  static void showApproval(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final state = ref.watch(chatProvider);
          final notifier = ref.read(chatProvider.notifier);
          final scheme = Theme.of(context).colorScheme;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 20, 20, 4),
                  child: Text(
                    '写操作确认策略',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    '决定 AI 动手改东西之前要不要先问你',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
                for (final mode in AiApprovalMode.values)
                  ListTile(
                    selected: state.approvalMode == mode,
                    selectedTileColor:
                        scheme.primaryContainer.withValues(alpha: 0.35),
                    leading: Icon(
                      switch (mode) {
                        AiApprovalMode.strict => Icons.lock_outline,
                        AiApprovalMode.cautious => Icons.shield_outlined,
                        AiApprovalMode.full => Icons.rocket_launch_outlined,
                      },
                      color: mode == AiApprovalMode.full ? scheme.error : null,
                    ),
                    title: Text(mode.label),
                    subtitle: Text(
                      mode.description,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: state.approvalMode == mode
                        ? Icon(Icons.check_circle, color: scheme.primary)
                        : null,
                    onTap: () {
                      notifier.setApprovalMode(mode);
                      Navigator.pop(context);
                    },
                  ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 模型选择：先挑提供商，再挑它名下的模型。
  ///
  /// 两步是必须的：多提供商之后同名模型可能在两家都有（很多网关都转发
  /// `deepseek-chat`），只列一串模型名的话根本分不清点的是哪家的。
  static void showModelPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _ModelPickerSheet(),
    );
  }

  /// 模型强度 + 自动压缩阈值。
  static void showStrength(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final state = ref.watch(chatProvider);
          final notifier = ref.read(chatProvider.notifier);
          const labels = ['无', '低', '中', '高'];
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '模型强度：${labels[state.reasoningEffort]}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Slider(
                    value: state.reasoningEffort.toDouble(),
                    min: 0,
                    max: 3,
                    divisions: 3,
                    label: labels[state.reasoningEffort],
                    onChanged: (v) => notifier.setReasoningEffort(v.round()),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '自动压缩阈值：${(state.autoCompressThreshold * 100).round()}%',
                    style: const TextStyle(fontSize: 14),
                  ),
                  Slider(
                    value: state.autoCompressThreshold,
                    min: 0.3,
                    max: 1.0,
                    divisions: 14,
                    label: '${(state.autoCompressThreshold * 100).round()}%',
                    onChanged: notifier.setAutoCompressThreshold,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 上下文占用 + 当前模型上限。
  static void showContext(BuildContext context, WidgetRef outerRef) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _ContextSheet(),
    );
  }
}

/// 上下文面板：默认折叠，可展开看当前上下文里到底有什么。
class _ContextSheet extends ConsumerStatefulWidget {
  const _ContextSheet();

  @override
  ConsumerState<_ContextSheet> createState() => _ContextSheetState();
}

class _ContextSheetState extends ConsumerState<_ContextSheet> {
  late final TextEditingController _limitController;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _limitController = TextEditingController(
      text: ref.read(chatProvider).contextLimit.toString(),
    );
  }

  @override
  void dispose() {
    _limitController.dispose();
    super.dispose();
  }

  void _save() {
    final n = int.tryParse(_limitController.text.trim());
    if (n == null || n <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入大于 0 的数字')),
      );
      return;
    }
    final state = ref.read(chatProvider);
    ref.read(chatProvider.notifier).setModelContextLimit(
          state.selectedModel.isEmpty ? 'default' : state.selectedModel,
          n,
        );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存：$n tokens')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatProvider);
    final used = AiControlSheets.estimateUsedTokens(state);
    final limit = state.contextLimit;
    final percent = limit <= 0 ? 0.0 : (used / limit).clamp(0.0, 1.0);
    final scheme = Theme.of(context).colorScheme;
    // 用当前真正的 history 生成可读预览，确认上下文不是空壳。
    final preview =
        ref.read(chatProvider.notifier).contextPreview(maxChars: 8000);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: percent,
                        strokeWidth: 6,
                      ),
                      Text('${(percent * 100).round()}%'),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    [
                      '上下文占用 ${Formatter.tokens(used)} / '
                          '${Formatter.tokens(limit)} tokens'
                          '${state.lastPromptTokens > 0 ? '（服务端实测）' : '（估算）'}',
                      '本会话累计 '
                          '${Formatter.tokens(state.sessionTokens)} tokens、'
                          '${state.sessionRequests} 次请求',
                      if (state.lastTokens > 0)
                        '上一次任务累计计费 '
                            '${Formatter.tokens(state.lastTokens)} tokens'
                            '（每轮都会重发历史，所以远大于上下文）',
                      if (state.lastCacheHitTokens > 0)
                        '其中命中提示词缓存 '
                            '${Formatter.tokens(state.lastCacheHitTokens)} tokens，'
                            '这部分按约 1/10 计价',
                      '超过 ${(state.autoCompressThreshold * 100).round()}% 会自动压缩',
                    ].join('\n'),
                    style: const TextStyle(fontSize: 12.5, height: 1.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 默认折叠：点一下才展开看上下文内容，避免每次弹窗都一大坨。
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _expanded ? '收起上下文内容' : '展开上下文内容',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${state.messages.length} 条会话消息',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 8),
              Container(
                height: 300,
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: preview.isEmpty
                    ? Center(
                        child: Text(
                          '当前还没有可预览的上下文',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : SingleChildScrollView(
                        child: SelectableText(
                          preview,
                          style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.45,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _limitController,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '当前模型上下文上限（tokens）',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _save,
                child: const Text('保存上下文上限'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 两步选模型：上面一排提供商，下面是这家的模型。
///
/// 翻看另一家不等于切过去——只有点了某个模型才会同时切家 + 选模型。
/// 这样"我就想看看那家有什么模型"不会把正在用的配置换掉。
class _ModelPickerSheet extends ConsumerStatefulWidget {
  const _ModelPickerSheet();

  @override
  ConsumerState<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends ConsumerState<_ModelPickerSheet> {
  /// 当前正在翻看哪家。默认是正在用的那家。
  String _browsing = '';

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(llmRegistryProvider);
    final state = ref.watch(chatProvider);
    final notifier = ref.read(chatProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final activeId = registry.active.id;
    final browsingId = registry.byId(_browsing) == null ? activeId : _browsing;
    final provider = registry.byId(browsingId);
    final models = provider?.allModels ?? const <String>[];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '选择模型',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: state.isLoadingModels || provider == null
                      ? null
                      : () async {
                          await notifier.loadModelsFor(provider.id);
                          if (!context.mounted) return;
                          final err = ref.read(chatProvider).modelsError;
                          final n = ref
                                  .read(llmRegistryProvider)
                                  .byId(provider.id)
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
                              // 失败原因常常是一整句话（自签名证书那条最长），
                              // 默认 4 秒读不完。
                              duration: Duration(seconds: err == null ? 2 : 8),
                            ),
                          );
                        },
                  icon: const Icon(Icons.refresh),
                  label: Text(state.isLoadingModels ? '获取中…' : '重新获取'),
                ),
                TextButton(
                  onPressed: provider == null
                      ? null
                      : () async {
                          final (ok, why) =
                              await notifier.testProviderDetail(provider.id);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(ok ? '连接成功' : '连接失败：$why'),
                              duration: Duration(seconds: ok ? 2 : 8),
                            ),
                          );
                        },
                  child: const Text('测试连通'),
                ),
              ],
            ),
            if (registry.providers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('还没有提供商。到「设置 → AI → 提供商」添加一家。'),
              )
            else ...[
              // 第一步：挑家。当前在用的那家带个勾。
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final p in registry.providers)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          selected: p.id == browsingId,
                          avatar: p.id == activeId
                              ? Icon(
                                  Icons.check_circle,
                                  size: 16,
                                  color: scheme.primary,
                                )
                              : null,
                          label: Text(
                            '${p.label}（${p.allModels.length}）',
                            style: const TextStyle(fontSize: 12.5),
                          ),
                          onSelected: (_) => setState(() => _browsing = p.id),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              if (browsingId != activeId)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '正在翻看「${provider?.label ?? ''}」，点一个模型才会切过去',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (state.modelsError != null && state.modelsError!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    state.modelsError!,
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ),
              if (models.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('这家还没有模型，点上面「重新获取」拉一次。'),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: models.length,
                    itemBuilder: (context, index) {
                      final model = models[index];
                      // "选中"要同时看家和模型：两家都有 deepseek-chat 时，
                      // 只比模型名会在两边都打勾。
                      final selected = browsingId == activeId &&
                          model == state.selectedModel;
                      final testing = state.testingModel == model;
                      final testResult = state.modelTestResults[model];
                      return ListTile(
                        leading: selected
                            ? Icon(Icons.check_circle, color: scheme.primary)
                            : null,
                        title: Text(model),
                        subtitle: Text(
                          '${provider?.contextLimits[model] ?? 8000} ctx'
                          '${testResult == null ? '' : testResult ? ' · 可用' : ' · 不可用'}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          tooltip: '测试该模型',
                          icon: testing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  testResult == null
                                      ? Icons.network_check_outlined
                                      : (testResult
                                          ? Icons.check_circle_outline
                                          : Icons.error_outline),
                                  color: testResult == null
                                      ? null
                                      : (testResult
                                          ? Colors.green
                                          : scheme.error),
                                ),
                          onPressed: testing || browsingId != activeId
                              ? null
                              : () => notifier.testModel(model),
                        ),
                        onTap: () async {
                          await notifier.setProviderAndModel(
                            browsingId,
                            model,
                          );
                          if (!context.mounted) return;
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
