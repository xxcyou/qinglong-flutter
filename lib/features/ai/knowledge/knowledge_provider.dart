import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/logger.dart';
import 'knowledge_models.dart';
import 'knowledge_store.dart';

class KnowledgeState {
  const KnowledgeState({
    this.docs = const [],
    this.loading = false,
    this.loaded = false,
    this.error,
  });

  final List<KnowledgeDoc> docs;
  final bool loading;
  final bool loaded;
  final String? error;

  KnowledgeState copyWith({
    List<KnowledgeDoc>? docs,
    bool? loading,
    bool? loaded,
    String? error,
    bool clearError = false,
  }) {
    return KnowledgeState(
      docs: docs ?? this.docs,
      loading: loading ?? this.loading,
      loaded: loaded ?? this.loaded,
      error: clearError ? null : error ?? this.error,
    );
  }
}

/// 知识库管理页的 UI 状态。
///
/// AI 侧不通过这个 provider，而是直接用 [KnowledgeStore]；两边读写同一个
/// /workspace/.knowledge，所以状态不会有两份真相。
class KnowledgeNotifier extends Notifier<KnowledgeState> {
  final KnowledgeStore _store = KnowledgeStore();

  @override
  KnowledgeState build() {
    Future.microtask(load);
    return const KnowledgeState();
  }

  Future<void> load() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final docs = await _store.list();
      state = KnowledgeState(docs: docs, loaded: true);
    } catch (e) {
      Logger.e('knowledge', 'load failed', e);
      state = state.copyWith(
        loading: false,
        loaded: true,
        error: '读取知识库失败：$e',
      );
    }
  }

  Future<KnowledgeDoc?> save({
    required String title,
    required String content,
    List<String> tags = const [],
    String? existingPath,
  }) async {
    try {
      final doc = await _store.write(
        title: title,
        content: content,
        tags: tags,
        existingPath: existingPath,
      );
      await load();
      return doc;
    } catch (e) {
      Logger.e('knowledge', 'save failed', e);
      state = state.copyWith(error: '保存知识失败：$e');
      return null;
    }
  }

  Future<bool> delete(String path) async {
    try {
      final ok = await _store.delete(path);
      if (ok) await load();
      return ok;
    } catch (e) {
      Logger.e('knowledge', 'delete failed', e);
      state = state.copyWith(error: '删除知识失败：$e');
      return false;
    }
  }
}

final knowledgeProvider =
    NotifierProvider<KnowledgeNotifier, KnowledgeState>(KnowledgeNotifier.new);

/// 给 AI 工具直接用的同一份 store。
final knowledgeStoreProvider = Provider<KnowledgeStore>((ref) => KnowledgeStore());
