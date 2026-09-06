import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panels/providers/panel_list_provider.dart';
import '../api/env_api.dart';
import '../models/env_var.dart';

enum EnvStatusFilter {
  all('全部'),
  enabled('已启用'),
  disabled('已禁用');

  const EnvStatusFilter(this.label);
  final String label;
}

class EnvListState {
  const EnvListState({
    this.items = const [],
    this.search = '',
    this.filter = EnvStatusFilter.all,
    this.isLoading = false,
    this.error,
  });

  final List<EnvVar> items;
  final String search;
  final EnvStatusFilter filter;
  final bool isLoading;
  final Object? error;

  EnvListState copyWith({
    List<EnvVar>? items,
    String? search,
    EnvStatusFilter? filter,
    bool? isLoading,
    Object? error,
    bool clearError = false,
  }) {
    return EnvListState(
      items: items ?? this.items,
      search: search ?? this.search,
      filter: filter ?? this.filter,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class EnvListNotifier extends Notifier<EnvListState> {
  @override
  EnvListState build() {
    ref.listen(currentPanelProvider, (previous, next) {
      if (previous?.id != next?.id && next != null) {
        Future.microtask(load);
      }
    });
    return const EnvListState();
  }

  String get _apiBaseUrl {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) throw StateError('未选择面板');
    return panel.apiBaseUrl;
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final items = await EnvApi.list(
        apiBaseUrl: _apiBaseUrl,
        searchValue: state.search,
      );
      state = state.copyWith(items: items, isLoading: false, clearError: true);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e);
    }
  }

  Future<void> refresh() => load();

  void setSearch(String value) {
    state = state.copyWith(search: value.trim());
    load();
  }

  void setFilter(EnvStatusFilter filter) {
    state = state.copyWith(filter: filter);
  }

  Future<void> create(EnvVar env) async {
    await EnvApi.create(apiBaseUrl: _apiBaseUrl, env: env);
    await refresh();
  }

  Future<void> update(EnvVar env) async {
    await EnvApi.update(apiBaseUrl: _apiBaseUrl, env: env);
    await refresh();
  }

  Future<void> delete(List<int> ids) async {
    await EnvApi.delete(apiBaseUrl: _apiBaseUrl, ids: ids);
    await refresh();
  }

  Future<void> setEnabled(List<int> ids, bool enabled) async {
    await EnvApi.setEnabled(
        apiBaseUrl: _apiBaseUrl, ids: ids, enabled: enabled);
    await refresh();
  }
}

final envListProvider =
    NotifierProvider<EnvListNotifier, EnvListState>(EnvListNotifier.new);
