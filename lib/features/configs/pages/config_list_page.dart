import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/error_text.dart';
import '../../../shared/empty_view.dart';
import '../../../shared/error_view.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/loading_view.dart';
import '../models/config_file.dart';
import '../providers/config_list_provider.dart';
import 'config_edit_page.dart';

class ConfigListPage extends ConsumerStatefulWidget {
  const ConfigListPage({super.key});

  @override
  ConsumerState<ConfigListPage> createState() => _ConfigListPageState();
}

class _ConfigListPageState extends ConsumerState<ConfigListPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(configListProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(configListProvider);
    return GlassScaffold(
      title: '配置管理',
      body: _buildBody(state),
    );
  }

  Widget _buildBody(ConfigListState state) {
    if (state.isLoading && state.items.isEmpty) return const LoadingView();
    if (state.error != null && state.items.isEmpty) {
      return ErrorView(
        message: errorText(state.error!),
        onRetry: ref.read(configListProvider.notifier).refresh,
      );
    }
    if (state.items.isEmpty) {
      return const EmptyView(
        message: '暂无配置文件',
        icon: Icons.settings_suggest_outlined,
      );
    }
    return RefreshIndicator(
      onRefresh: ref.read(configListProvider.notifier).refresh,
      child: ListView.separated(
        padding: const EdgeInsets.only(top: 4, bottom: 96),
        itemCount: state.items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final file = state.items[index];
          final sensitive = file.name == 'auth.json';
          final scheme = Theme.of(context).colorScheme;
          return GlassCard(
            onTap: () => _open(file),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  sensitive
                      ? Icons.lock_outline
                      : Icons.settings_applications_outlined,
                  size: 22,
                  color: sensitive ? scheme.tertiary : scheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sensitive ? '敏感文件，编辑需二次确认' : '配置文件',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _open(ConfigFile file) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ConfigEditPage(fileName: file.name)),
    );
    Future.microtask(() => ref.read(configListProvider.notifier).refresh());
  }
}
