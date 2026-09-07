import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/logger.dart';
import 'skill_importer.dart';
import 'skill_models.dart';

class SkillState {
  const SkillState({this.skills = const [], this.loaded = false});

  final List<AiSkill> skills;
  final bool loaded;

  List<AiSkill> get enabled => skills.where((s) => s.enabled).toList();

  List<String> get enabledNames => enabled.map((s) => s.name).toList();

  SkillState copyWith({List<AiSkill>? skills, bool? loaded}) =>
      SkillState(skills: skills ?? this.skills, loaded: loaded ?? this.loaded);
}

class SkillNotifier extends Notifier<SkillState> {
  static const _key = 'ai_skills_v1';

  /// 给工具报错/提示用的名字列表。
  List<String> get enabledNames => state.enabled.map((s) => s.name).toList();

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

  /// 从来源（GitHub 仓库 / URL）完整导入一个市面技能，含附属代码文件。
  /// 返回一段给人/AI 看的导入结果说明。
  Future<String> importFromSource(String source) async {
    try {
      final (skill, docUrl) = await SkillImporter.import(source);
      // 技能名冲突时自动追加后缀避免覆盖。
      var name = skill.name;
      if (state.skills.any((s) => s.name == name)) {
        name = '$name-${skill.id.split('-').last}';
      }
      await upsert(skill.copyWith(name: name));
      final fileCount = skill.files.length;
      final scriptCount = skill.files.where((f) => f.isScript).length;
      return '技能「${skill.name}」导入成功（来自 $docUrl）。'
          '共 $fileCount 个附件文件，其中 $scriptCount 个是脚本。'
          '正文与代码都已存好，AI 可用 skill_read 读取。'
          '${skill.license.isEmpty ? '' : ' 许可证：${skill.license}'}';
    } catch (e) {
      return '导入失败：${e is StateError ? e.message : e}';
    }
  }

  /// skill_read 的扩展版：读手册；path 给了就读某个附件文件内容。
  String read(String name, {String? path}) {
    final key = name.trim().toLowerCase();
    final matched = state.enabled.where(
      (s) => s.name.toLowerCase() == key || s.id.toLowerCase() == key,
    );
    if (matched.isEmpty) {
      final names = state.enabled.map((s) => s.name).join('、');
      return '没有叫「$name」的技能。可用技能：${names.isEmpty ? '（无）' : names}';
    }
    final skill = matched.first;
    if (path != null && path.isNotEmpty) {
      final p = path.trim();
      final file =
          skill.files.where((f) => f.path == p || f.path.endsWith('/$p'));
      if (file.isEmpty) {
        final avail = skill.files.isEmpty
            ? '（无附件文件）'
            : skill.files.map((f) => f.path).join('、');
        return '技能「${skill.name}」没有文件「$p」。该技能附件：$avail';
      }
      final f = file.first;
      if (f.binary) {
        return '技能「${skill.name}」文件 ${f.path} 是二进制附件'
            '（${f.content.length} 个 base64 字符）。'
            '用 skill_export(name, path) 把内容写到 /workspace/skills 下，'
            '再用 shell_archive_extract 解压或直接处理。';
      }
      return '技能「${skill.name}」文件 ${f.path}（${f.content.length} 字）：\n${f.content}';
    }
    var out =
        '# 技能：${skill.name}\n${skill.description}\n\n${skill.instructions.trim()}';
    if (skill.files.isNotEmpty) {
      out += '\n\n---\n### 附件文件\n'
          '共 ${skill.files.length} 个，需要时用 skill_read(name, path="...") 读取：\n'
          '${skill.files.map((f) => '- ${f.path}${f.isScript ? '（脚本）' : ''}').join('\n')}';
    }
    return out;
  }

  /// 某个技能里要运行的脚本条路径（供 skill_run 落盘后执行）。
  String? scriptPath(String name, String script) {
    final file = skillFile(name, script);
    return file?.path;
  }

  AiSkill? skillByName(String name) {
    final key = name.trim().toLowerCase();
    final matched = state.skills.where(
      (s) => s.name.toLowerCase() == key || s.id.toLowerCase() == key,
    );
    return matched.isEmpty ? null : matched.first;
  }

  SkillFile? skillFile(String name, String path) {
    final skill = skillByName(name);
    if (skill == null) return null;
    final p = path.trim();
    final files = skill.files.where(
      (f) => f.path == p || f.path.endsWith('/$p'),
    );
    return files.isEmpty ? null : files.first;
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
}

final skillProvider =
    NotifierProvider<SkillNotifier, SkillState>(SkillNotifier.new);
