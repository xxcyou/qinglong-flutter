import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/formatter.dart';
import '../../../shared/glass_scaffold.dart';
import '../memory/memory_models.dart';
import '../memory/memory_provider.dart';

/// AI 记忆库：看 AI 记了什么、改它、删它。
///
/// 记忆是 AI 自己写进去的，但决定权在用户——所以这一页必须能删、能改重要度、
/// 能置顶。否则一条记错的"事实"会一直污染后面所有对话。
class MemoryPage extends ConsumerStatefulWidget {
  const MemoryPage({super.key});

  @override
  ConsumerState<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends ConsumerState<MemoryPage> {
  final _searchController = TextEditingController();
  String _keyword = '';
  MemoryKind? _kindFilter;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(memoryProvider);
    final notifier = ref.read(memoryProvider.notifier);

    var items = [...state.items];
    if (_kindFilter != null) {
      items = items.where((m) => m.kind == _kindFilter).toList();
    }
    if (_keyword.isNotEmpty) {
      final key = _keyword.toLowerCase();
      items = items
          .where((m) =>
              m.content.toLowerCase().contains(key) ||
              m.tags.any((t) => t.toLowerCase().contains(key)))
          .toList();
    }
    // 置顶优先，其次重要度，再按更新时间。
    items.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final byImportance = b.importance.compareTo(a.importance);
      if (byImportance != 0) return byImportance;
      return b.updatedAt.compareTo(a.updatedAt);
    });

    return GlassScaffold(
      title: 'AI 记忆',
      subtitle: '共 ${state.items.length} 条 · 显示 ${items.length} 条',
      showBack: true,
      actions: [
        IconButton(
          tooltip: '手动添加',
          onPressed: () => _edit(null),
          icon: const Icon(Icons.add),
        ),
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (value) async {
            if (value != 'clear') return;
            final ok = await _confirm('清空全部记忆？', 'AI 会忘掉所有长期结论，不可撤销。');
            if (ok) await notifier.clearAll();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'clear', child: Text('清空全部')),
          ],
        ),
      ],
      headerBottom: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Column(
          children: [
            GlassPanel(
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
                        hintText: '搜索记忆内容或标签',
                      ),
                      onChanged: (v) => setState(() => _keyword = v.trim()),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: _kindFilter == null,
                    onSelected: (_) => setState(() => _kindFilter = null),
                  ),
                  for (final kind in MemoryKind.values)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ChoiceChip(
                        label: Text(kind.label),
                        selected: _kindFilter == kind,
                        onSelected: (_) => setState(() => _kindFilter = kind),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: items.isEmpty
          ? _buildEmpty(state.items.isEmpty)
          // separated 而不是 builder：GlassCard 自己不带外边距，
          // builder 会让卡片一张贴一张（记忆一多就是一整块连体），
          // 边框叠在一起看不出这是几条。别的列表页都是 8 像素间距。
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 54),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) =>
                  _buildTile(items[index], notifier),
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
            const Icon(Icons.psychology_outlined, size: 56),
            const SizedBox(height: 12),
            Text(
              totallyEmpty ? 'AI 还没记住任何东西' : '没有匹配的记忆',
              style: const TextStyle(fontSize: 15),
            ),
            if (totallyEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '和 AI 聊天时，它会把值得长期记住的结论\n'
                '（你的偏好、面板事实、踩过的坑）自己写进来。\n'
                '你也可以点右上角手动加一条。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTile(AiMemory m, MemoryNotifier notifier) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      onTap: () => _edit(m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  m.kind.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '重要度 ${m.importance}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: m.pinned ? '取消置顶' : '置顶（每轮必注入）',
                onPressed: () => notifier.update(m.id, pinned: !m.pinned),
                icon: Icon(
                  m.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 18,
                  color: m.pinned ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '删除',
                onPressed: () async {
                  final ok = await _confirm('删除这条记忆？', m.content);
                  if (ok) await notifier.remove(m.id);
                },
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(m.content, style: const TextStyle(fontSize: 14, height: 1.35)),
          const SizedBox(height: 6),
          Row(
            children: [
              if (m.tags.isNotEmpty)
                Expanded(
                  child: Text(
                    m.tags.map((t) => '#$t').join(' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: scheme.primary),
                  ),
                )
              else
                const Spacer(),
              Text(
                '命中 ${m.hits} · ${Formatter.dateTime(m.updatedAt)}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String detail) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(detail, maxLines: 6, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return result == true;
  }

  /// 新增/编辑一条记忆。传 null 表示新增。
  Future<void> _edit(AiMemory? memory) async {
    final controller = TextEditingController(text: memory?.content ?? '');
    final tagController =
        TextEditingController(text: memory?.tags.join(' ') ?? '');
    var kind = memory?.kind ?? MemoryKind.fact;
    var importance = memory?.importance ?? 3;
    var pinned = memory?.pinned ?? false;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                memory == null ? '添加记忆' : '编辑记忆',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '内容',
                  hintText: '一句话结论，例如：通知走 Bark，不要用邮件',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: tagController,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '标签（空格分隔）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final k in MemoryKind.values)
                    ChoiceChip(
                      label: Text(k.label),
                      selected: kind == k,
                      onSelected: (_) => setSheetState(() => kind = k),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('重要度', style: TextStyle(fontSize: 13)),
                  Expanded(
                    child: Slider(
                      value: importance.toDouble(),
                      min: 1,
                      max: 5,
                      divisions: 4,
                      label: '$importance',
                      onChanged: (v) =>
                          setSheetState(() => importance = v.round()),
                    ),
                  ),
                  Text('$importance'),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: pinned,
                onChanged: (v) => setSheetState(() => pinned = v),
                title: const Text('置顶', style: TextStyle(fontSize: 14)),
                subtitle: const Text(
                  '每轮对话都注入，给真正的长期约束用',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    final content = controller.text.trim();
    controller.dispose();
    final tags = tagController.text
        .split(RegExp(r'\s+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    tagController.dispose();
    if (saved != true || content.isEmpty) return;

    final notifier = ref.read(memoryProvider.notifier);
    if (memory == null) {
      await notifier.write(
        content: content,
        kind: kind,
        tags: tags,
        importance: importance,
        pinned: pinned,
      );
    } else {
      await notifier.update(
        memory.id,
        content: content,
        importance: importance,
        pinned: pinned,
        tags: tags,
      );
    }
  }
}
