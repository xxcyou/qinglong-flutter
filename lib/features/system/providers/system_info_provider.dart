import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../panels/providers/panel_list_provider.dart';
import '../api/system_api.dart';
import '../models/system_info.dart';

class SystemInfoState {
  const SystemInfoState({this.info, this.isLoading = false, this.error});

  final SystemInfo? info;
  final bool isLoading;
  final Object? error;

  SystemInfoState copyWith({
    SystemInfo? info,
    bool clearInfo = false,
    bool? isLoading,
    Object? error,
    bool clearError = false,
  }) {
    return SystemInfoState(
      info: clearInfo ? null : info ?? this.info,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class SystemInfoNotifier extends Notifier<SystemInfoState> {
  @override
  SystemInfoState build() {
    ref.listen(currentPanelProvider, (previous, next) {
      if (previous?.id != next?.id && next != null) {
        Future.microtask(load);
      }
    });
    return const SystemInfoState();
  }

  String get _apiBaseUrl {
    final panel = ref.read(currentPanelProvider);
    if (panel == null) throw StateError('未选择面板');
    return panel.apiBaseUrl;
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final info = await SystemApi.info(apiBaseUrl: _apiBaseUrl);
      state = state.copyWith(info: info, isLoading: false, clearError: true);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e);
    }
  }

  Future<void> refresh() => load();

  Future<void> setLogRemoveFrequency(int days) async {
    await SystemApi.setLogRemoveFrequency(
      apiBaseUrl: _apiBaseUrl,
      days: days,
    );
    await load();
  }
}

final systemInfoProvider =
    NotifierProvider<SystemInfoNotifier, SystemInfoState>(
        SystemInfoNotifier.new);
