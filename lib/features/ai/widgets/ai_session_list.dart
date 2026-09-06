import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/chat_provider.dart';

/// 会话管理列表：AI 页的底部弹窗和悬浮窗的内嵌面板共用这一份。
///
/// 为什么必须共用：悬浮窗里也要能换会话——「每次都切到 AI 页再点会话管理」
/// 本身就是要解决的问题。两处各写一份的话，删除确认、时间格式、空态、
/// 改名规则迟早会长成两个样子，用户在两个地方看到的同一件事就不一样了。
class AiSessionList extends ConsumerStatefulWidget {
  const AiSessionList({
    super.key,
    this.dense = false,
    this.scroll,
    this.onLeave,
    this.onClose,
  });

  /// 紧凑排版：悬浮窗只有三四行的高度，行高、字号都要收一档。
  final bool dense;

  /// 外层滚动控制器（[DraggableScrollableSheet] 需要接过去才能下拉关闭）。
  final ScrollController? scroll;

  /// 切了会话 / 新建了会话之后调用：弹窗里是 pop，悬浮窗里是收起这一层。
  final VoidCallback? onLeave;

  /// 右上角关闭按钮。给 null 就不画（弹窗靠下拉关，不需要）。
  final VoidCallback? onClose;

  /// AI 页用的底部弹窗形态。
  static Future<void> showSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scroll) => AiSessionList(
          scroll: scroll,
          onLeave: () => Navigator.of(sheetContext).pop(),
        ),
      ),
    );
  }

  @override
  ConsumerState<AiSessionList> createState() => _AiSessionListState();
}

class _AiSessionListState extends ConsumerState<AiSessionList> {
  /// 待确认删除的会话 id。删会话不可逆，悬浮窗里行高又小，
  /// 一下点掉整段历史太容易——第一下变成「再点一次」，第二下才真删。
  String? _pendingDelete;

  /// 正在就地改名的会话 id。悬浮层在 Navigator 之外，弹不出输入对话框
  /// （弹出来会跑到悬浮窗底下去），所以改名做成这一行原地变输入框。
  String? _renaming;
  final _renameInput = TextEditingController();

  @override
  void dispose() {
    _renameInput.dispose();
    super.dispose();
  }

