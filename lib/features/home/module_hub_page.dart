import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/glass.dart';
import '../../shared/glass_scaffold.dart';
import '../ai/mcp/mcp_provider.dart';
import '../ai/memory/memory_provider.dart';
import '../ai/pages/mcp_server_page.dart';
import '../ai/pages/memory_page.dart';
import '../ai/pages/skill_list_page.dart';
import '../ai/skills/skill_provider.dart';
import '../configs/pages/config_list_page.dart';
import '../dependencies/pages/dependency_list_page.dart';
import '../envs/pages/env_list_page.dart';
import '../logs/pages/log_center_page.dart';
import '../panels/providers/panel_list_provider.dart';
import '../scripts/pages/script_list_page.dart';
import '../subscriptions/pages/subscription_list_page.dart';
import '../system/pages/system_page.dart';

/// 管理页：面板资源与 AI 扩展的总入口。
///
/// 旧版是两排一样大的灰方格，每格一个图标加两行字——信息密度低、六个格子长得
/// 一模一样，滑到底只记得"有六个块"。现在按"这是什么东西"分层：
/// 顶部先说清在管哪个面板（改错面板代价很高）；面板资源是常去的地方，
/// 用带色横条列出来；AI 扩展是三块能力，一排三张竖卡，右边/下面直接给实时数量。
class ModuleHubPage extends ConsumerWidget {
  const ModuleHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final panel = ref.watch(currentPanelProvider);
    final skills = ref.watch(skillProvider);
    final mcp = ref.watch(mcpProvider);
    final memory = ref.watch(memoryProvider);

    const panelModules = <_Module>[
      _Module(
        '脚本管理',
        '看 / 改 / 新建脚本文件',
        Icons.description_outlined,
        Color(0xFF3FA97B),
      ),
      _Module(
        '订阅管理',
        '拉仓库脚本，自动建任务',
        Icons.cloud_download_outlined,
        Color(0xFF7E8FE0),
      ),
      _Module(
        '环境变量',
        'cookie、token 都在这',
        Icons.key_outlined,
        Color(0xFFCE9A2E),
      ),
      _Module(
        '配置管理',
        'config.sh 等配置文件',
        Icons.settings_suggest_outlined,
        Color(0xFF4C8EDA),
      ),
      _Module(
        '依赖管理',
        'npm / pip 包',
        Icons.inventory_2_outlined,
        Color(0xFF9A6FD8),
      ),
      _Module(
        '日志中心',
        '按目录翻历史日志',
        Icons.receipt_long_outlined,
        Color(0xFF57A8B8),
      ),
      _Module(
        '系统管理',
        '版本与面板更新',
        Icons.hub_outlined,
        Color(0xFFD1725B),
      ),
    ];
    final aiModules = <_Module>[
      _Module(
        '技能库',
        '给 AI 装操作手册',
        Icons.auto_stories_outlined,
        const Color(0xFF3FA97B),
        badge: skills.skills.isEmpty
            ? null
            : '${skills.enabled.length}/${skills.skills.length} 启用',
      ),
      _Module(
        'MCP 扩展',
        '接入外部工具服务器',
        Icons.extension_outlined,
        const Color(0xFF4C8EDA),
        badge: mcp.tools.isEmpty ? null : '${mcp.tools.length} 个工具',
      ),
      _Module(
        'AI 记忆',
        '看 / 改 AI 记住的结论',
        Icons.psychology_outlined,
        const Color(0xFF9A6FD8),
        badge: memory.items.isEmpty ? null : '${memory.items.length} 条',
      ),
    ];

