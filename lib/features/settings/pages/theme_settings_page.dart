import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/theme_config.dart';
import '../../../core/theme/theme_store.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../shared/local_file_picker.dart';
import '../widgets/theme_menu_window.dart';

/// 主题方案二级页：主题包应用 / 导入 / 导出 / 删除 / 主题菜单。
class ThemeSettingsPage extends ConsumerStatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  ConsumerState<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends ConsumerState<ThemeSettingsPage> {
  Future<void> _importZip() async {
    final picked = await LocalFilePicker.pickZip(context);
    if (picked == null || !mounted) return;
    try {
      final theme =
          await ref.read(themeProvider.notifier).importZip(picked.path);
      await ref.read(themeProvider.notifier).apply(theme.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 ZIP 主题：${theme.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ZIP 导入失败：$e')),
      );
    }
  }

  Future<void> _exportZip(ThemeConfig theme) async {
    try {
      final path = await ref.read(themeProvider.notifier).exportZip(theme.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出 ZIP：$path')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ZIP 导出失败：$e')),
      );
    }
  }

  Future<void> _deleteTheme(ThemeConfig theme) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除主题包'),
        content: Text('确定删除“${theme.name}”吗？删除后主题包目录会被移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(themeProvider.notifier).remove(theme.id);
  }

  Future<void> _openThemeMenu(ThemeConfig theme) async {
    final notifier = ref.read(themeProvider.notifier);
    final hasMenu = await notifier.hasThemeMenu(theme.id);
    if (!hasMenu || !mounted) return;
    showThemeMenuWindow(
      context,
      theme: theme,
      readConfig: () => notifier.readMenuConfig(theme.id),
      saveConfig: (config) => notifier.saveMenuConfig(theme.id, config),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(themeProvider);
    final notifier = ref.read(themeProvider.notifier);
    return GlassScaffold(
      title: '主题方案',
      actions: [
        TextButton.icon(
          onPressed: _importZip,
          icon: const Icon(Icons.file_open_outlined, size: 16),
          label: const Text('导入 ZIP'),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
        children: [
          for (final theme in state.themes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassCard(
                onTap: () => notifier.apply(theme.id),
                onLongPress: () => _openThemeMenu(theme),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: _ThemePreview(theme: theme),
                  title: Text(
                    theme.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  subtitle: Text(
                    '${theme.id} · ${theme.isDark ? '暗色' : '亮色'}'
                    '${theme.backgroundImage.isEmpty ? ' · 纯配色' : ' · 背景图'}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (state.activeId == theme.id)
                        const Icon(Icons.check_circle, color: Colors.green)
                      else
                        IconButton(
                          tooltip: '应用',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => notifier.apply(theme.id),
                          icon: const Icon(Icons.check_circle_outline),
                        ),
                      IconButton(
                        tooltip: '导出 ZIP',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _exportZip(theme),
                        icon: const Icon(Icons.archive_outlined),
                      ),
                      IconButton(
                        tooltip: '删除',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _deleteTheme(theme),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 4),
          GlassCard(
            child: Text(
              '主题包目录：/workspace/.ql_themes/packages（导入导出均为 ZIP）',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.theme});

  final ThemeConfig theme;

  @override
  Widget build(BuildContext context) {
    final primary = theme.color('primary', const Color(0xFF66BB6A));
    final accent = theme.color('accent', const Color(0xFF4FC3F7));
    final surface = theme.color('surface', const Color(0xFF1A1D24));
    final onSurface = theme.color('onSurface', const Color(0xFFE8EAED));
    final background = theme.color('background', const Color(0xFF0F1115));
    final radius = BorderRadius.circular(8);
    return Container(
      width: 56,
      height: 34,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [background, surface, primary.withValues(alpha: 0.55)],
        ),
        border: Border.all(
          color: theme.color('border', Colors.white).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _dot(primary),
          _dot(accent),
          _dot(onSurface),
        ],
      ),
    );
  }

  Widget _dot(Color color) => Container(
        width: 8,
        height: 8,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}