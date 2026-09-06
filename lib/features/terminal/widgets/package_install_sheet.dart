import 'package:flutter/material.dart';
import '../../../shared/mono_text.dart';

/// 装包面板：把 `apt-get install` 这类命令包装成点选。
///
/// 「终端支持安装软件包」——底层能力本来就有（rootfs 里带 apt），
/// 缺的是别让用户去记 `DEBIAN_FRONTEND=noninteractive apt-get -y install`
/// 这一长串。选好之后命令直接写进 pty，输出仍然在终端里滚，
/// 装没装成、报什么错都看得见。
class PackageInstallSheet extends StatefulWidget {
  const PackageInstallSheet({super.key, required this.onRun});

  /// 把整条命令（含结尾回车）写进 pty。
  final ValueChanged<String> onRun;

  static Future<void> show(BuildContext context, ValueChanged<String> onRun) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => PackageInstallSheet(onRun: onRun),
    );
  }

  @override
  State<PackageInstallSheet> createState() => _PackageInstallSheetState();
}

class _PackageInstallSheetState extends State<PackageInstallSheet> {
  final _controller = TextEditingController();
  final _selected = <String>{};

  /// 常用包：按"跑青龙脚本会缺什么"排的。
  static const _presets = <String, List<String>>{
    '基础工具': [
      'curl',
      'wget',
      'git',
      'unzip',
      'vim',
      'nano',
      'htop',
      'jq',
      'tree'
    ],
    'Python': ['python3-pip', 'python3-venv', 'python3-dev'],
    'Node 生态': ['nodejs', 'npm'],
    '构建/编译': ['build-essential', 'gcc', 'make', 'pkg-config'],
    '网络排查': ['iputils-ping', 'dnsutils', 'net-tools', 'openssh-client'],
    '常见依赖': ['ca-certificates', 'libssl-dev', 'zlib1g-dev', 'tzdata'],
  };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<String> get _packages {
    final extra = _controller.text
        .split(RegExp(r'[\s,]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    return {..._selected, ...extra}.toList();
  }

  void _run(String command) {
    widget.onRun('$command\r');
    Navigator.of(context).pop();
  }

  void _install() {
    final packages = _packages;
    if (packages.isEmpty) return;
    final list = packages.join(' ');
    // 两件事必须一起做，缺一个就会踩坑：
    //
    // 1) noninteractive + -y：手机上没法回答 apt 的交互式提问。
    // 2) **索引空了要自动 update**。刚装好的 rootfs 里
    //    /var/lib/apt/lists 是空的（打包时清掉了，否则镜像大一截），
    //    这时 apt 只认 dpkg 已装的那些包，装 wget/unzip 一律回
    //    "E: Unable to locate package"——而 curl 因为本来就装着，
    //    看起来"部分成功"，特别容易误判成源坏了。
    //    所以：先直接装，失败就 update 再装一次。这样索引新鲜时不多花
    //    十几秒，索引空/过期时也能自己救回来。
    _run(
      'DEBIAN_FRONTEND=noninteractive apt-get install -y $list '
      '|| { apt-get update && DEBIAN_FRONTEND=noninteractive '
      'apt-get install -y $list; }',
    );
  }

  @override
  Widget build(BuildContext context) {
    final packages = _packages;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, controller) => SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.inventory_2_outlined, size: 19),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '安装软件包',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '第一次装包前先更新索引；命令会写进终端，输出实时可见。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _run('apt-get update'),
                        icon: const Icon(Icons.sync, size: 17),
                        label: const Text('更新索引'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _run(
                          'DEBIAN_FRONTEND=noninteractive apt-get upgrade -y',
                        ),
                        icon: const Icon(Icons.upgrade, size: 17),
                        label: const Text('升级全部'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () =>
                            _run('apt list --installed | head -50'),
                        icon: const Icon(Icons.list_alt, size: 17),
                        label: const Text('已装列表'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  for (final group in _presets.entries) ...[
                    Text(
                      group.key,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final pkg in group.value)
                          FilterChip(
                            label: Text(pkg),
                            selected: _selected.contains(pkg),
                            onSelected: (on) => setState(() {
                              if (on) {
                                _selected.add(pkg);
                              } else {
                                _selected.remove(pkg);
                              }
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _controller,
                    style: const TextStyle(
                        fontFamily: kMonoFamily,
                        fontFamilyFallback: kMonoFallback,
                        fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '其他包名（空格或逗号分隔）',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      packages.isEmpty
                          ? '还没选包'
                          : '将安装 ${packages.length} 个：${packages.join(' ')}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: packages.isEmpty ? null : _install,
                    icon: const Icon(Icons.download),
                    label: const Text('安装'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
