import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../shared/glass_scaffold.dart';
import '../knowledge/knowledge_models.dart';
import '../knowledge/knowledge_provider.dart';

/// AI 知识库管理页。
///
/// 知识库存成 /workspace/.knowledge/*.md，文件管理器里直接可见。
/// 和记忆的区别：记忆会自动注入相关上下文，知识库**只按需调用**，
/// 主动 kb_search / kb_read 才看到内容。
class KnowledgePage extends ConsumerStatefulWidget {
  const KnowledgePage({super.key});

  @override
  ConsumerState<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends ConsumerState<KnowledgePage> {
  final _searchController = TextEditingController();
  String _keyword = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(knowledgeProvider);
    final notifier = ref.read(knowledgeProvider.notifier);

    var docs = state.docs;
    if (_keyword.isNotEmpty) {
      final key = _keyword.toLowerCase();
      docs = docs
          .where((d) =>
              d.title.toLowerCase().contains(key) ||
              d.content.toLowerCase().contains(key) ||
              d.tags.any((t) => t.toLowerCase().contains(key)))
          .toList();
    }

    return GlassScaffold(
      title: '知识库',
      subtitle: state.loading
          ? '读取中…'
          : '共 ${state.docs.length} 篇 · 显示 ${docs.length} 篇',
      showBack: true,
      actions: [
        IconButton(
          tooltip: '新建知识',
          onPressed: () => _edit(context, null, notifier),
          icon: const Icon(Icons.add),
        ),
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (value) async {
            if (value != 'refresh') return;
            await notifier.load();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'refresh', child: Text('刷新')),
          ],
        ),
      ],
      headerBottom: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: GlassPanel(
          radius: 18,
          blur: 14,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              const Icon(Icons.search, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    hintText: '搜索标题 / 标签 / 正文',
                  ),
                  onChanged: (v) => setState(() => _keyword = v.trim()),
                ),
              ),
            ],
          ),
        ),
      ),
      body: state.error != null
          ? Center(child: Text(state.error!))
          : state.loading && docs.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : docs.isEmpty
                  ? _buildEmpty(state.docs.isEmpty)
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 54),
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) => _buildTile(
                        context,
                        docs[index],
                        notifier,
                      ),
                    ),
    );
  }

  Widget _buildEmpty(bool totallyEmpty) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book_outlined, size: 56),
            const SizedBox(height: 12),
            Text(
              totallyEmpty ? '知识库还是空的' : '没有匹配的知识',
              style: const TextStyle(fontSize: 15),
            ),
            if (totallyEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'AI 遇到踩坑/可靠经验时会把方案记到这里，也可以手动新建。\n'
                '知识库不会自动塞进上下文，AI 检索后才会读。',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTile(
    BuildContext context,
    KnowledgeDoc doc,
    KnowledgeNotifier notifier,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return GlassPanel(
      radius: 18,
      blur: 16,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _edit(context, doc, notifier),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    doc.title,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  _formatTime(doc.updatedAt),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (doc.tags.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final tag in doc.tags.take(6))
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              doc.snippet,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    KnowledgeDoc? existing,
    KnowledgeNotifier notifier,
  ) async {
    final titleController = TextEditingController(text: existing?.title ?? '');
    final tagsController = TextEditingController(
      text: existing?.tags.join('、') ?? '',
    );
    final contentController =
        TextEditingController(text: existing?.content ?? '');

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: Container(
          height: MediaQuery.of(sheetContext).size.height * 0.82,
          decoration: BoxDecoration(
            color: Theme.of(sheetContext).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      existing == null ? '新建知识' : '编辑知识',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  labelText: '标题',
                  hintText: '一句话说清主题',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: tagsController,
                decoration: const InputDecoration(
                  labelText: '标签',
                  hintText: '用、或空格分隔，如：青龙、API、踩坑',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: TextField(
                  controller: contentController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    labelText: '正文',
                    hintText: '方案 / 步骤 / 代码 / 注意事项，写成以后能照着用的程度',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (existing != null) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final ok =
                              await _confirmDelete(sheetContext, existing);
                          if (!ok) return;
                          await notifier.delete(existing.path);
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('删除'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor:
                              Theme.of(sheetContext).colorScheme.error,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: () async {
                        final title = titleController.text.trim();
                        final content = contentController.text.trim();
                        if (title.isEmpty || content.isEmpty) {
                          ScaffoldMessenger.of(sheetContext).showSnackBar(
                            const SnackBar(content: Text('标题和正文不能为空')),
                          );
                          return;
                        }
                        final tags = tagsController.text
                            .split(RegExp(r'[、,，\s]+'))
                            .where((t) => t.trim().isNotEmpty)
                            .map((t) => t.trim())
                            .toList();
                        final ok = await notifier.save(
                          title: title,
                          content: content,
                          tags: tags,
                          existingPath: existing?.path,
                        );
                        if (ok != null && sheetContext.mounted) {
                          Navigator.pop(sheetContext);
                        }
                      },
                      icon: const Icon(Icons.save_outlined),
                      label: Text(existing == null ? '保存' : '保存修改'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context, KnowledgeDoc doc) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条知识？'),
        content: Text('「${doc.title}」删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    void pad(StringBuffer b, int v) => b.write(v.toString().padLeft(2, '0'));
    final b = StringBuffer()
      ..write('${local.year}-${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')} ');
    pad(b, local.hour);
    b.write(':');
    pad(b, local.minute);
    return b.toString();
  }
}
