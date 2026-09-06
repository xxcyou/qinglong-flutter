import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panels/providers/panel_list_provider.dart';
import '../api/dependency_api.dart';
import '../models/dependency.dart';

class DependencyListState {
  const DependencyListState({
    this.type = 0,
    this.items = const [],
    this.isLoading = false,
    this.error,
  });

  final int type;
  final List<Dependency> items;
  final bool isLoading;
  final Object? error;

  DependencyListState copyWith({
    int? type,
    List<Dependency>? items,
    bool? isLoading,
    Object? error,
    bool clearError = false,
  }) {
    return DependencyListState(
      type: type ?? this.type,
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class DependencyListNotifier extends Notifier<DependencyListState> {
  @override
  DependencyListState build() {
    ref.listen(currentPanelProvider, (previous, next) {
      if (previous?.id != next?.id && next != null) {
        Future.microtask(load);
      }
    });
    return const DependencyListState();
  }

  String get _apiBaseUrl {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) throw StateError('未选择面板');
    return panel.apiBaseUrl;
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final items = await DependencyApi.list(
        apiBaseUrl: _apiBaseUrl,
        type: state.type,
      );
      state = state.copyWith(items: items, isLoading: false, clearError: true);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e);
    }
  }

  Future<void> refresh() => load();

  void setType(int type) {
    if (state.type == type) return;
    state = state.copyWith(type: type, items: const []);
    load();
  }

  Future<void> install(List<String> names) async {
    await DependencyApi.install(
      apiBaseUrl: _apiBaseUrl,
      type: state.type,
      names: names,
    );
    await refresh();
  }

  Future<void> remove(List<int> ids) async {
    await DependencyApi.remove(apiBaseUrl: _apiBaseUrl, ids: ids);
    await refresh();
  }

  Future<void> reinstall(List<int> ids) async {
    await DependencyApi.reinstall(apiBaseUrl: _apiBaseUrl, ids: ids);
    await refresh();
  }
}

final dependencyListProvider =
    NotifierProvider<DependencyListNotifier, DependencyListState>(
  DependencyListNotifier.new,
);
