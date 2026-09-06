import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../scripts/models/script_node.dart';
import '../../scripts/providers/script_list_provider.dart';
import '../../../shared/mono_text.dart';

/// 脚本选择器：把面板脚本目录树拍平成可搜索的列表，点一下就填进命令积木。
///
/// 「输入脚本可以选择脚本」——不用手打路径，也就不会因为拼错路径跑空任务。
class ScriptPickerSheet extends ConsumerStatefulWidget {
  const ScriptPickerSheet({super.key});

  /// 返回选中的脚本相对路径（如 `jd/jd_bean.js`），取消则为 null。
  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ScriptPickerSheet(),
    );
  }

  @override
  ConsumerState<ScriptPickerSheet> createState() => _ScriptPickerSheetState();
}

class _ScriptPickerSheetState extends ConsumerState<ScriptPickerSheet> {
  final _searchController = TextEditingController();
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    // 脚本树可能还没加载过（用户直接进的定时页），这里主动拉一次。
    Future.microtask(() {
      final state = ref.read(scriptListProvider);
      if (state.roots.isEmpty && !state.isLoading) {
        ref.read(scriptListProvider.notifier).load();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 深度优先拍平所有叶子节点，路径用 key（后端给的相对路径）。
  List<_Entry> _flatten(List<ScriptNode> nodes, String prefix) {
    final out = <_Entry>[];
    for (final node in nodes) {
      final path =
          node.key ?? (prefix.isEmpty ? node.title : '$prefix/${node.title}');
      if (node.isLeaf) {
        out.add(_Entry(name: node.title, path: path, size: node.size));
      } else {
        out.addAll(_flatten(node.children, path));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scriptListProvider);
    final all = _flatten(state.roots, '');
    final lower = _keyword.toLowerCase();
    final entries = lower.isEmpty
        ? all
        : all.where((e) => e.path.toLowerCase().contains(lower)).toList();
    entries.sort((a, b) => a.path.compareTo(b.path));

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.94,
      builder: (context, controller) => SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '选择脚本',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (state.isLoading)
                    const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: () =>
                        ref.read(scriptListProvider.notifier).refresh(),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 20),
                  hintText: '搜索脚本名或目录',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _keyword = v.trim()),
              ),
            ),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        state.isLoading
                            ? '正在加载脚本列表…'
                            : state.error != null
                                ? '脚本列表加载失败，点右上刷新重试'
                                : '没有匹配的脚本',
                      ),
                    )
                  : ListView.builder(
                      controller: controller,
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final e = entries[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.description_outlined),
                          title: Text(e.name),
                          subtitle: Text(
                            e.path,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: kMonoFamily,
                              fontFamilyFallback: kMonoFallback,
                            ),
                          ),
                          onTap: () => Navigator.of(context).pop(e.path),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Entry {
  const _Entry({required this.name, required this.path, this.size});

  final String name;
  final String path;
  final int? size;
}
