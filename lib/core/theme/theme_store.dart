import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local_shell/proot_bridge.dart';
import '../utils/logger.dart';
import 'theme_config.dart';

/// 主题方案库状态。
class ThemeState {
  const ThemeState({
    this.themes = const [],
    this.activeId = '',
    this.loaded = false,
  });

  final List<ThemeConfig> themes;

  /// 当前应用的主题 id。
  final String activeId;
  final bool loaded;

  ThemeConfig? get active {
    for (final t in themes) {
      if (t.id == activeId) return t;
    }
    return null;
  }

  ThemeConfig? byId(String id) {
    for (final t in themes) {
      if (t.id == id) return t;
    }
    return null;
  }

  ThemeState copyWith({
    List<ThemeConfig>? themes,
    String? activeId,
    bool? loaded,
  }) {
    return ThemeState(
      themes: themes ?? this.themes,
      activeId: activeId ?? this.activeId,
      loaded: loaded ?? this.loaded,
    );
  }
}

/// 主题方案读写：配置文件在 `/workspace/.ql_themes/themes.json`。
///
/// 用文件而不是 SharedPreferences，就是让 AI/终端/用户都能直接打开这个
/// JSON 改颜色、改背景图路径、改玻璃效果，改完 App 里一应用就生效。
class ThemeNotifier extends Notifier<ThemeState> {
  static const configPath = '/workspace/.ql_themes/themes.json';

  final _bridge = ProotBridge();
  bool _loaded = false;

  @override
  ThemeState build() => const ThemeState();

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      await _bridge.exec(
        command: 'mkdir -p /workspace/.ql_themes',
        timeoutSeconds: 20,
      );
      final raw = await _bridge.readFile(path: configPath);
      if (raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final themes = [
            for (final it in (decoded['themes'] as List? ?? const []))
              if (it is Map<String, dynamic>) ThemeConfig.fromJson(it),
          ];
          final activeId = decoded['activeId']?.toString() ??
              (themes.isNotEmpty ? themes.first.id : '');
          state = ThemeState(themes: themes, activeId: activeId, loaded: true);
          return;
        }
      }
      state = _defaultState();
      await _save();
    } catch (e) {
      // Runtime 没装/文件系统不可用时退回内存默认，App 照常能用。
      Logger.e('theme', '主题配置读取失败，使用默认主题', e);
      state = _defaultState(loaded: true);
    }
  }

  ThemeState _defaultState({bool loaded = false}) {
    final dark = ThemeConfig(
      id: 'default-dark',
      name: '默认暗色',
      brightness: 'dark',
      colors: ThemeConfig.defaultColorsForBrightness('dark'),
      effects: ThemeConfig.defaultEffects,
    );
    final light = ThemeConfig(
      id: 'default-light',
      name: '默认亮色',
      brightness: 'light',
      colors: ThemeConfig.defaultColorsForBrightness('light'),
      effects: ThemeConfig.defaultEffects,
    );
    return ThemeState(
      themes: [dark, light],
      activeId: 'default-dark',
      loaded: loaded,
    );
  }

  Future<void> _save() async {
    try {
      await _bridge.exec(
        command: 'mkdir -p /workspace/.ql_themes',
        timeoutSeconds: 20,
      );
      await _bridge.writeFile(
        path: configPath,
        content: jsonEncode({
          'activeId': state.activeId,
          'themes': [for (final t in state.themes) t.toJson()],
        }),
      );
    } catch (e) {
      Logger.e('theme', '主题配置保存失败', e);
    }
  }

  /// 新增/覆盖主题。
  Future<void> upsert(ThemeConfig config) async {
    final list = [...state.themes];
    final idx = list.indexWhere((t) => t.id == config.id);
    if (idx < 0) {
      list.add(config);
    } else {
      list[idx] = config;
    }
    state = state.copyWith(themes: list);
    await _save();
  }

  Future<void> remove(String id) async {
    state = state.copyWith(
      themes: state.themes.where((t) => t.id != id).toList(),
      activeId: state.activeId == id
          ? (state.themes.length > 1
              ? state.themes.firstWhere((t) => t.id != id).id
              : '')
          : state.activeId,
    );
    await _save();
  }

  /// 应用某个主题（只改 activeId，不删别的方案）。
  Future<void> apply(String id) async {
    if (state.byId(id) == null) return;
    state = state.copyWith(activeId: id);
    await _save();
  }

  /// 导出一个主题为 JSON 字符串。
  String exportJson(String id) {
    final theme = state.byId(id);
    if (theme == null) return '';
    return const JsonEncoder.withIndent('  ').convert(theme.toJson());
  }

  /// 从 JSON 字符串导入一个主题。id 重复时覆盖；不传 id 则自动生成。
  Future<ThemeConfig> importJson(
    String jsonText, {
    String? overrideId,
  }) async {
    final decoded = jsonDecode(jsonText);
    final map = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    var theme = ThemeConfig.fromJson(map);
    if (overrideId != null && overrideId.isNotEmpty) {
      theme = theme.copyWith(id: overrideId);
    }
    await upsert(theme);
    return theme;
  }
}

final themeProvider =
    NotifierProvider<ThemeNotifier, ThemeState>(ThemeNotifier.new);
