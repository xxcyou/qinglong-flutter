import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panels/providers/panel_list_provider.dart';
import '../api/log_api.dart';
import '../models/log_item.dart';

class LogListState {
  const LogListState({
    this.items = const [],
    this.search = '',
    this.isLoading = false,
    this.error,
  });

  final List<LogItem> items;
  final String search;
  final bool isLoading;
  final Object? error;

  LogListState copyWith({
    List<LogItem>? items,
    String? search,
    bool? isLoading,
    Object? error,
    bool clearError = false,
  }) {
    return LogListState(
      items: items ?? this.items,
      search: search ?? this.search,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class LogListNotifier extends Notifier<LogListState> {
  @override
  LogListState build() {
    ref.listen(currentPanelProvider, (previous, next) {
      if (previous?.id != next?.id && next != null) {
        Future.microtask(load);
      }
    });
    return const LogListState();
  }

  String get _apiBaseUrl {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) throw StateError('未选择面板');
    return panel.apiBaseUrl;
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final items = await LogApi.list(
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
}

final logListProvider =
    NotifierProvider<LogListNotifier, LogListState>(LogListNotifier.new);