    return GlassScaffold(
      title: '管理',
      subtitle: '面板资源与 AI 扩展',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 54),
        children: [
          _CurrentPanelCard(
            name: panel?.name ?? '未选择面板',
            url: panel?.baseUrl ?? '到「面板」页添加一个',
            online: panel != null,
          ),
          const SectionLabel('面板资源'),
          for (final m in panelModules)
            _ModuleRow(module: m, onTap: () => _open(context, m.title)),
          SectionLabel(
            'AI 扩展',
            trailing: Text(
              mcp.servers.isEmpty ? '未接入 MCP' : '${mcp.servers.length} 个 MCP 服务器',
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
          // IntrinsicHeight 而不是 crossAxisAlignment.stretch：
          // 这一行在 ListView 里，纵向约束是无限的，stretch 会直接抛
          // "BoxConstraints forces an infinite height" 把整页打黑。
          // IntrinsicHeight 先量出最高的那张卡，再让三张一样高。
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < aiModules.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(
                    child: _ModuleCard(
                      module: aiModules[i],
                      onTap: () => _open(context, aiModules[i].title),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _open(BuildContext context, String title) {
    final builder = switch (title) {
      '脚本管理' => (BuildContext _) => const ScriptListPage(),
      '订阅管理' => (BuildContext _) => const SubscriptionListPage(),
      '环境变量' => (BuildContext _) => const EnvListPage(),
      '配置管理' => (BuildContext _) => const ConfigListPage(),
      '依赖管理' => (BuildContext _) => const DependencyListPage(),
      '日志中心' => (BuildContext _) => const LogCenterPage(),
      '系统管理' => (BuildContext _) => const SystemPage(),
      '技能库' => (BuildContext _) => const SkillListPage(),
      'MCP 扩展' => (BuildContext _) => const McpServerPage(),
      'AI 记忆' => (BuildContext _) => const MemoryPage(),
      _ => null,
    };
    if (builder == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: builder));
  }
}

class _Module {
  const _Module(
    this.title,
    this.subtitle,
    this.icon,
    this.accent, {
    this.badge,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;

  /// 右侧/底部的实时小字（数量等）。没有就不占位。
  final String? badge;
}

/// 顶部当前面板卡：管理页里所有面板资源都是对"这个面板"操作的，
/// 不写清楚是哪个，改错面板的代价很高。
class _CurrentPanelCard extends StatelessWidget {
  const _CurrentPanelCard({
    required this.name,
    required this.url,
    required this.online,
  });

  final String name;
  final String url;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassPanel(
      radius: 22,
      shadowY: 6,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary.withValues(alpha: 0.85),
                  scheme.tertiary.withValues(alpha: 0.7),
                ],
              ),
            ),
            child:
                const Icon(Icons.dns_outlined, size: 21, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: (online ? scheme.primary : scheme.error)
                  .withValues(alpha: 0.13),
            ),
            child: Text(
              online ? '当前面板' : '未配置',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: online ? scheme.primary : scheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板资源的横条：左侧彩色图标、中间两行字、右侧数量与箭头。
class _ModuleRow extends StatelessWidget {
  const _ModuleRow({required this.module, required this.onTap});

  final _Module module;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassPanel(
        radius: 18,
        blur: 14,
        shadowY: 3,
        opacity: 0.9,
        padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: module.accent.withValues(alpha: 0.16),
                border: Border.all(
                  color: module.accent.withValues(alpha: 0.32),
                ),
              ),
              child: Icon(module.icon, size: 18, color: module.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    module.title,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    module.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (module.badge != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  module.badge!,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: module.accent,
                  ),
                ),
              ),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
          ],
        ),
      ),
    );
  }
}

/// AI 扩展的竖卡：一排三个，图标在上、标题在中、实时数量在下。
class _ModuleCard extends StatelessWidget {
  const _ModuleCard({required this.module, required this.onTap});

  final _Module module;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassPanel(
      radius: 20,
      blur: 14,
      shadowY: 4,
      padding: const EdgeInsets.fromLTRB(11, 13, 11, 12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  module.accent.withValues(alpha: 0.9),
                  module.accent.withValues(alpha: 0.55),
                ],
              ),
            ),
            child: Icon(module.icon, size: 18, color: Colors.white),
          ),
          const SizedBox(height: 10),
          Text(
            module.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            module.badge ?? module.subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 1.25,
              fontWeight: module.badge == null ? null : FontWeight.w600,
              color: module.badge == null
                  ? scheme.onSurfaceVariant
                  : module.accent,
            ),
          ),
        ],
      ),
    );
  }
}
