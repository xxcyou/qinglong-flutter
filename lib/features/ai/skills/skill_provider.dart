import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/logger.dart';
import 'skill_models.dart';

class SkillState {
  const SkillState({this.skills = const [], this.loaded = false});

  final List<AiSkill> skills;
  final bool loaded;

  List<AiSkill> get enabled => skills.where((s) => s.enabled).toList();

  SkillState copyWith({List<AiSkill>? skills, bool? loaded}) =>
      SkillState(skills: skills ?? this.skills, loaded: loaded ?? this.loaded);
}

class SkillNotifier extends Notifier<SkillState> {
  static const _key = 'ai_skills_v1';

  @override
  SkillState build() {
    Future.microtask(load);
    return const SkillState();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key) ?? '';
      final saved = raw.isEmpty ? const <AiSkill>[] : AiSkill.decodeList(raw);
      // 内置技能以代码为准（可以随版本更新正文），只保留用户的启用开关。
      final savedById = {for (final s in saved) s.id: s};
      final merged = <AiSkill>[
        for (final b in builtinSkills)
          b.copyWith(enabled: savedById[b.id]?.enabled ?? true),
        ...saved.where((s) => !s.builtin),
      ];
      state = SkillState(skills: merged, loaded: true);
    } catch (e) {
      Logger.e('skill', 'load failed', e);
      state = const SkillState(skills: builtinSkills, loaded: true);
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, AiSkill.encodeList(state.skills));
    } catch (e) {
      Logger.e('skill', 'persist failed', e);
    }
  }

  Future<void> upsert(AiSkill skill) async {
    final list = [...state.skills];
    final index = list.indexWhere((s) => s.id == skill.id);
    if (index < 0) {
      list.add(skill);
    } else {
      list[index] = skill;
    }
    state = state.copyWith(skills: list);
    await _persist();
  }

  Future<void> remove(String id) async {
    final target = state.skills.where((s) => s.id == id);
    if (target.isNotEmpty && target.first.builtin) return;
    state = state.copyWith(
      skills: state.skills.where((s) => s.id != id).toList(),
    );
    await _persist();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    state = state.copyWith(
      skills: [
        for (final s in state.skills)
          if (s.id == id) s.copyWith(enabled: enabled) else s,
      ],
    );
    await _persist();
  }

  /// 注入系统提示的目录（只有名字与触发场景，正文按需读取）。
  String promptCatalog() {
    final list = state.enabled;
    if (list.isEmpty) return '';
    final lines = <String>[
      '## 可用技能（渐进加载）',
      '下面是为你准备的操作手册。看到匹配场景时，先用 skill_read(name) 把正文读出来再动手，别凭印象操作。',
    ];
    for (final s in list) {
      final when = s.whenToUse.isEmpty ? '' : '｜何时用：${s.whenToUse}';
      lines.add('- ${s.name}：${s.description}$when');
    }
    return lines.join('\n');
  }

  /// skill_read 工具的实现。
  String read(String name) {
    final key = name.trim().toLowerCase();
    final matched = state.enabled.where(
      (s) => s.name.toLowerCase() == key || s.id.toLowerCase() == key,
    );
    if (matched.isEmpty) {
      final names = state.enabled.map((s) => s.name).join('、');
      return '没有叫「$name」的技能。可用技能：${names.isEmpty ? '（无）' : names}';
    }
    final skill = matched.first;
    return '# 技能：${skill.name}\n${skill.description}\n\n${skill.instructions.trim()}';
  }
}

final skillProvider =
    NotifierProvider<SkillNotifier, SkillState>(SkillNotifier.new);
