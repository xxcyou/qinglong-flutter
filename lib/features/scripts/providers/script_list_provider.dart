import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panels/providers/panel_list_provider.dart';
import '../api/script_api.dart';
import '../models/script_node.dart';

class ScriptListState {
  const ScriptListState({
    this.roots = const [],
    this.search = '',
    this.isLoading = false,
    this.error,
  });

  final List<ScriptNode> roots;
  final String search;
  final bool isLoading;
  final Object? error;

  ScriptListState copyWith({
    List<ScriptNode>? roots,
    String? search,
    bool? isLoading,
    Object? error,
    bool clearError = false,
  }) {
    return ScriptListState(
      roots: roots ?? this.roots,
      search: search ?? this.search,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class ScriptListNotifier extends Notifier<ScriptListState> {
  @override
  ScriptListState build() {
    ref.listen(currentPanelProvider, (previous, next) {
      if (previous?.id != next?.id && next != null) {
        Future.microtask(load);
      }
    });
    return const ScriptListState();
  }

  String get _apiBaseUrl {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) {
      throw StateError('未选择面板');
    }
    return panel.apiBaseUrl;
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final roots = await ScriptApi.files(
        apiBaseUrl: _apiBaseUrl,
        searchValue: state.search,
      );
      state = state.copyWith(roots: roots, isLoading: false, clearError: true);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e);
    }
  }

  Future<void> refresh() => load();

  void setSearch(String value) {
    state = state.copyWith(search: value.trim());
    load();
  }

  Future<void> create(String path, String content) async {
    await ScriptApi.create(
        apiBaseUrl: _apiBaseUrl, path: path, content: content);
    await refresh();
  }

  Future<void> save(String path, String content) async {
    await ScriptApi.save(apiBaseUrl: _apiBaseUrl, path: path, content: content);
    await refresh();
  }

  Future<void> remove(String path, {bool isDirectory = false}) async {
    await ScriptApi.delete(
      apiBaseUrl: _apiBaseUrl,
      path: path,
      isDirectory: isDirectory,
    );
    await refresh();
  }

  Future<void> rename(String path, String newFilename) async {
    await ScriptApi.rename(
      apiBaseUrl: _apiBaseUrl,
      path: path,
      newFilename: newFilename,
    );
    await refresh();
  }

  Future<void> createDirectory(String parentPath, String directory) async {
    await ScriptApi.createDirectory(
      apiBaseUrl: _apiBaseUrl,
      path: parentPath,
      directory: directory,
    );
    await refresh();
  }
}

final scriptListProvider =
    NotifierProvider<ScriptListNotifier, ScriptListState>(
        ScriptListNotifier.new);