  void _submitRename(String id) {
    final text = _renameInput.text.trim();
    if (text.isNotEmpty) {
      ref.read(chatProvider.notifier).renameSession(id, text);
    }
    setState(() => _renaming = null);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(chatProvider);
    final notifier = ref.read(chatProvider.notifier);
    final dense = widget.dense;
    final sessions = state.sessions;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            dense ? 12 : 16,
            dense ? 6 : 16,
            4,
            dense ? 0 : 4,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '会话 · ${sessions.length}',
                  style: TextStyle(
                    fontSize: dense ? 13 : 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                tooltip: '新建会话',
                visualDensity: VisualDensity.compact,
                constraints: dense
                    ? const BoxConstraints(minWidth: 32, minHeight: 32)
                    : null,
                onPressed: () {
                  notifier.createSession();
                  widget.onLeave?.call();
                },
                icon: Icon(
                  Icons.add_comment_outlined,
                  size: dense ? 18 : 22,
                ),
              ),
              if (widget.onClose != null)
                IconButton(
                  tooltip: '回到对话',
                  visualDensity: VisualDensity.compact,
                  constraints: dense
                      ? const BoxConstraints(minWidth: 32, minHeight: 32)
                      : null,
                  onPressed: widget.onClose,
                  icon: Icon(Icons.close, size: dense ? 18 : 22),
                ),
            ],
          ),
        ),
        Expanded(
          child: sessions.isEmpty
              ? const Center(child: Text('还没有会话'))
              : ListView.builder(
                  controller: widget.scroll,
                  itemCount: sessions.length,
                  padding: EdgeInsets.fromLTRB(
                    dense ? 8 : 12,
                    0,
                    dense ? 8 : 12,
                    dense ? 8 : 24,
                  ),
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    final current = session.id == state.currentSessionId;
                    final pending = _pendingDelete == session.id;
                    // 正在跑的会话不能删：请求还挂在它身上，删了工具回调会
                    // 落到一个已经不存在的会话里。
                    final locked = current && state.isLoading;
                    if (_renaming == session.id) {
                      return _renameRow(session.id, dense, scheme);
                    }
                    return Card(
                      margin: EdgeInsets.symmetric(vertical: dense ? 3 : 4),
                      color: current ? scheme.primaryContainer : null,
                      child: ListTile(
                        dense: dense,
                        visualDensity: dense
                            ? VisualDensity.compact
                            : VisualDensity.standard,
                        contentPadding: EdgeInsets.fromLTRB(
                          dense ? 10 : 16,
                          0,
                          dense ? 2 : 8,
                          0,
                        ),
                        title: Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: dense ? 12.5 : 15,
                            fontWeight:
                                current ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                        subtitle: Text(
                          '${session.messages.length} 条 · ${_stamp(session.updatedAt)}'
                          '${locked ? ' · 执行中' : ''}',
                          style: TextStyle(fontSize: dense ? 10.5 : 13),
                        ),
                        onTap: () {
                          notifier.selectSession(session.id);
                          widget.onLeave?.call();
                        },
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '改名',
                              visualDensity: VisualDensity.compact,
                              constraints: BoxConstraints(
                                minWidth: dense ? 30 : 40,
                                minHeight: dense ? 30 : 40,
                              ),
                              padding: EdgeInsets.zero,
                              onPressed: () {
                                _renameInput.text = session.title;
                                setState(() {
                                  _renaming = session.id;
                                  _pendingDelete = null;
                                });
                              },
                              icon: Icon(
                                Icons.drive_file_rename_outline,
                                size: dense ? 16 : 20,
                              ),
                            ),
                            IconButton(
                              tooltip: locked
                                  ? '执行中，先停下再删'
                                  : (pending ? '再点一次确认删除' : '删除会话'),
                              visualDensity: VisualDensity.compact,
                              constraints: BoxConstraints(
                                minWidth: dense ? 30 : 40,
                                minHeight: dense ? 30 : 40,
                              ),
                              padding: EdgeInsets.zero,
                              onPressed: locked
                                  ? null
                                  : () {
                                      if (!pending) {
                                        setState(
                                          () => _pendingDelete = session.id,
                                        );
                                        return;
                                      }
                                      setState(() => _pendingDelete = null);
                                      notifier.deleteSession(session.id);
                                    },
                              icon: Icon(
                                pending
                                    ? Icons.delete_forever
                                    : Icons.delete_outline,
                                size: dense ? 16 : 20,
                                color: pending ? scheme.error : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _renameRow(String id, bool dense, ColorScheme scheme) {
    return Card(
      margin: EdgeInsets.symmetric(vertical: dense ? 3 : 4),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: EdgeInsets.fromLTRB(dense ? 10 : 16, 2, 4, 2),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _renameInput,
                autofocus: true,
                style: TextStyle(fontSize: dense ? 12.5 : 15),
                decoration: const InputDecoration(
                  isDense: true,
                  // filled: false 是必须的：主题给输入框上了玻璃填充，
                  // 这里已经在一张卡里了，再填一层就是"框里套框"。
                  filled: false,
                  border: InputBorder.none,
                  hintText: '会话名字',
                ),
                onSubmitted: (_) => _submitRename(id),
              ),
            ),
            IconButton(
              tooltip: '取消',
              visualDensity: VisualDensity.compact,
              constraints: BoxConstraints(
                minWidth: dense ? 30 : 40,
                minHeight: dense ? 30 : 40,
              ),
              padding: EdgeInsets.zero,
              onPressed: () => setState(() => _renaming = null),
              icon: Icon(Icons.close, size: dense ? 16 : 20),
            ),
            IconButton(
              tooltip: '保存名字',
              visualDensity: VisualDensity.compact,
              constraints: BoxConstraints(
                minWidth: dense ? 30 : 40,
                minHeight: dense ? 30 : 40,
              ),
              padding: EdgeInsets.zero,
              onPressed: () => _submitRename(id),
              icon: Icon(
                Icons.check,
                size: dense ? 16 : 20,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.month}-${t.day} ${two(t.hour)}:${two(t.minute)}';
  }
}
