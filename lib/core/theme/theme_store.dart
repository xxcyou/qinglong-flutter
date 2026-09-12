import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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
  static const packagesRoot = '/workspace/.ql_themes/packages';
  static const exportsRoot = '/workspace/.ql_themes/exports';

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

  /// 从 ZIP 主题包导入。zip 内必须包含 theme.json，推荐目录结构：
  /// theme.json / README.md / controller.js / css/ / js/ / image/background/
  /// image/elements/ / audio/ / 方案/。有 index.html 会启用 WebView 动态背景。
  Future<ThemeConfig> importZip(String guestZipPath) async {
    await _bridge.exec(
      command: 'mkdir -p $packagesRoot',
      timeoutSeconds: 20,
    );
    final zipHost = await _bridge.hostPath(path: guestZipPath, scope: 'shell');
    final bytes = await File(zipHost).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final themeId = 'pkg${DateTime.now().millisecondsSinceEpoch}';
    final packageGuest = '$packagesRoot/$themeId';
    await _bridge.exec(command: 'mkdir -p $packageGuest', timeoutSeconds: 20);
    final packageHost =
        await _bridge.hostPath(path: packageGuest, scope: 'shell');

    // 找到 theme.json 并解析。
    ArchiveFile? configFile;
    for (final f in archive.files) {
      final name = f.name.replaceAll('\\', '/');
      if (f.isFile && name.endsWith('theme.json')) {
        configFile = f;
        break;
      }
    }
    if (configFile == null) {
      throw Exception('ZIP 里找不到 theme.json');
    }
    var config = ThemeConfig.fromJson(
      jsonDecode(utf8.decode(configFile.content as List<int>)),
    );

    // 解包全部文件。
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll('\\', '/');
      final hostTarget = File('$packageHost/$name');
      await hostTarget.parent.create(recursive: true);
      await hostTarget.writeAsBytes(f.content as List<int>, flush: true);
    }

    // 检测动态 HTML 背景。
    final htmlRel = archive.files.any((f) =>
        f.isFile &&
        (f.name.endsWith('index.html') || f.name.endsWith('/index.htm')));
    if (htmlRel) {
      final htmlName = archive.files
          .firstWhere((f) =>
              f.isFile &&
              (f.name.endsWith('index.html') || f.name.endsWith('/index.htm')))
          .name
          .replaceAll('\\', '/');
      config = config.copyWith(
        id: themeId,
        name: config.name.isEmpty ? 'ZIP 主题' : config.name,
        backgroundHtml: '$packageGuest/$htmlName',
      );
    } else {
      // 没有 HTML 就用第一张背景图兜底。
      final bg = archive.files
          .where((f) =>
              f.isFile &&
              (f.name.contains('background') || f.name.contains('背景')) &&
              (f.name.endsWith('.png') ||
                  f.name.endsWith('.jpg') ||
                  f.name.endsWith('.jpeg') ||
                  f.name.endsWith('.webp')))
          .toList();
      if (bg.isNotEmpty) {
        final name = bg.first.name.replaceAll('\\', '/');
        config = config.copyWith(
          id: themeId,
          name: config.name.isEmpty ? 'ZIP 主题' : config.name,
          backgroundImage: '$packageGuest/$name',
        );
      } else {
        config = config.copyWith(
          id: themeId,
          name: config.name.isEmpty ? 'ZIP 主题' : config.name,
        );
      }
    }
    await upsert(config);
    return config;
  }

  /// 导出主题为 ZIP 包。返回 guest 路径。
  ///
  /// 纯色主题（没有 package 目录）会临时生成最小包：theme.json + README.md
  /// + controller.js；有动态背景的包会把 packages/<id>/ 整个目录打进去。
  Future<String> exportZip(String id, {String? outPath}) async {
    final theme = state.byId(id);
    if (theme == null) throw Exception('找不到主题 $id');
    await _bridge.exec(
      command: 'mkdir -p $exportsRoot',
      timeoutSeconds: 20,
    );
    final safe = _safeName(theme.name.isEmpty ? theme.id : theme.name);
    final guestOut =
        outPath?.isNotEmpty == true ? outPath! : '$exportsRoot/$safe.zip';
    final hostRoot = await _bridge.hostPath(path: exportsRoot, scope: 'shell');
    final hostOut = File('$hostRoot/$safe.zip');

    // 收集要打包的文件。默认/纯色主题没有 package 目录时先补一个最小包目录，
    // 再打包，避免“默认主题导出失败”这种问题。
    final packageGuest = await _ensurePackageDir(theme);
    final files = <String, List<int>>{};
    final hostDir = await _bridge.hostPath(path: packageGuest, scope: 'shell');
    final dir = Directory(hostDir);
    for (final f in dir.listSync(recursive: true, followLinks: false)) {
      if (f is File) {
        files[f.path.substring(hostDir.length + 1)] = f.readAsBytesSync();
      }
    }

    files['theme.json'] = utf8.encode(jsonEncode(theme.toJson()));
    if (!files.containsKey('README.md')) {
      files['README.md'] = utf8.encode(
        '# ${theme.name}\n\n${theme.backgroundHtml.isEmpty ? '纯色/静态主题' : 'HTML/CSS/JS 动态背景主题'}\n'
        '来源：APP 主题 ${theme.id}\n',
      );
    }
    if (!files.containsKey('controller.js')) {
      files['controller.js'] = utf8.encode(
        '// 纯色主题控制脚本：只声明配色，不创建任何 WebView/动画。\n'
        'const theme = ${jsonEncode(theme.toJson())};\n'
        'if (!theme.backgroundHtml) { export default { pure: true, colors: theme.colors }; }\n',
      );
    }

    final archive = Archive();
    for (final e in files.entries) {
      archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    final zipBytes = ZipEncoder().encode(archive)!;
    if (!hostOut.parent.existsSync()) {
      hostOut.parent.createSync(recursive: true);
    }
    await hostOut.writeAsBytes(zipBytes, flush: true);
    return guestOut;
  }

  /// 确保主题有 package 目录；没有就生成最小纯色包（默认主题导出用这个）。
  Future<String> _ensurePackageDir(ThemeConfig theme) async {
    final packageGuest = '$packagesRoot/${theme.id}';
    try {
      await _bridge.hostPath(path: packageGuest, scope: 'shell');
      return packageGuest;
    } catch (_) {
      // 不存在就新建。
    }
    await _bridge.exec(
      command: 'mkdir -p $packageGuest',
      timeoutSeconds: 20,
    );
    final hostDir = await _bridge.hostPath(path: packageGuest, scope: 'shell');
    final themeFile = File('$hostDir/theme.json');
    if (!themeFile.existsSync()) {
      await themeFile.writeAsString(
        jsonEncode(theme.toJson()),
        flush: true,
      );
    }
    final readme = File('$hostDir/README.md');
    if (!readme.existsSync()) {
      await readme.writeAsString(
        '# ${theme.name}\n\n${theme.backgroundHtml.isEmpty ? '纯色/静态主题' : 'HTML/CSS/JS 动态背景主题'}\n'
        '来源：APP 主题 ${theme.id}\n',
        flush: true,
      );
    }
    final controller = File('$hostDir/controller.js');
    if (!controller.existsSync()) {
      await controller.writeAsString(
        '// 纯色主题控制脚本：只声明配色，不创建任何 WebView/动画。\n'
        'const theme = ${jsonEncode(theme.toJson())};\n'
        'if (!theme.backgroundHtml) { export default { pure: true, colors: theme.colors }; }\n',
        flush: true,
      );
    }
    return packageGuest;
  }

  String _safeName(String name) {
    // 文件名只用安全 ASCII，避免中文/特殊字符在部分文件系统或 zip 工具里出问题。
    if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) return name;
    return 'theme_${DateTime.now().millisecondsSinceEpoch}';
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
