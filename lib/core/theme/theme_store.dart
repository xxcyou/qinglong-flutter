import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// 主题方案读写：主题一律是 ZIP 包。
///
/// 包目录在 `/workspace/.ql_themes/packages/<id>/`，核心配置是 `controller.js`
/// 控制脚本（纯色也在脚本里配置），HTML/CSS/JS/图片/音频/方案目录原样保留。
/// 不用任何独立 JSON 主题文件；当前激活主题 id 只存在 SharedPreferences。
class ThemeNotifier extends Notifier<ThemeState> {
  static const packagesRoot = '/workspace/.ql_themes/packages';
  static const exportsRoot = '/workspace/.ql_themes/exports';
  static const activeKey = 'activeThemeId';

  final _bridge = ProotBridge();
  bool _loading = false;
  int _retryCount = 0;

  @override
  ThemeState build() => const ThemeState();

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    try {
      // 用 Dart 直接建目录，不依赖 PRoot exec（避免启动时 proot 还没起来导致
      // “默认主题目录不存在/导出失败”）。
      const qlGuest = '/workspace/.ql_themes';
      String qlHost;
      try {
        qlHost = await _bridge.hostPath(path: qlGuest, scope: 'shell');
      } catch (_) {
        await _bridge.exec(command: 'mkdir -p $qlGuest', timeoutSeconds: 20);
        qlHost = await _bridge.hostPath(path: qlGuest, scope: 'shell');
      }
      Directory('$qlHost/packages').createSync(recursive: true);
      Directory('$qlHost/exports').createSync(recursive: true);
      // 清理旧的独立 JSON 主题索引，全面只认 ZIP 包。
      final oldJson = File('$qlHost/themes.json');
      if (oldJson.existsSync()) {
        try {
          oldJson.deleteSync();
        } catch (_) {}
      }
      // 保证默认暗色/亮色也是真实存在的 ZIP 主题包目录。
      await _ensureDefaults();
      final themes = await _scanPackages();
      final prefs = await SharedPreferences.getInstance();
      final activeId = prefs.getString(activeKey) ??
          (themes.isNotEmpty ? themes.first.id : '');
      state = ThemeState(themes: themes, activeId: activeId, loaded: true);
      _retryCount = 0;
      _loading = false;
    } catch (e) {
      // Runtime 没装/文件系统不可用时退回内存默认，App 照常能用；
      // 稍后自动重试，避免启动时 PRoot 还没就绪导致默认主题包建不出来。
      Logger.e('theme', '主题包扫描失败，使用默认主题，稍后重试', e);
      state = _defaultState(loaded: true);
      _loading = false;
      if (_retryCount < 5) {
        _retryCount++;
        Future<void>.delayed(const Duration(seconds: 1), load);
      }
    }
  }

  Future<void> _ensureDefaults() async {
    final defaults = [
      ThemeConfig(
        id: 'default-dark',
        name: '默认暗色',
        brightness: 'dark',
        colors: ThemeConfig.defaultColorsForBrightness('dark'),
        effects: ThemeConfig.defaultEffects,
      ),
      ThemeConfig(
        id: 'default-light',
        name: '默认亮色',
        brightness: 'light',
        colors: ThemeConfig.defaultColorsForBrightness('light'),
        effects: ThemeConfig.defaultEffects,
      ),
    ];
    for (final t in defaults) {
      await _ensurePackageDir(t);
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

  Future<List<ThemeConfig>> _scanPackages() async {
    final hostRoot = await _bridge.hostPath(path: packagesRoot, scope: 'shell');
    final rootDir = Directory(hostRoot);
    if (!rootDir.existsSync()) return const [];
    final result = <ThemeConfig>[];
    for (final d in rootDir.listSync(followLinks: false)) {
      if (d is! Directory) continue;
      final id = d.path.split(Platform.pathSeparator).last;
      try {
        result.add(await _readPackageConfig(id));
      } catch (e) {
        Logger.e('theme', '主题包 $id 解析失败，跳过', e);
      }
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  /// 从 package 目录读取主题配置：核心是 controller.js。
  Future<ThemeConfig> _readPackageConfig(String id) async {
    final packageGuest = '$packagesRoot/$id';
    final hostDir = await _bridge.hostPath(path: packageGuest, scope: 'shell');
    final dir = Directory(hostDir);
    final controllerFile = File('$hostDir/controller.js');
    if (!controllerFile.existsSync()) {
      throw Exception('主题包 $id 缺少 controller.js');
    }
    final data = _parseJsObject(await controllerFile.readAsString());
    final brightness =
        data['brightness']?.toString() == 'light' ? 'light' : 'dark';
    final baseColors = ThemeConfig.defaultColorsForBrightness(brightness);
    final rawColors = data['colors'];
    final colors = <String, String>{
      ...baseColors,
      if (rawColors is Map)
        for (final e in rawColors.entries) e.key.toString(): e.value.toString(),
    };
    final rawEffects = data['effects'];
    final effects = <String, double>{
      ...ThemeConfig.defaultEffects,
      if (rawEffects is Map)
        for (final e in rawEffects.entries)
          e.key.toString(): (e.value as num?)?.toDouble() ??
              ThemeConfig.defaultEffects[e.key.toString()] ??
              0,
    };

    var backgroundImage = data['backgroundImage']?.toString() ?? '';
    var backgroundHtml = '';
    final htmlCandidates = [
      '$hostDir/html/index.html',
      '$hostDir/html/background.html',
      '$hostDir/index.html',
      '$hostDir/index.htm',
    ];
    for (final candidate in htmlCandidates) {
      if (File(candidate).existsSync()) {
        final rel =
            candidate.substring(hostDir.length + 1).replaceAll('\\', '/');
        backgroundHtml = '$packageGuest/$rel';
        break;
      }
    }
    if (backgroundHtml.isEmpty && Directory('$hostDir/html').existsSync()) {
      final htmlDir = Directory('$hostDir/html');
      final htmlFiles = htmlDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.html') || f.path.endsWith('.htm'))
          .toList();
      if (htmlFiles.isNotEmpty) {
        final rel = htmlFiles.first.path
            .substring(hostDir.length + 1)
            .replaceAll('\\', '/');
        backgroundHtml = '$packageGuest/$rel';
      }
    }
    if (backgroundHtml.isEmpty) {
      backgroundImage =
          _findBackgroundImage(dir, packageGuest, backgroundImage) ??
              backgroundImage;
    }

    return ThemeConfig(
      id: id,
      name: data['name']?.toString() ?? id,
      brightness: brightness,
      backgroundImage: backgroundImage,
      backgroundHtml: backgroundHtml,
      colors: colors,
      effects: effects,
    );
  }

  String? _findBackgroundImage(
    Directory dir,
    String packageGuest,
    String current,
  ) {
    if (current.isNotEmpty) return current;
    for (final f in dir.listSync(recursive: true, followLinks: false)) {
      if (f is! File) continue;
      final path = f.path.replaceAll('\\', '/');
      final lower = path.toLowerCase();
      final inBg = lower.contains('/background/') ||
          lower.contains('image/background') ||
          lower.contains('背景');
      if (!inBg) continue;
      if (!(lower.endsWith('.png') ||
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.gif'))) {
        continue;
      }
      final rel = f.path.substring(dir.path.length + 1).replaceAll('\\', '/');
      return '$packageGuest/$rel';
    }
    return null;
  }

  /// 新增/覆盖主题包（写 controller.js，不写任何 JSON 主题文件）。
  Future<void> upsert(ThemeConfig config) async {
    await _writePackageConfig(config);
    final list = [...state.themes];
    final idx = list.indexWhere((t) => t.id == config.id);
    if (idx < 0) {
      list.add(config);
    } else {
      list[idx] = config;
    }
    state = state.copyWith(themes: list);
  }

  Future<void> remove(String id) async {
    try {
      final hostDir =
          await _bridge.hostPath(path: '$packagesRoot/$id', scope: 'shell');
      if (Directory(hostDir).existsSync()) {
        Directory(hostDir).deleteSync(recursive: true);
      }
    } catch (_) {}
    state = state.copyWith(
      themes: state.themes.where((t) => t.id != id).toList(),
      activeId: state.activeId == id
          ? (state.themes.length > 1
              ? state.themes.firstWhere((t) => t.id != id).id
              : '')
          : state.activeId,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(activeKey, state.activeId);
  }

  /// 应用某个主题（只改 activeId，不删别的方案）。
  Future<void> apply(String id) async {
    if (state.byId(id) == null) return;
    state = state.copyWith(activeId: id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(activeKey, id);
  }

  /// 从 ZIP 主题包导入。zip 内必须有 controller.js（纯色配置也写在脚本里）。
  Future<ThemeConfig> importZip(String guestZipPath) async {
    final rootHost = await _bridge.hostPath(path: packagesRoot, scope: 'shell');
    final zipHost = await _bridge.hostPath(path: guestZipPath, scope: 'shell');
    final bytes = await File(zipHost).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final themeId = 'pkg${DateTime.now().millisecondsSinceEpoch}';
    final packageHost = '$rootHost/$themeId';
    Directory(packageHost).createSync(recursive: true);

    for (final f in archive.files) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll('\\', '/');
      final hostTarget = File('$packageHost/$name');
      await hostTarget.parent.create(recursive: true);
      await hostTarget.writeAsBytes(f.content as List<int>, flush: true);
    }
    _deleteJsonThemeFiles(packageHost);

    if (!File('$packageHost/controller.js').existsSync()) {
      Directory(packageHost).deleteSync(recursive: true);
      throw Exception('ZIP 里没有 controller.js，不是有效的主题包');
    }

    final config = await _readPackageConfig(themeId);
    await upsert(config);
    return config;
  }

  /// 导出主题为 ZIP 包。返回 guest 路径。
  Future<String> exportZip(String id, {String? outPath}) async {
    final theme = state.byId(id);
    if (theme == null) throw Exception('找不到主题 $id');
    final hostRoot = await _bridge.hostPath(path: exportsRoot, scope: 'shell');
    Directory(hostRoot).createSync(recursive: true);
    // 保证默认主题也是完整 package 目录。
    final packageGuest = await _ensurePackageDir(theme);
    final safe = _safeName(theme.name.isEmpty ? theme.id : theme.name);
    final hostOut = File('$hostRoot/$safe.zip');
    final hostDir = await _bridge.hostPath(path: packageGuest, scope: 'shell');
    final dir = Directory(hostDir);
    final files = <String, List<int>>{};
    for (final f in dir.listSync(recursive: true, followLinks: false)) {
      if (f is File) {
        files[f.path.substring(hostDir.length + 1)] = f.readAsBytesSync();
      }
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
    return '$exportsRoot/$safe.zip';
  }

  /// 标准主题包目录骨架：除了 README.md 和 controller.js，其余都是目录。
  static const _packageDirs = [
    'image/elements',
    'scripts',
    'audio',
    'css',
    'js',
    'html',
    'xml/components',
    'xml/animations',
  ];

  void _ensurePackageStructure(String hostDir) {
    for (final sub in _packageDirs) {
      Directory('$hostDir/$sub').createSync(recursive: true);
    }
    // 空目录在 zip 里不保留，放一个 .gitkeep 方便用户看到骨架。
    for (final sub in _packageDirs) {
      File('$hostDir/$sub/.gitkeep').createSync(recursive: false);
    }
  }

  /// 确保主题有 package 目录；没有就生成最小纯色包（默认主题导出用这个）。
  Future<String> _ensurePackageDir(ThemeConfig theme) async {
    final rootHost = await _bridge.hostPath(path: packagesRoot, scope: 'shell');
    final packageGuest = '$packagesRoot/${theme.id}';
    final hostDir = '$rootHost/${theme.id}';
    Directory(hostDir).createSync(recursive: true);
    _ensurePackageStructure(hostDir);
    if (!File('$hostDir/controller.js').existsSync()) {
      await _writeController(hostDir, theme);
    }
    _deleteJsonThemeFiles(hostDir);
    final readme = File('$hostDir/README.md');
    if (!readme.existsSync()) {
      await readme.writeAsString(
        '# ${theme.name}\n\n${theme.backgroundHtml.isEmpty ? '纯色/静态主题' : 'HTML/CSS/JS 动态背景主题'}\n'
        '来源：APP 主题 ${theme.id}\n',
        flush: true,
      );
    }
    return packageGuest;
  }

  Future<void> _writePackageConfig(ThemeConfig theme) async {
    final rootHost = await _bridge.hostPath(path: packagesRoot, scope: 'shell');
    final hostDir = '$rootHost/${theme.id}';
    Directory(hostDir).createSync(recursive: true);
    _ensurePackageStructure(hostDir);
    await _writeController(hostDir, theme);
    final readme = File('$hostDir/README.md');
    if (!readme.existsSync()) {
      await readme.writeAsString(
        '# ${theme.name}\n\n${theme.backgroundHtml.isEmpty ? '纯色/静态主题' : 'HTML/CSS/JS 动态背景主题'}\n'
        '来源：APP 主题 ${theme.id}\n',
        flush: true,
      );
    }
  }

  Future<void> _writeController(String hostDir, ThemeConfig theme) async {
    final b = StringBuffer();
    b.writeln('// 主题控制脚本：这是整个主题的总控入口（纯色也在这里配置）。');
    b.writeln('// 它负责分配：哪个组件用哪个子 js / css / html / xml / 图片 / 音效。');
    b.writeln('const theme = {');
    b.writeln("  id: '${_jsEscape(theme.id)}',");
    b.writeln("  name: '${_jsEscape(theme.name)}',");
    b.writeln("  brightness: '${_jsEscape(theme.brightness)}',");
    b.writeln("  backgroundImage: '${_jsEscape(theme.backgroundImage)}',");
    b.writeln('  colors: ${jsonEncode(theme.colors)},');
    b.writeln('  effects: ${jsonEncode(theme.effects)},');
    b.writeln('};');
    b.writeln('');
    b.writeln('// 主题资源路由：controller.js 在这里分配各组件的子脚本/样式/HTML/XML。');
    b.writeln("const themeResources = {");
    b.writeln("  components: {");
    b.writeln(
        "    background: { script: 'js/background.js', css: 'css/background.css', html: 'html/index.html', xml: 'xml/animations/background.xml' },");
    b.writeln(
        "    chatBubble: { script: 'js/chat-bubble.js', css: 'css/chat-bubble.css', html: 'html/chat-bubble.html', xml: 'xml/components/chat-bubble.xml' },");
    b.writeln("  },");
    b.writeln("  images: 'image/elements',");
    b.writeln("  scripts: 'scripts',");
    b.writeln("  audio: 'audio',");
    b.writeln("};");
    b.writeln('export default themeResources;');
    await File('$hostDir/controller.js').writeAsString(
      b.toString(),
      flush: true,
    );
  }

  String _jsEscape(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'")
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '');

  String _safeName(String name) {
    if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) return name;
    return 'theme_${DateTime.now().millisecondsSinceEpoch}';
  }

  /// 删除包内残留的 theme.json（全面改为 controller.js 配置）。
  void _deleteJsonThemeFiles(String hostDir) {
    final dir = Directory(hostDir);
    if (!dir.existsSync()) return;
    for (final f in dir.listSync(recursive: true, followLinks: false)) {
      if (f is File &&
          f.path.split(Platform.pathSeparator).last == 'theme.json') {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// 从 controller.js 里取 `const theme = {...}` 对象。
  Map<String, dynamic> _parseJsObject(String script) {
    final start = script.indexOf('{');
    if (start < 0) return const {};
    final end = _findClosingBrace(script, start);
    if (end < 0) return const {};
    var obj = script.substring(start, end + 1);
    // 先生成包里的 controller.js 本来就是合法 JSON 对象；AI 手写单引号/注释也兼容。
    obj = obj.replaceAll(RegExp(r'//[^\n]*'), '').replaceAll("'", '"');
    obj = obj.replaceAllMapped(
      RegExp(r'([{,]\s*)([A-Za-z_$][\w$]*)\s*:'),
      (m) => '${m.group(1)}"${m.group(2)}":',
    );
    obj = obj.replaceAll(RegExp(r',\s*}'), '}');
    try {
      final decoded = jsonDecode(obj);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {}
    return const {};
  }

  int _findClosingBrace(String s, int start) {
    var depth = 0;
    var inString = false;
    var quoteChar = '';
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (inString) {
        if (c == '\\') {
          i++;
          continue;
        }
        if (c == quoteChar) inString = false;
        continue;
      }
      if (c == "'" || c == '"') {
        inString = true;
        quoteChar = c;
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }
}

final themeProvider =
    NotifierProvider<ThemeNotifier, ThemeState>(ThemeNotifier.new);
