import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/dio_client.dart';
import '../../../core/storage/prefs.dart';
import '../../../core/storage/secure_storage.dart';
import 'panel_token_manager.dart';
import '../models/panel_info.dart';

final panelListProvider =
    StateNotifierProvider<PanelListNotifier, List<PanelInfo>>(
  (ref) => PanelListNotifier(),
);

final currentPanelIdProvider = StateProvider<String?>((ref) => null);

final currentPanelProvider = Provider<PanelInfo?>((ref) {
  final panels = ref.watch(panelListProvider);
  final id = ref.watch(currentPanelIdProvider);
  if (id != null) {
    final match = panels.where((p) => p.id == id).isEmpty
        ? null
        : panels.where((p) => p.id == id).first;
    if (match != null) return match;
  }
  final defaultPanel = panels.where((p) => p.isDefault).isEmpty
      ? null
      : panels.where((p) => p.isDefault).first;
  return defaultPanel ?? (panels.isNotEmpty ? panels.first : null);
});

final hasPanelsProvider = Provider<bool>((ref) {
  return ref.watch(panelListProvider).isNotEmpty;
});

class PanelListNotifier extends StateNotifier<List<PanelInfo>> {
  PanelListNotifier() : super(const []);

  bool _loaded = false;

  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    final data = await Prefs.readPanelData();
    final order = await Prefs.readPanelOrder();
    final defaultId = await Prefs.readDefaultPanelId();
    final panels = <PanelInfo>[];
    for (final id in order) {
      final raw = data[id];
      if (raw != null) {
        final panel = _decodePanel(raw).copyWith(
          isDefault: id == defaultId,
        );
        // 密码从安全存储读取（仅账号密码模式）。
        if (panel.loginType == LoginType.account) {
          final password = await SecureStorage.readPassword(panel.id);
          if (password != null) {
            panels.add(panel.copyWith(password: () => password));
            continue;
          }
        }
        panels.add(panel);
      }
    }
    // 若 order 缺失，则按 data 顺序补充。
    for (final entry in data.entries) {
      if (panels.any((p) => p.id == entry.key)) continue;
      final panel = _decodePanel(entry.value);
      panels.add(panel.copyWith(isDefault: panel.id == defaultId));
    }
    state = panels;
    _loaded = true;
  }

  Future<void> add(PanelInfo panel) async {
    state = [...state, panel];
    await _persist();
  }

  Future<void> update(PanelInfo panel) async {
    state = [
      for (final p in state)
        if (p.id == panel.id) panel else p
    ];
    await _persist();
  }

  Future<void> remove(String id) async {
    state = state.where((p) => p.id != id).toList();
    await SecureStorage.deleteToken(id);
    await SecureStorage.deletePassword(id);
    final data = await Prefs.readPanelData();
    data.remove(id);
    await Prefs.writePanelData(data);
    await _persistOrder();
  }

  Future<void> markDefault(String id) async {
    state = [
      for (final p in state) p.copyWith(isDefault: p.id == id),
    ];
    await Prefs.writeDefaultPanelId(id);
  }

  Future<void> reorder(List<PanelInfo> panels) async {
    state = List.of(panels);
    await _persistOrder();
  }

  Future<void> _persist() async {
    final data = await Prefs.readPanelData();
    for (final p in state) {
      data[p.id] = jsonEncode({
        'id': p.id,
        'name': p.name,
        'baseUrl': p.baseUrl,
        'loginType': p.loginType.name,
        'username': p.username,
        'clientId': p.clientId,
        'clientSecret': p.clientSecret,
        'isDefault': p.isDefault,
        'createTime': p.createTime?.toIso8601String(),
      });
    }
    await Prefs.writePanelData(data);
    await _persistOrder();
  }

  Future<void> _persistOrder() async {
    final order = [for (final p in state) p.id];
    await Prefs.writePanelOrder(order);
    final defaultId = state.where((p) => p.isDefault).isEmpty
        ? null
        : state.where((p) => p.isDefault).first.id;
    await Prefs.writeDefaultPanelId(defaultId);
  }

  PanelInfo _decodePanel(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return PanelInfo(
      id: map['id'] as String? ?? _fallbackId(map),
      name: map['name'] as String? ?? '未命名面板',
      baseUrl: map['baseUrl'] as String? ?? '',
      loginType:
          LoginType.values.asNameMap()[map['loginType']] ?? LoginType.account,
      username: map['username'] as String?,
      clientId: map['clientId'] as String?,
      clientSecret: map['clientSecret'] as String?,
      isDefault: map['isDefault'] as bool? ?? false,
      createTime: map['createTime'] == null
          ? null
          : DateTime.tryParse(map['createTime'] as String),
    );
  }

  String _fallbackId(Map<String, dynamic> map) {
    final name = map['name'] as String? ?? 'panel';
    final base = map['baseUrl'] as String? ?? '';
    return '${name}_${base.hashCode}';
  }
}

/// 刷新当前面板对应的 Dio Token / 401 自动重登。
///
/// 换票逻辑全部交给 [PanelTokenManager]：它会看到期时间提前续期、并发合流，
/// 所以这里只是把它接到 Dio 上。
void configureDioForPanel(PanelInfo? panel) {
  DioClient.configure(
    tokenProvider: () async {
      if (panel == null) return null;
      return PanelTokenManager.token(panel);
    },
    unauthorizedHandler: () async {
      if (panel == null) return false;
      // 走到这里说明服务端不认手上的票（会话被清、密码改了、时钟差太多），
      // 到期时间已经不可信，直接强制换一张。
      final token = await PanelTokenManager.renew(panel);
      return token != null && token.isNotEmpty;
    },
  );
}
