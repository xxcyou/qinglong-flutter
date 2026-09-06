import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/error_text.dart';
import '../../../shared/empty_view.dart';
import '../../../shared/error_view.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/loading_view.dart';
import '../../../shared/search_field.dart';
import '../models/log_item.dart';
import '../providers/log_list_provider.dart';
import 'log_view_page.dart';

class LogCenterPage extends ConsumerStatefulWidget {
  const LogCenterPage({super.key});

  @override
  ConsumerState<LogCenterPage> createState() => _LogCenterPageState();
}

class _LogCenterPageState extends ConsumerState<LogCenterPage> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(logListProvider.notifier).load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(logListProvider);
    return GlassScaffold(
      title: '日志中心',
      headerInline: SearchField(
        controller: _searchController,
        hintText: '搜索日志文件',
        onChanged: ref.read(logListProvider.notifier).setSearch,
      ),
      body: _buildBody(state),
    );
  }

  Widget _buildBody(LogListState state) {
    if (state.isLoading && state.items.isEmpty) return const LoadingView();
    if (state.error != null && state.items.isEmpty) {
      return ErrorView(
        message: errorText(state.error!),
        onRetry: ref.read(logListProvider.notifier).refresh,
      );
    }
    if (state.items.isEmpty) {
      return EmptyView(
        message: state.search.isNotEmpty ? '没有匹配的日志' : '暂无日志',
        icon: Icons.receipt_long_outlined,
      );
    }
    // 一级菜单：脚本日志目录；二级菜单：该目录下的日志文件。
    final grouped = <String, List<LogItem>>{};
    for (final item in state.items) {
      final dir = item.dir.isEmpty ? '根目录' : item.dir;
      grouped.putIfAbsent(dir, () => []).add(item);
    }
    final dirs = grouped.keys.toList()..sort((a, b) => a.compareTo(b));

    return RefreshIndicator(
      onRefresh: ref.read(logListProvider.notifier).refresh,
      child: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 96),
        children: [
          for (final dir in dirs)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassCard(
                padding: EdgeInsets.zero,
                child: Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                  ),
                  child: ExpansionTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(dir),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                    childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    children: [
                      for (final item in grouped[dir]!)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _buildLogFileCard(item),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLogFileCard(LogItem item) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LogViewPage(
            file: item.file,
            dir: item.dir,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.article_outlined,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.file,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  item.dir.isEmpty ? '根目录' : item.dir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right, size: 20, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}
