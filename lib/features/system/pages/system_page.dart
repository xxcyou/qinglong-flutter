import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/error_text.dart';
import '../../../shared/ask_ai.dart';
import '../../../shared/confirm_dialog.dart';
import '../../../shared/error_view.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/loading_view.dart';
import '../../../shared/text_input_dialog.dart';
import '../api/system_api.dart';
import '../providers/system_info_provider.dart';
import '../../panels/providers/panel_list_provider.dart';

class SystemPage extends ConsumerStatefulWidget {
  const SystemPage({super.key});

  @override
  ConsumerState<SystemPage> createState() => _SystemPageState();
}

class _SystemPageState extends ConsumerState<SystemPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(systemInfoProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(systemInfoProvider);
    final info = state.info;
    return GlassScaffold(
      title: '系统管理',
      actions: [
        AskAiButton(
          label: '系统信息',
          source: 'system_info',
          contentBuilder: () {
            final current = ref.read(systemInfoProvider).info;
            final currentError = ref.read(systemInfoProvider).error;
            return '青龙版本：${current?.version ?? '-'}\n'
                '日志删除频率：${current?.logRemoveFrequency == null ? '-' : '${current!.logRemoveFrequency} 天'}\n'
                '最近错误：${currentError == null ? '无' : errorText(currentError)}';
          },
          draft: '帮我分析一下青龙面板的系统状态',
        ),
      ],
      body: state.isLoading && info == null
          ? const LoadingView()
          : state.error != null && info == null
              ? ErrorView(
                  message: errorText(state.error!),
                  onRetry: ref.read(systemInfoProvider.notifier).refresh,
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 44),
                  children: [
                    GlassCard(
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              '青龙版本',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Text(info?.version ?? '-'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    GlassCard(
                      child: Row(
                        children: [
                          const Icon(Icons.history),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '日志删除频率',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  info?.logRemoveFrequency == null
                                      ? '-'
                                      : '${info!.logRemoveFrequency} 天',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: _editLogFrequency,
                            icon: const Icon(Icons.edit_outlined),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    GlassCard(
                      onTap: _checkUpdate,
                      child: const Row(
                        children: [
                          Icon(Icons.system_update_alt),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '检测更新',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    GlassCard(
                      onTap: _updatePanel,
                      child: Row(
                        children: [
                          const Icon(Icons.system_update_alt),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '更新面板',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '更新过程中面板可能重启',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                    if (state.error != null) ...[
                      const SizedBox(height: 8),
                      GlassCard(
                        accent: Theme.of(context).colorScheme.error,
                        child: Text(
                          '最近错误：${errorText(state.error!)}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
    );
  }

  Future<void> _editLogFrequency() async {
    final text = await showTextInputDialog(
      context,
      title: '日志删除频率',
      labelText: '天数',
      initialValue:
          ref.read(systemInfoProvider).info?.logRemoveFrequency?.toString() ??
              '7',
      keyboardType: TextInputType.number,
      confirmText: '保存',
    );
    final days = int.tryParse(text?.trim() ?? '');
    if (days == null || !mounted) return;
    try {
      await ref.read(systemInfoProvider.notifier).setLogRemoveFrequency(days);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：${errorText(e)}')),
        );
      }
    }
  }

  Future<void> _checkUpdate() async {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) return;
    try {
      final result = await SystemApi.checkUpdate(apiBaseUrl: panel.apiBaseUrl);
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('检测更新'),
          content: Text(result?.toString() ?? '检查完成'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检测失败：${errorText(e)}')),
        );
      }
    }
  }

  Future<void> _updatePanel() async {
    final ok = await showConfirmDialog(
      context,
      title: '更新面板',
      message: '更新青龙面板？面板可能重启，请谨慎操作。',
      confirmText: '更新',
      destructive: true,
    );
    if (!ok) return;
    final panel = ref.read(currentPanelProvider);
    if (panel == null) return;
    try {
      final result = await SystemApi.update(apiBaseUrl: panel.apiBaseUrl);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新指令已发送：${result ?? ''}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失败：${errorText(e)}')),
        );
      }
    }
  }
}
