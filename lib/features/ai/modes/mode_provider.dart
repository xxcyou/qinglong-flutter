import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/logger.dart';
import 'mode_models.dart';

class ModeState {
  const ModeState({this.items = const [], this.loaded = false});

  final List<AiMode> items;
  final bool loaded;

  ModeState copyWith({List<AiMode>? items, bool? loaded}) =>
      ModeState(items: items ?? this.items, loaded: loaded ?? this.loaded);
}

/// 模式库：用户定义的“编辑/回答模式”集合。
///
/// 它和记忆库、知识库同级，但用途不一样：记忆存结论，模式存“这次让 AI 怎么干活”。
/// 每个模式有一个标签名 + 一段具体指令内容；用户可以在输入框用 `/标签` 快速挂载，
/// 发送时这些模式内容会注入本次请求。
class ModeNotifier extends Notifier<ModeState> {
  static const _key = 'ai_modes_v1';

  @override
  ModeState build() {
    Future.microtask(load);
    return const ModeState();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key) ?? '';
      state = ModeState(items: AiMode.decodeList(raw), loaded: true);
    } catch (e) {
      Logger.e('mode', 'load failed', e);
      state = const ModeState(loaded: true);
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, AiMode.encodeList(state.items));
    } catch (e) {
      Logger.e('mode', 'persist failed', e);
    }
  }

  // ------------------------------------------------------------ 增删改

  Future<AiMode> create({
    required String name,
    required String content,
  }) async {
    final trimmedName = name.trim();
    final trimmedContent = content.trim();
    if (trimmedName.isEmpty || trimmedContent.isEmpty) {
      throw ArgumentError('模式名和内容都不能为空');
    }
    final now = DateTime.now();
    final mode = AiMode(
      id: now.microsecondsSinceEpoch.toRadixString(36),
      name: trimmedName,
      content: trimmedContent,
      createdAt: now,
      updatedAt: now,
    );
    state = state.copyWith(items: [...state.items, mode]);
    await _persist();
    return mode;
  }

  Future<bool> update(
    String id, {
    String? name,
    String? content,
    bool? enabled,
  }) async {
    final matched = state.items.where((m) => m.id == id);
    if (matched.isEmpty) return false;
    state = state.copyWith(
      items: [
        for (final m in state.items)
          if (m.id == id)
            m.copyWith(
              name: name?.trim().isNotEmpty == true ? name!.trim() : null,
              content:
                  content?.trim().isNotEmpty == true ? content!.trim() : null,
              enabled: enabled,
              updatedAt: DateTime.now(),
            )
          else
            m,
      ],
    );
    await _persist();
    return true;
  }

  Future<bool> remove(String id) async {
    final before = state.items.length;
    state =
        state.copyWith(items: state.items.where((m) => m.id != id).toList());
    if (state.items.length == before) return false;
    await _persist();
    return true;
  }

  Future<void> clearAll() async {
    state = state.copyWith(items: const []);
    await _persist();
  }

  // ------------------------------------------------------------ 检索/展示

  List<AiMode> list({bool onlyEnabled = true}) => [
        for (final m in state.items)
          if (!onlyEnabled || m.enabled) m,
      ];

  AiMode? byId(String id) {
    for (final m in state.items) {
      if (m.id == id) return m;
    }
    return null;
  }

  List<AiMode> search(String keyword) {
    final key = keyword.trim().toLowerCase();
    final modes = list();
    if (key.isEmpty) return modes;
    return [
      for (final m in modes)
        if (m.name.toLowerCase().contains(key) ||
            m.content.toLowerCase().contains(key))
          m,
    ];
  }

  /// 把选中的模式拼成一段提示词，按名字分组，重复标签去重。
  String promptBlock(List<String> modeIds) {
    final seen = <String>{};
    final picked = <AiMode>[];
    for (final id in modeIds) {
      final mode = byId(id);
      if (mode == null || !mode.enabled) continue;
      if (!seen.add(mode.id)) continue;
      picked.add(mode);
    }
    if (picked.isEmpty) return '';
    final lines = <String>[
      '## 本次编辑/回答模式（${picked.length} 个，必须严格照做）',
      for (final m in picked) '### 模式：${m.name}\n${m.content}',
    ];
    return lines.join('\n\n');
  }
}

final modeProvider =
    NotifierProvider<ModeNotifier, ModeState>(ModeNotifier.new);
