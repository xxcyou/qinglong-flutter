import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/font_settings_scope.dart';
import '../../../core/theme/theme_config.dart';
import '../../../core/theme/theme_store.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/local_file_picker.dart';
import '../providers/settings_provider.dart';

/// 字体设置二级页：字体文件、字号、字重、颜色、透明度、删除线、金边字。
class FontSettingsPage extends ConsumerWidget {
  const FontSettingsPage({super.key});

  static const _presetColors = <(String, Color)>[
    ('默认', Color(0xFF1A1C1E)),
    ('白色', Colors.white),
    ('金色', Color(0xFFD4AF37)),
    ('粉色', Color(0xFFFF9EC4)),
    ('红色', Color(0xFFE57373)),
    ('绿色', Color(0xFF66BB6A)),
    ('蓝色', Color(0xFF4FC3F7)),
    ('紫色', Color(0xFFB39DDB)),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final activeTheme = ref.watch(themeProvider).active;
    final themeFont = activeTheme?.fontStyle ?? const ThemeFontConfig();
    final scheme = Theme.of(context).colorScheme;

    return GlassScaffold(
      title: '字体设置',
      subtitle: settings.fontCustomEnabled ? '已启用自定义字体' : '跟随主题包',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 44),
        children: [
          GlassCard(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用自定义字体'),
              subtitle: const Text('关闭时完全跟随当前主题包的字体排版'),
              value: settings.fontCustomEnabled,
              onChanged: (v) => notifier.update(
                settings.copyWith(fontCustomEnabled: v),
              ),
            ),
          ),
          const SizedBox(height: 8),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('字体文件',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        settings.fontFamily.isEmpty
                            ? '未选择（使用系统默认 / 主题字体）'
                            : settings.fontFamily,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () => _pickFont(context, ref),
                      child: const Text('选择字体'),
                    ),
                    if (settings.fontFamily.isNotEmpty)
                      IconButton(
                        tooltip: '清除字体',
                        onPressed: () => notifier.update(
                          settings.copyWith(fontFamily: ''),
                        ),
                        icon: const Icon(Icons.delete_outline),
                      ),
                  ],
                ),
                if (themeFont.family.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '主题包字体：${themeFont.family}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sliderRow(
                  context,
                  '字号',
                  '${settings.fontSize.round()} px',
                  settings.fontSize,
                  12,
                  30,
                  (v) => notifier.update(settings.copyWith(fontSize: v)),
                ),
                const Divider(height: 12),
                _sliderRow(
                  context,
                  '字重',
                  _weightName(settings.fontWeight),
                  settings.fontWeight,
                  100,
                  900,
                  (v) => notifier.update(
                    settings.copyWith(fontWeight: v.roundToDouble()),
                  ),
                  divisions: 8,
                ),
                const Divider(height: 12),
                _sliderRow(
                  context,
                  '透明度',
                  '${(settings.fontOpacity * 100).round()}%',
                  settings.fontOpacity,
                  0.2,
                  1,
                  (v) => notifier.update(settings.copyWith(fontOpacity: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('文字颜色',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (name, color) in _presetColors)
                      InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => notifier.update(
                          settings.copyWith(fontColor: color.toARGB32()),
                        ),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: settings.fontColor == color.toARGB32()
                                  ? scheme.primary
                                  : scheme.outlineVariant,
                              width: settings.fontColor == color.toARGB32()
                                  ? 3
                                  : 1,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              name == '默认' ? '默' : (name == '白色' ? '白' : ''),
                              style: TextStyle(
                                fontSize: 12,
                                color: _contrastOn(color),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '当前色值：#${(settings.fontColor & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          GlassCard(
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('删除线'),
                  subtitle: const Text('给全局文字加删除线效果'),
                  value: settings.fontStrikethrough,
                  onChanged: (v) => notifier.update(
                    settings.copyWith(fontStrikethrough: v),
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('金边字'),
                  subtitle: const Text('文字带金色描边/发光'),
                  value: settings.fontGoldBorder,
                  onChanged: (v) => notifier.update(
                    settings.copyWith(fontGoldBorder: v),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('预览', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Text(
                  '青龙面板 · 字体设置预览\nABCDEFG 0123456789 中文测试',
                  style: TextStyle(
                    fontSize: settings.fontSize,
                    fontWeight: _fontWeight(settings.fontWeight),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '说明：字体文件支持 .ttf / .otf；主题包可在 controller.js 的 '
            'typography 字段提供 family / size / weight / color / opacity / '
            'strikethrough / gold，AI 制作主题包时也可以带上。',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _sliderRow(
    BuildContext context,
    String label,
    String valueLabel,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    int? divisions,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 58,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            valueLabel,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  String _weightName(double w) => switch (w.round()) {
        100 => '细',
        200 => '特细',
        300 => '较细',
        400 => '常规',
        500 => '中等',
        600 => '半粗',
        700 => '粗',
        800 => '特粗',
        _ => '超粗',
      };

  FontWeight _fontWeight(double w) => switch (w.round()) {
        100 => FontWeight.w100,
        200 => FontWeight.w200,
        300 => FontWeight.w300,
        400 => FontWeight.w400,
        500 => FontWeight.w500,
        600 => FontWeight.w600,
        700 => FontWeight.w700,
        800 => FontWeight.w800,
        _ => FontWeight.w900,
      };

  Color _contrastOn(Color c) =>
      c.computeLuminance() > 0.45 ? const Color(0xFF1A1C1E) : Colors.white;

  Future<void> _pickFont(BuildContext context, WidgetRef ref) async {
    final picked = await LocalFilePicker.pickFile(context);
    if (picked == null || !context.mounted) return;
    final lower = picked.path.toLowerCase();
    if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择 .ttf 或 .otf 字体文件')),
      );
      return;
    }
    await FontLoaderService.loadUserFont(picked.path, scope: picked.scope);
    if (!context.mounted) return;
    ref.read(settingsProvider.notifier).update(
          ref.read(settingsProvider).copyWith(
                fontCustomEnabled: true,
                fontFamily: picked.path,
              ),
        );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('字体已生效')),
    );
  }
}
