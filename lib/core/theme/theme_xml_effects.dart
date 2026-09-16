import 'dart:io';

import 'theme_effects_controller.dart';

/// 主题包 XML 组件构造：读取 `xml/` 下的组件/特效声明，转换成 DSHTheme effect。
///
/// 支持简单声明式 XML，例如：
/// ```xml
/// <effects>
///   <effect id="petal-1"
///           imagePath="image/elements/petal.png"
///           x="120" y="80" width="48" height="48"
///           color="#FFB3BA"
///           animation="float" durationMs="2400"
///           opacity="0.9" />
///   <effect id="badge-1"
///           icon="sparkle"
///           x="720" y="56" width="32" height="32"
///           color="#FFD700" />
/// </effects>
/// ```
Future<List<ThemeEffect>> loadThemeXmlEffects(String hostPackageRoot) async {
  final effects = <ThemeEffect>[];
  final xmlDir = Directory('$hostPackageRoot/xml');
  if (!xmlDir.existsSync()) return effects;

  var index = 0;
  for (final file in xmlDir.listSync(recursive: true).whereType<File>()) {
    if (!file.path.toLowerCase().endsWith('.xml')) continue;
    final content = await file.readAsString();
    final fileName = file.path.split(Platform.pathSeparator).last;
    final baseName = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;

    for (final match
        in RegExp(r'<(?:effect|component)\b([^>]*?)/?>').allMatches(content)) {
      final tag = match.group(1)?.trim() ?? '';
      if (tag.isEmpty) continue;
      final attrs = _parseAttrs(tag);
      final rawId = attrs['id']?.trim() ?? '';
      final id = rawId.isNotEmpty ? rawId : 'xml_${baseName}_${index++}';

      final effect = ThemeEffectBridge.parseEffect({
        'id': id,
        if (attrs['imagePath']?.isNotEmpty == true)
          'imagePath': attrs['imagePath'],
        if (attrs['icon']?.isNotEmpty == true) 'icon': attrs['icon'],
        if (attrs['text']?.isNotEmpty == true) 'text': attrs['text'],
        'x': _num(attrs, 'x') ?? 0,
        'y': _num(attrs, 'y') ?? 0,
        'width': _num(attrs, 'width') ?? _num(attrs, 'w') ?? 80,
        'height': _num(attrs, 'height') ?? _num(attrs, 'h') ?? 80,
        if (attrs['color']?.isNotEmpty == true)
          'color': ThemeEffectBridge.parseColor(attrs['color']!)?.toARGB32() ??
              attrs['color'],
        if (_num(attrs, 'fontSize') != null)
          'fontSize': _num(attrs, 'fontSize'),
        if (attrs['animation']?.isNotEmpty == true)
          'animation': attrs['animation'],
        if (attrs['fit']?.isNotEmpty == true) 'fit': attrs['fit'],
        if (_bool(attrs, 'interactive') != null)
          'interactive': _bool(attrs, 'interactive'),
        if (_bool(attrs, 'speechTail') != null)
          'speechTail': _bool(attrs, 'speechTail'),
        if (_num(attrs, 'opacity') != null) 'opacity': _num(attrs, 'opacity'),
        if (_num(attrs, 'rotation') != null)
          'rotation': _num(attrs, 'rotation'),
        if (_num(attrs, 'scale') != null) 'scale': _num(attrs, 'scale'),
        if (_num(attrs, 'durationMs') != null)
          'durationMs': _num(attrs, 'durationMs')!.round(),
        if (attrs['textBackgroundColor']?.isNotEmpty == true)
          'textBackgroundColor':
              ThemeEffectBridge.parseColor(attrs['textBackgroundColor']!)
                  ?.toARGB32(),
        if (attrs['textBorderColor']?.isNotEmpty == true)
          'textBorderColor':
              ThemeEffectBridge.parseColor(attrs['textBorderColor']!)
                  ?.toARGB32(),
        if (_num(attrs, 'textBorderWidth') != null)
          'textBorderWidth': _num(attrs, 'textBorderWidth'),
        if (_num(attrs, 'textRadius') != null)
          'textRadius': _num(attrs, 'textRadius'),
        if (_num(attrs, 'textPadding') != null)
          'textPadding': _num(attrs, 'textPadding'),
      });
      if (effect != null) effects.add(effect);
    }
  }
  return effects;
}

Map<String, String> _parseAttrs(String tagBody) {
  final map = <String, String>{};
  for (final m in RegExp(r'([\w:-]+)\s*=\s*"([^"]*)"').allMatches(tagBody)) {
    map[m.group(1)!] = m.group(2)!;
  }
  return map;
}

double? _num(Map<String, String> attrs, String key) {
  final value = attrs[key];
  if (value == null || value.isEmpty) return null;
  return double.tryParse(value);
}

bool? _bool(Map<String, String> attrs, String key) {
  final value = attrs[key]?.toLowerCase();
  if (value == null) return null;
  if (value == 'true' || value == '1' || value == 'yes') return true;
  if (value == 'false' || value == '0' || value == 'no') return false;
  return null;
}
