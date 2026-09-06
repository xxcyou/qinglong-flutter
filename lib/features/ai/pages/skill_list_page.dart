import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/confirm_dialog.dart';
import '../../../shared/glass_scaffold.dart';
import '../skills/skill_models.dart';
import '../skills/skill_provider.dart';
import '../../../shared/mono_text.dart';

/// 技能库：给 AI 装操作手册。
///
/// 系统提示里只放"名字 + 何时用"，AI 真正需要时才用 skill_read 读正文，
/// 所以装很多技能也不会把上下文撑爆。
class SkillListPage extends ConsumerWidget {
  const SkillListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(skillProvider);
    final notifier = ref.read(skillProvider.notifier);
    final builtin = state.skills.where((s) => s.builtin).toList();
    final custom = state.skills.where((s) => !s.builtin).toList();

    return GlassScaffold(
      title: '技能库',
      subtitle: '${state.enabled.length}/${state.skills.length} 个已启用',
      actions: [
        IconButton(
          tooltip: '新建技能',
          onPressed: () => _edit(context, ref, null),
          icon: const Icon(Icons.add, size: 22),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 54),
        children: [
          GlassCard(
            child: Row(
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '技能是给 AI 看的操作手册：写清"什么时候用"和"怎么做"，'
                    'AI 遇到对应场景会自己读它再动手，比每次都重复交代靠谱。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (custom.isNotEmpty) ...[
            const SectionLabel('我的技能'),
            for (final s in custom)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _SkillCard(
                  skill: s,
                  onToggle: (v) => notifier.setEnabled(s.id, v),
                  onTap: () => _edit(context, ref, s),
                  onDelete: () async {
                    final ok = await showConfirmDialog(
                      context,
                      title: '删除技能',
                      message: '删除「${s.name}」后 AI 不再拥有这份手册。',
                      confirmText: '删除',
                      destructive: true,
                    );
                    if (ok) await notifier.remove(s.id);
                  },
                ),
              ),
          ],
          const SectionLabel('内置技能'),
          for (final s in builtin)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SkillCard(
                skill: s,
                onToggle: (v) => notifier.setEnabled(s.id, v),
                onTap: () => _view(context, s),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, AiSkill? skill) async {
    final result = await Navigator.of(context).push<AiSkill>(
      MaterialPageRoute(builder: (_) => _SkillEditPage(skill: skill)),
    );
    if (result != null) {
      await ref.read(skillProvider.notifier).upsert(result);
    }
  }

  void _view(BuildContext context, AiSkill skill) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GlassScaffold(
          title: skill.name,
          subtitle: '内置技能（只读）',
          showBack: true,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 54),
            children: [
              if (skill.whenToUse.isNotEmpty) ...[
                const SectionLabel('何时使用'),
                Text(skill.whenToUse, style: const TextStyle(fontSize: 13)),
              ],
              const SectionLabel('手册正文'),
              SelectableText(
                skill.instructions.trim(),
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkillCard extends StatelessWidget {
  const _SkillCard({
    required this.skill,
    required this.onToggle,
    required this.onTap,
    this.onDelete,
  });

  final AiSkill skill;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                skill.enabled
                    ? Icons.auto_stories
                    : Icons.auto_stories_outlined,
                size: 18,
                color: skill.enabled ? scheme.primary : scheme.outline,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  skill.name,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    fontFamily: kMonoFamily,
                    fontFamilyFallback: kMonoFallback,
                  ),
                ),
              ),
              Switch(
                value: skill.enabled,
                onChanged: onToggle,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              if (onDelete != null)
                IconButton(
                  tooltip: '删除',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                  icon:
                      Icon(Icons.delete_outline, size: 18, color: scheme.error),
                )
              else
                const SizedBox(width: 8),
            ],
          ),
          Text(skill.description, style: const TextStyle(fontSize: 12.5)),
          if (skill.whenToUse.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '何时用：${skill.whenToUse}',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _SkillEditPage extends StatefulWidget {
  const _SkillEditPage({this.skill});

  final AiSkill? skill;

  @override
  State<_SkillEditPage> createState() => _SkillEditPageState();
}

class _SkillEditPageState extends State<_SkillEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _when;
  late final TextEditingController _body;

  @override
  void initState() {
    super.initState();
    final s = widget.skill;
    _name = TextEditingController(text: s?.name ?? '');
    _desc = TextEditingController(text: s?.description ?? '');
    _when = TextEditingController(text: s?.whenToUse ?? '');
    _body = TextEditingController(text: s?.instructions ?? _template);
  }

  static const _template = '''
# 步骤
1.
2.

# 注意
-
''';

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _when.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      title: widget.skill == null ? '新建技能' : '编辑技能',
      showBack: true,
      actions: [
        IconButton(
          tooltip: '保存',
          onPressed: () {
            if (_formKey.currentState?.validate() != true) return;
            Navigator.of(context).pop(
              AiSkill(
                id: widget.skill?.id ??
                    DateTime.now().microsecondsSinceEpoch.toString(),
                name: _name.text.trim(),
                description: _desc.text.trim(),
                whenToUse: _when.text.trim(),
                instructions: _body.text,
                enabled: widget.skill?.enabled ?? true,
              ),
            );
          },
          icon: const Icon(Icons.check, size: 22),
        ),
      ],
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 54),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '技能名',
                hintText: '英文短横线命名，例如 jd-sign',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请填技能名' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _desc,
              decoration: const InputDecoration(
                labelText: '一句话说明',
                hintText: '这个技能能干什么',
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? '请填说明' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _when,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '何时使用',
                hintText: '写清触发场景，AI 靠它判断要不要加载',
              ),
            ),
            const SectionLabel('手册正文（Markdown）'),
            TextFormField(
              controller: _body,
              maxLines: 20,
              minLines: 10,
              style: const TextStyle(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                  fontSize: 12.5),
              decoration: const InputDecoration(
                alignLabelWithHint: true,
                hintText: '步骤、命令模板、注意事项…',
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? '请填正文' : null,
            ),
          ],
        ),
      ),
    );
  }
}
