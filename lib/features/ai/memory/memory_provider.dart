import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/logger.dart';
import 'memory_models.dart';

class MemoryState {
  const MemoryState({this.items = const [], this.loaded = false});

  final List<AiMemory> items;
  final bool loaded;

  MemoryState copyWith({List<AiMemory>? items, bool? loaded}) =>
      MemoryState(items: items ?? this.items, loaded: loaded ?? this.loaded);
}

/// AI 长期记忆库。
///
/// 为什么不是"把整段历史存起来"：历史越长越贵、越噪。这里存的是**结论**——
/// 模型自己决定什么值得记（memory_write），下一次对话时只把置顶 + 与当前
/// 问题相关的若干条注入系统提示，其余按需用 memory_search 捞。
///
/// 落盘用 SharedPreferences：条数量级在几百，JSON 一把梭比上 drift 划算。
class MemoryNotifier extends Notifier<MemoryState> {
  static const _key = 'ai_memories_v1';

  /// 每轮自动注入的上限，避免记忆本身吃掉上下文。
  static const promptLimit = 24;

  /// 总条数上限；超了淘汰"不置顶 + 重要度最低 + 最久没命中"的。
  static const capacity = 400;

  @override
  MemoryState build() {
    Future.microtask(load);
    return const MemoryState();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key) ?? '';
      state = MemoryState(items: AiMemory.decodeList(raw), loaded: true);
    } catch (e) {
      Logger.e('memory', 'load failed', e);
      state = const MemoryState(loaded: true);
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, AiMemory.encodeList(state.items));
    } catch (e) {
      Logger.e('memory', 'persist failed', e);
    }
  }

  // ------------------------------------------------------------ 增删改

  /// 写入一条记忆。内容高度相似的旧条目会被覆盖而不是堆积。
  Future<AiMemory> write({
    required String content,
    MemoryKind kind = MemoryKind.fact,
    List<String> tags = const [],
    int importance = 3,
    bool pinned = false,
  }) async {
    final text = content.trim();
    final now = DateTime.now();
    final existing = _findSimilar(text);
    if (existing != null) {
      final updated = existing.copyWith(
        content: text,
        kind: kind,
        tags: tags.isEmpty ? existing.tags : tags,
        importance: importance,
        pinned: pinned || existing.pinned,
        updatedAt: now,
      );
      state = state.copyWith(
        items: [
          for (final m in state.items)
            if (m.id == existing.id) updated else m,
        ],
      );
      await _persist();
      return updated;
    }
    final memory = AiMemory(
      id: now.microsecondsSinceEpoch.toRadixString(36),
      content: text,
      kind: kind,
      tags: tags,
      importance: importance.clamp(1, 5),
      pinned: pinned,
      createdAt: now,
      updatedAt: now,
    );
    final items = [...state.items, memory];
    state = state.copyWith(items: _evict(items));
    await _persist();
    return memory;
  }

  Future<bool> update(String id,
      {String? content,
      int? importance,
      bool? pinned,
      List<String>? tags}) async {
    final matched = state.items.where((m) => m.id == id);
    if (matched.isEmpty) return false;
    state = state.copyWith(
      items: [
        for (final m in state.items)
          if (m.id == id)
            m.copyWith(
              content: content,
              importance: importance,
              pinned: pinned,
              tags: tags,
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

  // ------------------------------------------------------------ 检索

  /// 关键词检索。分词后按命中词数 + 重要度 + 命中次数排序。
  List<AiMemory> search(String query, {int limit = 10}) {
    final words = _tokens(query);
    if (words.isEmpty) {
      final sorted = [...state.items]..sort(_byPriority);
      return sorted.take(limit).toList();
    }
    final scored = <(AiMemory, int)>[];
    for (final m in state.items) {
      final haystack = '${m.content} ${m.tags.join(' ')}'.toLowerCase();
      var score = 0;
      for (final w in words) {
        if (haystack.contains(w)) score += w.length >= 2 ? 2 : 1;
      }
      if (score == 0) continue;
      scored
          .add((m, score * 10 + m.importance * 2 + (m.hits > 5 ? 3 : m.hits)));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final s in scored.take(limit)) s.$1];
  }

  /// 注入系统提示的记忆块：置顶全给 + 与本轮输入相关的若干条。
  ///
  /// 只读，不改 hits——注入发生在每一轮，计数会失去意义。
  String promptBlock(String userInput) {
    if (state.items.isEmpty) return '';
    final pinned = state.items.where((m) => m.pinned).toList()
      ..sort(_byPriority);
    final related =
        search(userInput, limit: promptLimit).where((m) => !m.pinned).toList();
    final picked = <AiMemory>[
      ...pinned,
      ...related,
    ].take(promptLimit).toList();
    if (picked.isEmpty) return '';

    final grouped = <MemoryKind, List<AiMemory>>{};
    for (final m in picked) {
      grouped.putIfAbsent(m.kind, () => []).add(m);
    }
    final lines = <String>[
      '## 你的长期记忆（共 ${state.items.length} 条，本轮注入 ${picked.length} 条）',
      '这些是你之前主动记下的结论。它们是既有认知，不需要重新确认；'
          '若发现记忆与现实不符，用 memory_write 覆盖或 memory_delete 删掉，别将错就错。',
    ];
    for (final kind in MemoryKind.values) {
      final list = grouped[kind];
      if (list == null || list.isEmpty) continue;
      lines.add('### ${kind.label}');
      for (final m in list) {
        lines.add(m.toPromptLine());
      }
    }
    if (state.items.length > picked.length) {
      lines.add(
        '（还有 ${state.items.length - picked.length} 条未注入，'
        '需要时用 memory_search 检索。）',
      );
    }
    return lines.join('\n');
  }

  /// 命中计数 +1（memory_search 工具调用时才计）。
  Future<void> markHits(Iterable<String> ids) async {
    final idSet = ids.toSet();
    if (idSet.isEmpty) return;
    state = state.copyWith(
      items: [
        for (final m in state.items)
          if (idSet.contains(m.id)) m.copyWith(hits: m.hits + 1) else m,
      ],
    );
    await _persist();
  }

  // ------------------------------------------------------------ 内部

  /// 同一句话反复记会把上下文塞满，这里做一次粗粒度去重：
  /// 分词重合度 ≥ 0.8 就当同一条。
  AiMemory? _findSimilar(String text) {
    final a = _tokens(text).toSet();
    if (a.isEmpty) return null;
    for (final m in state.items) {
      final b = _tokens(m.content).toSet();
      if (b.isEmpty) continue;
      final overlap = a.intersection(b).length;
      final ratio = overlap / (a.length > b.length ? a.length : b.length);
      if (ratio >= 0.8) return m;
    }
    return null;
  }

  List<AiMemory> _evict(List<AiMemory> items) {
    if (items.length <= capacity) return items;
    final removable = items.where((m) => !m.pinned).toList()
      ..sort((a, b) {
        final byImportance = a.importance.compareTo(b.importance);
        if (byImportance != 0) return byImportance;
        final byHits = a.hits.compareTo(b.hits);
        if (byHits != 0) return byHits;
        return a.updatedAt.compareTo(b.updatedAt);
      });
    final drop =
        removable.take(items.length - capacity).map((m) => m.id).toSet();
    return items.where((m) => !drop.contains(m.id)).toList();
  }

  int _byPriority(AiMemory a, AiMemory b) {
    final byImportance = b.importance.compareTo(a.importance);
    if (byImportance != 0) return byImportance;
    return b.updatedAt.compareTo(a.updatedAt);
  }

  /// 中英文混排的粗分词：英文按词，中文按二元切分。
  List<String> _tokens(String text) {
    final lower = text.toLowerCase();
    final out = <String>[];
    for (final match in RegExp(r'[a-z0-9_./-]{2,}').allMatches(lower)) {
      out.add(match.group(0)!);
    }
    final cjk = lower.replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '');
    for (var i = 0; i + 1 < cjk.length; i++) {
      out.add(cjk.substring(i, i + 2));
    }
    return out;
  }
}

final memoryProvider =
    NotifierProvider<MemoryNotifier, MemoryState>(MemoryNotifier.new);
