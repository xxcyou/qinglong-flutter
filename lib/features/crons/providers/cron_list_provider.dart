import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panels/providers/panel_list_provider.dart';
import '../api/cron_api.dart';
import '../models/cron_task.dart';

enum CronFilter {
  all('全部'),
  enabled('已启用'),
  disabled('已禁用'),
  running('运行中');

  const CronFilter(this.label);
  final String label;
}

class CronListState {
  const CronListState({
    this.items = const [],
    this.total = 0,
    this.page = 1,
    this.pageSize = 20,
    this.search = '',
    this.filter = CronFilter.all,
    this.isLoading = false,
    this.isRefreshing = false,
    this.isLoadingMore = false,
    this.error,
  });

  final List<CronTask> items;
  final int total;
  final int page;
  final int pageSize;
  final String search;
  final CronFilter filter;
  final bool isLoading;
  final bool isRefreshing;
  final bool isLoadingMore;
  final Object? error;

  bool get hasMore => items.length < total;

  CronListState copyWith({
    List<CronTask>? items,
    int? total,
    int? page,
    int? pageSize,
    String? search,
    CronFilter? filter,
    bool? isLoading,
    bool? isRefreshing,
    bool? isLoadingMore,
    Object? error,
    bool clearError = false,
  }) {
    return CronListState(
      items: items ?? this.items,
      total: total ?? this.total,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
      search: search ?? this.search,
      filter: filter ?? this.filter,
      isLoading: isLoading ?? this.isLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class CronListNotifier extends Notifier<CronListState> {
  @override
  CronListState build() {
    ref.listen(currentPanelProvider, (previous, next) {
      if (previous?.id != next?.id && next != null) {
        Future.microtask(loadFirst);
      }
    });
    return const CronListState();
  }

  String get _apiBaseUrl {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) {
      throw const ApiExceptionNoCurrent();
    }
    return panel.apiBaseUrl;
  }

  Future<void> loadFirst({bool force = false}) async {
    if (state.isLoading && !force) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await CronApi.list(
        apiBaseUrl: _apiBaseUrl,
        searchValue: state.search,
        page: 1,
        pageSize: state.pageSize,
      );
      state = state.copyWith(
        items: result.items,
        total: result.total,
        page: 1,
        isLoading: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e);
    }
  }

  Future<void> refresh() async {
    state = state.copyWith(isRefreshing: true, error: null);
    try {
      final result = await CronApi.list(
        apiBaseUrl: _apiBaseUrl,
        searchValue: state.search,
        page: 1,
        pageSize: state.pageSize,
      );
      state = state.copyWith(
        items: result.items,
        total: result.total,
        page: 1,
        isRefreshing: false,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(isRefreshing: false, error: e);
    }
  }

  Future<void> loadMore() async {
    if (!state.hasMore || state.isLoadingMore || state.isLoading) return;
    state = state.copyWith(isLoadingMore: true);
    try {
      final nextPage = state.page + 1;
      final result = await CronApi.list(
        apiBaseUrl: _apiBaseUrl,
        searchValue: state.search,
        page: nextPage,
        pageSize: state.pageSize,
      );
      final seen = <int>{};
      final merged = <CronTask>[];
      for (final item in [...state.items, ...result.items]) {
        if (item.id != null && !seen.add(item.id!)) continue;
        merged.add(item);
      }
      merged.sort((a, b) => (a.id ?? 0).compareTo(b.id ?? 0));
      state = state.copyWith(
        items: merged,
        total: result.total,
        page: nextPage,
        isLoadingMore: false,
      );
    } catch (e) {
      state = state.copyWith(isLoadingMore: false, error: e);
    }
  }

  void setSearch(String value) {
    if (state.search == value.trim()) return;
    state = state.copyWith(search: value.trim(), items: const [], page: 1);
    loadFirst();
  }

  void setFilter(CronFilter filter) {
    if (state.filter == filter) return;
    state = state.copyWith(filter: filter, items: const [], page: 1);
    loadFirst();
  }

  Future<void> create(CronTask task) async {
    await CronApi.create(apiBaseUrl: _apiBaseUrl, task: task);
    await loadFirst(force: true);
  }

  Future<void> update(CronTask task) async {
    await CronApi.update(apiBaseUrl: _apiBaseUrl, task: task);
    await loadFirst(force: true);
  }

  Future<void> run(List<int> ids) async {
    await CronApi.run(apiBaseUrl: _apiBaseUrl, ids: ids);
    await refresh();
  }

  Future<void> stop(List<int> ids) async {
    await CronApi.stop(apiBaseUrl: _apiBaseUrl, ids: ids);
    await refresh();
  }

  Future<void> setEnabled(List<int> ids, bool enabled) async {
    await CronApi.setEnabled(
        apiBaseUrl: _apiBaseUrl, ids: ids, enabled: enabled);
    await refresh();
  }

  Future<void> setPinned(List<int> ids, bool pinned) async {
    await CronApi.setPinned(apiBaseUrl: _apiBaseUrl, ids: ids, pinned: pinned);
    await refresh();
  }

  Future<void> delete(List<int> ids) async {
    await CronApi.delete(apiBaseUrl: _apiBaseUrl, ids: ids);
    await refresh();
  }
}

final cronListProvider =
    NotifierProvider<CronListNotifier, CronListState>(CronListNotifier.new);

class ApiExceptionNoCurrent implements Exception {
  const ApiExceptionNoCurrent();

  @override
  String toString() => '未选择面板，请先添加并切换到面板';
}
