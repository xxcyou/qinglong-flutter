import 'package:flutter/material.dart';

import '../../../core/local_shell/proot_bridge.dart';
import '../../../core/theme/glass.dart';
import '../../../core/utils/formatter.dart';
import '../../../shared/file_kinds.dart';

/// 长按文件/文件夹弹出的操作菜单（MT 管理器那种）。
///
/// 为什么不用 PopupMenuButton：那个要点右边那个小三角，手指粗一点就点到别的行；
/// MT 的做法是长按整行弹一张底部卡，标题就是这个文件本身，操作按钮排成网格，
/// 一眼能看完、随便点得到。
class FileActionSheet extends StatelessWidget {
  const FileActionSheet({
    super.key,
    required this.entry,
    required this.kind,
    required this.onAction,
    required this.canPaste,
  });

  final ShellFileEntry entry;
  final FileKind kind;
  final ValueChanged<String> onAction;

  /// 剪贴板里有东西时，目录上多给一个"粘贴到这里"。
  final bool canPaste;

  static Future<void> show(
    BuildContext context, {
    required ShellFileEntry entry,
    required FileKind kind,
    required ValueChanged<String> onAction,
    bool canPaste = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => FileActionSheet(
        entry: entry,
        kind: kind,
        onAction: onAction,
        canPaste: canPaste,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    void act(String action) {
      Navigator.of(context).pop();
      onAction(action);
    }

    final actions = <_Action>[
      if (entry.isDirectory)
        const _Action('open', '打开', Icons.folder_open_rounded)
      else if (kind.needsExternalApp)
        const _Action('external', '用其它 APP', Icons.open_in_new_rounded)
      else
        const _Action('open', '打开', Icons.open_in_new_rounded),
      const _Action('select', '多选', Icons.check_circle_outline_rounded),
      const _Action('rename', '重命名', Icons.drive_file_rename_outline_rounded),
      const _Action('copy', '复制', Icons.copy_rounded),
      const _Action('cut', '剪切', Icons.content_cut_rounded),
      if (canPaste && entry.isDirectory)
        const _Action('pasteInto', '粘贴进去', Icons.content_paste_go_rounded),
      if (!entry.isDirectory)
        const _Action('share', '分享', Icons.ios_share_rounded),
      const _Action('permissions', '权限', Icons.lock_outline_rounded),
      const _Action('info', '属性', Icons.info_outline_rounded),
      const _Action('copyPath', '复制路径', Icons.link_rounded),
      if (!entry.isDirectory && kind.isTextLike)
        const _Action('askAi', '问 AI', Icons.smart_toy_outlined),
      const _Action('delete', '删除', Icons.delete_outline_rounded, danger: true),
    ];

    return GlassPanel(
      radius: 22,
      blur: Glass.blurStrong,
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: kind.color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(kind.icon, color: kind.color, size: 22),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        [
                          kind.label,
                          if (!entry.isDirectory)
                            FileKinds.sizeText(entry.size),
                          Formatter.dateTime(entry.modified),
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            // 网格：一行 4 个，够大不误触。
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 4,
              childAspectRatio: 0.92,
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                for (final action in actions)
                  _ActionButton(action: action, onTap: () => act(action.id)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Action {
  const _Action(this.id, this.label, this.icon, {this.danger = false});

  final String id;
  final String label;
  final IconData icon;
  final bool danger;
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action, required this.onTap});

  final _Action action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = action.danger ? scheme.error : scheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(action.icon, size: 22, color: color),
          const SizedBox(height: 5),
          Text(
            action.label,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: color),
          ),
        ],
      ),
    );
  }
}
