import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/cache_cleaner.dart';
import '../../../core/debug/api_debug_log.dart';
import '../../../shared/glass_scaffold.dart';
import '../../../core/llm/llm_registry_provider.dart';
import '../../ai/floating/ai_dock_provider.dart';
import '../../ai/providers/chat_provider.dart';
import '../../debug/pages/api_debug_page.dart';
import '../providers/settings_provider.dart';
import 'ai_settings_page.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return GlassScaffold(
      title: '设置',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 44),
        children: [
          const SectionLabel('外观'),
          GlassCard(
            child: Row(
              children: [
                const Icon(Icons.palette_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '主题',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _themeName(settings.themeMode),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<ThemeMode>(
                  value: settings.themeMode,
                  items: const [
                    DropdownMenuItem(
                        value: ThemeMode.system, child: Text('跟随系统')),
                    DropdownMenuItem(value: ThemeMode.light, child: Text('亮色')),
                    DropdownMenuItem(value: ThemeMode.dark, child: Text('暗色')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      notifier.update(settings.copyWith(themeMode: v));
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const SectionLabel('刷新与轮询'),
          _StepperCard(
            icon: Icons.timer_outlined,
            title: '任务列表轮询间隔',
            valueLabel: '${settings.pollIntervalSeconds} 秒',
            onMinus: settings.pollIntervalSeconds > 1
                ? () => notifier.update(
                      settings.copyWith(
                        pollIntervalSeconds: settings.pollIntervalSeconds - 1,
                      ),
                    )
                : null,
            onPlus: settings.pollIntervalSeconds < 60
                ? () => notifier.update(
                      settings.copyWith(
                        pollIntervalSeconds: settings.pollIntervalSeconds + 1,
                      ),
                    )
                : null,
          ),
          const SizedBox(height: 8),
          _StepperCard(
            icon: Icons.hourglass_bottom_outlined,
            title: '日志自动刷新间隔',
            valueLabel: settings.logPollMillis % 1000 == 0
                ? '${settings.logPollMillis ~/ 1000} 秒'
                : '${(settings.logPollMillis / 1000).toStringAsFixed(1)} 秒',
            subtitle: '每次 ±0.5 秒，最快 0.2 秒；日志页会按这个间隔实时刷新',
            // 0.5 秒一档：脚本日志需要"看着像实时"，秒为单位太粗。
            onMinus: settings.logPollMillis > 200
                ? () => notifier.update(
                      settings.copyWith(
                        logPollMillis:
                            (settings.logPollMillis - 500).clamp(200, 60000),
                      ),
                    )
                : null,
            onPlus: settings.logPollMillis < 60000
                ? () => notifier.update(
                      settings.copyWith(
                        logPollMillis:
                            (settings.logPollMillis + 500).clamp(200, 60000),
                      ),
                    )
                : null,
          ),
          const SizedBox(height: 8),
          GlassCard(
            child: Row(
              children: [
                const Icon(Icons.https_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '允许自签名 HTTPS',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '默认不信任自签证书；开启后访问内网自签名面板',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: settings.allowSelfSigned,
                  onChanged: (v) =>
                      notifier.update(settings.copyWith(allowSelfSigned: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const _CacheSettingsCard(),
          const SizedBox(height: 8),
          const SectionLabel('AI'),
          Consumer(
            builder: (context, ref, _) {
              final chat = ref.watch(chatProvider);
              // 连接配置搬进"提供商"了，这里跟着看当前那家配没配。
              final registry = ref.watch(llmRegistryProvider);
              final configured = registry.active.isConfigured;
              return GlassCard(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AiSettingsPage()),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'AI 设置',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            configured
                                ? '${registry.active.label}'
                                    ' · ${chat.selectedModel.isEmpty ? "未选模型" : chat.selectedModel}'
                                    ' · ${chat.approvalMode.label}'
                                : '提供商、模型、参数、上下文、技能与 MCP',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Consumer(
            builder: (context, ref, _) {
              final dock = ref.watch(aiDockProvider);
              return GlassCard(
                child: Row(
                  children: [
                    const Icon(Icons.blur_on),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'AI 悬浮球',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          SizedBox(height: 2),
                          Text(
                            '点开聊天窗；长按伸出快问输入框（隐藏只能在这里关）',
                            style: TextStyle(fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: dock.visible,
                      onChanged: (_) =>
                          ref.read(aiDockProvider.notifier).toggleVisible(),
                    ),
                  ],
                ),
              );
            },
          ),
          const SectionLabel('终端'),
          GlassCard(
            child: Row(
              children: [
                const Icon(Icons.terminal_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '启动 APP 自动启动终端',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '仅在 Runtime 已安装时生效，不会自动下载',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: settings.autoStartTerminal,
                  onChanged: (v) =>
                      notifier.update(settings.copyWith(autoStartTerminal: v)),
                ),
              ],
            ),
          ),
          // 这条间距别删：GlassCard 不带外边距，少了它"启动 APP 自动启动终端"
          // 和"打开 APP 的首页"两张卡会贴成一整块。
          const SizedBox(height: 8),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.home_outlined),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '打开 APP 的首页',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '启动后直接落在这一页',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (index, label) in const [
                      (0, '任务'),
                      (1, '面板'),
                      (2, 'AI'),
                      (3, '终端'),
                      (4, '管理'),
                      (5, '设置'),
                    ])
                      ChoiceChip(
                        label: Text(label),
                        selected: settings.startupTabIndex == index,
                        onSelected: (_) => notifier
                            .update(settings.copyWith(startupTabIndex: index)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SectionLabel('调试'),
          GlassCard(
            child: Row(
              children: [
                const Icon(Icons.bug_report_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '调试日志',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '记录 API 请求 / 响应 / 错误，供排障使用',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: settings.debugLogEnabled,
                  onChanged: (v) {
                    ApiDebugLog.enabled = v;
                    notifier.update(settings.copyWith(debugLogEnabled: v));
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          GlassCard(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ApiDebugPage()),
            ),
            child: Row(
              children: [
                const Icon(Icons.bug_report_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'API 调试日志',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '查看最近请求 / 响应 / 错误，便于排查加载失败',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const SectionLabel('关于'),
          GlassCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '关于',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '青龙面板 Flutter 客户端 v0.1.0\n数据仅存本地，无第三方统计',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _themeName(ThemeMode mode) => switch (mode) {
        ThemeMode.system => '跟随系统',
        ThemeMode.light => '亮色',
        ThemeMode.dark => '暗色',
      };
}

/// 缓存设置：自动清理开关、保留天数、大小上限、当前占用、手动清空。
class _CacheSettingsCard extends ConsumerStatefulWidget {
  const _CacheSettingsCard();

  @override
  ConsumerState<_CacheSettingsCard> createState() => _CacheSettingsCardState();
}

class _CacheSettingsCardState extends ConsumerState<_CacheSettingsCard> {
  int? _cacheSize;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshSize();
  }

  Future<void> _refreshSize() async {
    final size = await CacheCleaner.size();
    if (mounted) setState(() => _cacheSize = size);
  }

  Future<void> _clearCache() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空缓存？'),
        content: const Text('会删除 /cache 下的所有临时文件（截图、临时图片、分享中转等），'
            '不影响 workspace、设置和用户数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final freed = await CacheCleaner.clearAll();
      await _refreshSize();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
          freed > 0 ? '已清空缓存，释放 ${_fmtBytes(freed)}' : '缓存已经是空的',
        )),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final sizeText = _cacheSize == null ? '读取中…' : _fmtBytes(_cacheSize!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('缓存'),
        GlassCard(
          child: Row(
            children: [
              const Icon(Icons.cleaning_services_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '自动清理缓存',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '启动时自动清超过保留时长的旧文件；超大小上限按旧数据优先清',
                      style: TextStyle(fontSize: 12.5, color: muted),
                    ),
                  ],
                ),
              ),
              Switch(
                value: settings.cacheCleanupEnabled,
                onChanged: (v) => notifier.update(
                  settings.copyWith(cacheCleanupEnabled: v),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _StepperCard(
          icon: Icons.calendar_today_outlined,
          title: '缓存保留时长',
          valueLabel: '${settings.cacheMaxAgeDays} 天',
          subtitle: '启动清理时，超过这个时间的缓存文件会被删除',
          onMinus: settings.cacheMaxAgeDays > 1
              ? () => notifier.update(
                    settings.copyWith(
                      cacheMaxAgeDays: settings.cacheMaxAgeDays - 1,
                    ),
                  )
              : null,
          onPlus: settings.cacheMaxAgeDays < 365
              ? () => notifier.update(
                    settings.copyWith(
                      cacheMaxAgeDays: settings.cacheMaxAgeDays + 1,
                    ),
                  )
              : null,
        ),
        const SizedBox(height: 8),
        _StepperCard(
          icon: Icons.data_usage_outlined,
          title: '缓存大小上限',
          valueLabel: '${settings.cacheMaxSizeMB} MB',
          subtitle: '超上限时最旧优先清理，直到降到约 70% 以下',
          onMinus: settings.cacheMaxSizeMB > 50
              ? () => notifier.update(
                    settings.copyWith(
                      cacheMaxSizeMB: settings.cacheMaxSizeMB - 50,
                    ),
                  )
              : null,
          onPlus: settings.cacheMaxSizeMB < 2000
              ? () => notifier.update(
                    settings.copyWith(
                      cacheMaxSizeMB: settings.cacheMaxSizeMB + 50,
                    ),
                  )
              : null,
        ),
        const SizedBox(height: 8),
        GlassCard(
          child: Row(
            children: [
              const Icon(Icons.folder_off_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '缓存占用',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sizeText,
                      style: TextStyle(fontSize: 12.5, color: muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _refreshSize,
                icon: const Icon(Icons.refresh),
              ),
              TextButton(
                onPressed: _busy ? null : _clearCache,
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('清空缓存'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}

/// 带 −/+ 两个按钮的数值卡片。
///
/// 之前只有一个「+」，加到上限就跳回 1，想调小得点一圈——这里补齐减号，
/// 到边界就把对应按钮置灰。
class _StepperCard extends StatelessWidget {
  const _StepperCard({
    required this.icon,
    required this.title,
    required this.valueLabel,
    this.subtitle,
    this.onMinus,
    this.onPlus,
  });

  final IconData icon;
  final String title;
  final String valueLabel;
  final String? subtitle;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return GlassCard(
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  valueLabel,
                  style: TextStyle(fontSize: 12.5, color: muted),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: TextStyle(fontSize: 11.5, color: muted),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: '减少',
            onPressed: onMinus,
            icon: const Icon(Icons.remove),
          ),
          IconButton(
            tooltip: '增加',
            onPressed: onPlus,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
