import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panels/providers/panel_list_provider.dart';
import '../api/config_api.dart';
import '../models/config_file.dart';

class ConfigListState {
  const ConfigListState({
    this.items = const [],
    this.isLoading = false,
    this.error,
  });

  final List<ConfigFile> items;
  final bool isLoading;
  final Object? error;

  ConfigListState copyWith({
    List<ConfigFile>? items,
    bool? isLoading,
    Object? error,
    bool clearError = false,
  }) {
    return ConfigListState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class ConfigListNotifier extends Notifier<ConfigListState> {
  @override
  ConfigListState build() {
    ref.listen(currentPanelProvider, (previous, next) {
      if (previous?.id != next?.id && next != null) {
        Future.microtask(load);
      }
    });
    return const ConfigListState();
  }

  String get _apiBaseUrl {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) throw StateError('未选择面板');
    return panel.apiBaseUrl;
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final items = await ConfigApi.files(apiBaseUrl: _apiBaseUrl);
      state = state.copyWith(items: items, isLoading: false, clearError: true);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e);
    }
  }

  Future<void> refresh() => load();

  Future<void> save(String file, String content) async {
    await ConfigApi.save(apiBaseUrl: _apiBaseUrl, file: file, content: content);
    await refresh();
  }
}

final configListProvider =
    NotifierProvider<ConfigListNotifier, ConfigListState>(
        ConfigListNotifier.new);
