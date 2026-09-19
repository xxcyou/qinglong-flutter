import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../core/utils/formatter.dart';
import '../../../shared/glass_scaffold.dart';
import '../modes/mode_models.dart';
import '../modes/mode_provider.dart';

/// 模式库：用户自己定义的“编辑/回答模式”。
///
/// 每个模式 = 标签名 + 具体指令内容。在 AI 输入框打 `/` 会列出这些标签，
/// 选中后挂到输入区上方，发送时该模式内容会注入本次提示词。
class ModePage extends ConsumerStatefulWidget {
  const ModePage({super.key});

  @override
  ConsumerState<ModePage> createState() => _ModePageState();
}

class _ModePageState extends ConsumerState<ModePage> {
  final _searchController = TextEditingController();
  String _keyword = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(modeProvider);
    final notifier = ref.read(modeProvider.notifier);
    var items = [...state.items];
    if (_keyword.isNotEmpty) {
      final key = _keyword.toLowerCase();
      items = items
          .where((m) =>
              m.name.toLowerCase().contains(key) ||
              m.content.toLowerCase().contains(key))
          .toList();
    }
    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return GlassScaffold(
      title: '模式库',
      subtitle: '共 ${state.items.length} 个模式 · 输入框打 / 快速挂载',
      showBack: true,
      actions: [
        IconButton(
          tooltip: '新建模式',
          onPressed: () => _edit(null),
          icon: const Icon(Icons.add),
        ),
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (value) async {
            if (value != 'clear') return;
            final ok = await _confirm('清空全部模式？', '所有自定义模式都会被删除，不可撤销。');
            if (ok) await notifier.clearAll();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'clear', child: Text('清空全部')),
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
                    hintText: '搜索模式标签或内容',
                  ),
                  onChanged: (v) => setState(() => _keyword = v.trim()),
                ),
              ),
            ],
          ),
        ),
      ),
      body: items.isEmpty
          ? _buildEmpty(state.items.isEmpty)
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
            const Icon(Icons.tune_outlined, size: 56),
            const SizedBox(height: 12),
            Text(
              totallyEmpty ? '还没有任何模式' : '没有匹配的模式',
              style: const TextStyle(fontSize: 15),
            ),
            if (totallyEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '新建一个模式后，在 AI 输入框打 / 就能看到它的标签。\n'
                '例如「规划模式」的内容可以是：分析问题、向用户提问、按步骤推进。',
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

  Widget _buildTile(AiMode mode, ModeNotifier notifier) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      onTap: () => _edit(mode),
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
                  '#${mode.name}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              if (!mode.enabled) ...[
                const SizedBox(width: 6),
                Text(
                  '已停用',
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: mode.enabled ? '停用（不在 / 列表显示）' : '启用',
                onPressed: () =>
                    notifier.update(mode.id, enabled: !mode.enabled),
                icon: Icon(
                  mode.enabled
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color:
                      mode.enabled ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '删除',
                onPressed: () async {
                  final ok =
                      await _confirm('删除模式「${mode.name}」？', mode.content);
                  if (ok) await notifier.remove(mode.id);
                },
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            mode.content,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, height: 1.35),
          ),
          const SizedBox(height: 6),
          Text(
            '更新 ${Formatter.dateTime(mode.updatedAt)}',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
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

  Future<void> _edit(AiMode? mode) async {
    final draft = await showModalBottomSheet<_ModeDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ModeEditSheet(mode: mode),
    );
    if (draft == null) return;
    final notifier = ref.read(modeProvider.notifier);
    if (mode == null) {
      await notifier.create(name: draft.name, content: draft.content);
    } else {
      await notifier.update(mode.id, name: draft.name, content: draft.content);
    }
  }
}

class _ModeDraft {
  const _ModeDraft({required this.name, required this.content});
  final String name;
  final String content;
}

class _ModeEditSheet extends StatefulWidget {
  const _ModeEditSheet({this.mode});
  final AiMode? mode;

  @override
  State<_ModeEditSheet> createState() => _ModeEditSheetState();
}

class _ModeEditSheetState extends State<_ModeEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _content;

  @override
  void initState() {
    super.initState();
    final mode = widget.mode;
    _name = TextEditingController(text: mode?.name ?? '');
    _content = TextEditingController(text: mode?.content ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final content = _content.text.trim();
    if (name.isEmpty || content.isEmpty) return;
    Navigator.of(context).pop(_ModeDraft(name: name, content: content));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.mode == null ? '新建模式' : '编辑模式',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '标签名',
              hintText: '例如：规划模式',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _content,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: '模式内容',
              hintText: 'AI 挂载这个模式后必须照做的具体步骤…',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
