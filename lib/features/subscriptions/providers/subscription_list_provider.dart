import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crons/providers/cron_list_provider.dart' show ApiExceptionNoCurrent;
import '../../panels/providers/panel_list_provider.dart';
import '../api/subscription_api.dart';
import '../models/subscription.dart';

enum SubFilter {
  all('全部'),
  enabled('已启用'),
  disabled('已禁用'),
  running('运行中');

  const SubFilter(this.label);
  final String label;

  bool matches(Subscription s) => switch (this) {
        SubFilter.all => true,
        SubFilter.enabled => !s.isDisabled,
        SubFilter.disabled => s.isDisabled,
        SubFilter.running => s.isRunning,
      };
}

class SubListState {
  const SubListState({
    this.items = const [],
    this.search = '',
    this.filter = SubFilter.all,
    this.isLoading = false,
    this.isRefreshing = false,
    this.error,
  });

  final List<Subscription> items;
  final String search;
  final SubFilter filter;
  final bool isLoading;
  final bool isRefreshing;
  final Object? error;

  List<Subscription> get visible =>
      items.where(filter.matches).toList(growable: false);

  bool get anyRunning => items.any((s) => s.isRunning);

  SubListState copyWith({
    List<Subscription>? items,
    String? search,
    SubFilter? filter,
    bool? isLoading,
    bool? isRefreshing,
    Object? error,
    bool clearError = false,
  }) {
    return SubListState(
      items: items ?? this.items,
      search: search ?? this.search,
      filter: filter ?? this.filter,
      isLoading: isLoading ?? this.isLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class SubListNotifier extends Notifier<SubListState> {
  Timer? _poll;

  @override
  SubListState build() {
    ref.listen(currentPanelProvider, (previous, next) {
      if (previous?.id != next?.id && next != null) {
        Future.microtask(() => load(force: true));
      }
    });
    // 页面被回收时把轮询也停掉，否则切面板/退出后还在后台打接口。
    ref.onDispose(_stopPolling);
    return const SubListState();
  }

  String get _apiBaseUrl {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) throw const ApiExceptionNoCurrent();
    return panel.apiBaseUrl;
  }

  Future<void> load({bool force = false}) async {
    if (state.isLoading && !force) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final items = await SubscriptionApi.list(
        apiBaseUrl: _apiBaseUrl,
        searchValue: state.search,
      );
      state = state.copyWith(items: items, isLoading: false, clearError: true);
      _syncPolling();
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e);
      _stopPolling();
    }
  }

  Future<void> refresh() async {
    state = state.copyWith(isRefreshing: true);
    try {
      final items = await SubscriptionApi.list(
        apiBaseUrl: _apiBaseUrl,
        searchValue: state.search,
      );
      state =
          state.copyWith(items: items, isRefreshing: false, clearError: true);
      _syncPolling();
    } catch (e) {
      state = state.copyWith(isRefreshing: false, error: e);
    }
  }

  /// 有订阅在跑就每 3 秒刷一次，跑完自动停。
  ///
  /// 拉仓库动辄十几秒到几分钟，用户点了"运行"之后最想看到的就是状态自己
  /// 从"运行中"变回"空闲"。没有这个轮询就得手动下拉，体验上像是卡住了。
  void _syncPolling() {
    if (state.anyRunning) {
      _poll ??= Timer.periodic(const Duration(seconds: 3), (_) {
        if (!state.anyRunning) {
          _stopPolling();
          return;
        }
        refresh();
      });
    } else {
      _stopPolling();
    }
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  void setSearch(String value) {
    final next = value.trim();
    if (state.search == next) return;
    state = state.copyWith(search: next);
    load(force: true);
  }

  void setFilter(SubFilter filter) {
    if (state.filter == filter) return;
    state = state.copyWith(filter: filter);
  }

  Future<void> create(Subscription sub) async {
    await SubscriptionApi.create(apiBaseUrl: _apiBaseUrl, sub: sub);
    await load(force: true);
  }

  Future<void> update(Subscription sub) async {
    await SubscriptionApi.update(apiBaseUrl: _apiBaseUrl, sub: sub);
    await load(force: true);
  }

  Future<void> run(List<int> ids) async {
    await SubscriptionApi.run(apiBaseUrl: _apiBaseUrl, ids: ids);
    await refresh();
    // 运行是异步的：面板先把状态改成 running 再慢慢拉，
    // 所以这里必须把轮询点起来，不能只刷一次。
    _syncPolling();
  }

  Future<void> stop(List<int> ids) async {
    await SubscriptionApi.stop(apiBaseUrl: _apiBaseUrl, ids: ids);
    await refresh();
  }

  Future<void> setEnabled(List<int> ids, bool enabled) async {
    await SubscriptionApi.setEnabled(
      apiBaseUrl: _apiBaseUrl,
      ids: ids,
      enabled: enabled,
    );
    await refresh();
  }

  Future<void> delete(List<int> ids, {bool force = false}) async {
    await SubscriptionApi.delete(
      apiBaseUrl: _apiBaseUrl,
      ids: ids,
      force: force,
    );
    await refresh();
  }
}

final subListProvider =
    NotifierProvider<SubListNotifier, SubListState>(SubListNotifier.new);
