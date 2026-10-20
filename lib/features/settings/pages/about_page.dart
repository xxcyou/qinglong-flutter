import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/glass_scaffold.dart';

/// 关于页：版本、项目说明和 GitHub 开源地址。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const String githubUrl = 'https://github.com/xxcyou/qinglong-flutter';
  static const String githubLabel = 'github.com/xxcyou/qinglong-flutter';

  static Future<void> openGithub(BuildContext context) async {
    final uri = Uri.parse(githubUrl);
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened && context.mounted) {
      await Clipboard.setData(const ClipboardData(text: githubUrl));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开浏览器，开源地址已复制到剪贴板')),
        );
      }
    }
  }

  static Future<void> copyGithub(BuildContext context) async {
    await Clipboard.setData(const ClipboardData(text: githubUrl));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('开源地址已复制')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassScaffold(
      title: '关于',
      showBack: true,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 44),
        children: [
          GlassCard(
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        scheme.primary,
                        scheme.tertiary,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    size: 32,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '青龙AI',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snapshot) {
                    final info = snapshot.data;
                    final version = info == null
                        ? 'v1.0.0'
                        : 'v${info.version}+${info.buildNumber}';
                    return Text(
                      version,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                Text(
                  '青龙面板移动客户端，内置浏览器抓包、终端与 AI 助手。\n'
                  '数据仅存本地，无第三方统计。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const SectionLabel('开源地址'),
          GlassCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.code_rounded),
              title: const Text(
                'GitHub',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(githubLabel),
              trailing: IconButton(
                tooltip: '复制',
                icon: const Icon(Icons.copy_rounded, size: 20),
                onPressed: () => copyGithub(context),
              ),
              onTap: () => openGithub(context),
            ),
          ),
          const SizedBox(height: 8),
          GlassCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined),
              title: const Text(
                '开源说明',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                '项目源码公开在 GitHub，欢迎提交 Issue 或 Pull Request。',
              ),
              trailing: const Icon(Icons.open_in_new_rounded, size: 18),
              onTap: () => openGithub(context),
            ),
          ),
        ],
      ),
    );
  }
}
