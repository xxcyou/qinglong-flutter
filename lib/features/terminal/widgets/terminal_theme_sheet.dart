import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/glass.dart';
import '../../../shared/glass_scaffold.dart';
import '../../settings/providers/settings_provider.dart';
import '../terminal_palettes.dart';
import '../../../shared/mono_text.dart';

/// 终端外观面板：换配色、调字号行高、开关命令高亮。
///
/// 为什么单独一个面板而不是塞进设置页：换配色是"看着效果调"的事，
/// 必须在终端页当场看到变化。这里每选一下就立刻落到设置里，终端实时重绘。
class TerminalThemeSheet extends ConsumerWidget {
  const TerminalThemeSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const TerminalThemeSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return GlassPanel(
      radius: 22,
      blur: Glass.blurStrong,
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.palette_outlined, size: 18, color: scheme.primary),
                  const SizedBox(width: 6),
                  const Text(
                    '终端外观',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const SectionLabel('配色方案'),
              const SizedBox(height: 6),
              for (final palette in TerminalPalette.all)
                _PaletteRow(
                  palette: palette,
                  selected: palette.id == settings.terminalPalette,
                  onTap: () => notifier.update(
                    settings.copyWith(terminalPalette: palette.id),
                  ),
                ),
              const SizedBox(height: 12),
              const SectionLabel('字号'),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: settings.terminalFontSize.clamp(9, 22),
                      min: 9,
                      max: 22,
                      divisions: 26,
                      label: settings.terminalFontSize.toStringAsFixed(1),
                      onChanged: (value) => notifier.update(
                        settings.copyWith(terminalFontSize: value),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      settings.terminalFontSize.toStringAsFixed(1),
                      style: const TextStyle(
                        fontFamily: kMonoFamily,
                        fontFamilyFallback: ['monospace'],
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SectionLabel('行高'),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: settings.terminalLineHeight.clamp(1.0, 1.8),
                      min: 1.0,
                      max: 1.8,
                      divisions: 16,
                      label: settings.terminalLineHeight.toStringAsFixed(2),
                      onChanged: (value) => notifier.update(
                        settings.copyWith(terminalLineHeight: value),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      settings.terminalLineHeight.toStringAsFixed(2),
                      style: const TextStyle(
                        fontFamily: kMonoFamily,
                        fontFamilyFallback: ['monospace'],
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: settings.terminalCommandHighlight,
                onChanged: (value) => notifier.update(
                  settings.copyWith(terminalCommandHighlight: value),
                ),
                title: const Text('命令语法高亮', style: TextStyle(fontSize: 13.5)),
                subtitle: const Text(
                  '底部输入框里给命令、参数、路径、变量上色',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
              const SizedBox(height: 4),
              // 预览：直接按选中的配色画一小段假输出，选之前就知道长什么样。
              _Preview(
                palette: TerminalPalette.byId(settings.terminalPalette),
                fontSize: settings.terminalFontSize,
                lineHeight: settings.terminalLineHeight,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final TerminalPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = palette.theme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected
              ? scheme.primary.withValues(alpha: 0.13)
              : Colors.transparent,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 1.4 : 0.8,
          ),
        ),
        child: Row(
          children: [
            // 色板：底色 + 6 个最常用的槽位，一眼看出风格。
            Container(
              width: 46,
              height: 30,
              decoration: BoxDecoration(
                color: theme.background,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: scheme.outlineVariant, width: 0.6),
              ),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Wrap(
                  spacing: 2,
                  runSpacing: 2,
                  children: [
                    for (final c in [
                      theme.red,
                      theme.green,
                      theme.yellow,
                      theme.blue,
                      theme.magenta,
                      theme.cyan,
                    ])
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: c,
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    palette.name,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    palette.description,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, size: 18, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.palette,
    required this.fontSize,
    required this.lineHeight,
  });

  final TerminalPalette palette;
  final double fontSize;
  final double lineHeight;

  @override
  Widget build(BuildContext context) {
    final t = palette.theme;
    TextStyle s(Color color, {bool bold = false}) => TextStyle(
          fontFamily: kMonoFamily,
          fontFamilyFallback: kMonoFallback,
          fontSize: fontSize,
          height: lineHeight,
          color: color,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        color: t.background,
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'coomi', style: s(t.brightGreen, bold: true)),
                  TextSpan(text: '@', style: s(t.foreground)),
                  TextSpan(text: 'debian', style: s(t.brightCyan, bold: true)),
                  TextSpan(text: ':', style: s(t.foreground)),
                  TextSpan(
                      text: '/workspace', style: s(t.brightBlue, bold: true)),
                  TextSpan(text: r'$ ', style: s(t.foreground)),
                  TextSpan(text: 'ls -alh', style: s(t.brightYellow)),
                ],
              ),
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'drwxr-xr-x  ', style: s(t.brightBlack)),
                  TextSpan(text: 'scripts/', style: s(t.blue, bold: true)),
                ],
              ),
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '-rwxr-xr-x  ', style: s(t.brightBlack)),
                  TextSpan(text: 'run.sh', style: s(t.green)),
                ],
              ),
            ),
            Text('error: connect ECONNREFUSED', style: s(t.brightRed)),
            Text('warn: retry in 3s', style: s(t.yellow)),
          ],
        ),
      ),
    );
  }
}
