import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/local_shell/proot_bridge.dart';
import '../features/ai/models/ai_message.dart';
import '../core/theme/glass.dart';
import '../core/utils/formatter.dart';
import 'file_kinds.dart';
import 'mono_text.dart';

/// 选中的本地文件（已读好正文，可直接当附件用）。
class PickedLocalFile {
  const PickedLocalFile({
    required this.path,
    required this.name,
    required this.content,
    required this.size,
    required this.truncated,
    this.language,
    this.scope = 'shell',
    this.mime = '',
  });

  final String path;
  final String name;

  /// 文件正文（超限已截断，见 [truncated]）。图片类附件不读正文，为空。
  final String content;
  final int size;
  final bool truncated;

  /// 代码高亮语言名，供附件块标注 fence。
  final String? language;

  /// 文件在哪一侧：shell（终端）或 app（APP 沙箱）。
  final String scope;

  /// MIME 类型（图片附件要用，文本附件可为空）。
  final String mime;
}

enum LocalFilePickerMode {
  /// 挑一个能当附件的文本/图片文件。
  attachment,

  /// 挑任意文件（只返回路径，不读内容），用于导入 ZIP 等场景。
  anyFile,
}

/// 本地文件选择器：给 AI 加附件用。

/// 把图片选择结果转成聊天用的 [AiImageAttachment]。
///
/// 图片不走「读文本」那条路：这里通过宿主路径读原始字节，编码成 data URI，
/// 既给模型识别用，也给气泡/悬浮窗展示用。
Future<AiImageAttachment?> readPickedImage(PickedLocalFile picked) async {
  if (!picked.mime.toLowerCase().startsWith('image/')) return null;
  try {
    final bridge = ProotBridge();
    final host = await bridge.hostPath(
      path: picked.path,
      scope: picked.scope,
    );
    final bytes = await File(host).readAsBytes();
    if (bytes.isEmpty) return null;
    return AiImageAttachment(
      name: picked.name,
      mime: picked.mime,
      dataUri: 'data:${picked.mime};base64,${base64Encode(bytes)}',
      path: picked.path,
      scope: picked.scope,
    );
  } catch (_) {
    return null;
  }
}

///
/// 复用文件管理那套目录能力（[ProotBridge]），但**不是**文件管理器：
/// 这里只做"挑一个能当附件的文本文件"，所以
///  - 图片/压缩包/可执行文件直接置灰，点了只提示原因（AI 收的是文字，
///    塞二进制进上下文没有意义，还会把 token 烧光）；
///  - 选中即读取并按上限截断，调用方拿到的就是可以直接拼进提问的正文。
class LocalFilePicker extends StatefulWidget {
  const LocalFilePicker({
    super.key,
    this.maxChars = 20000,
    this.mode = LocalFilePickerMode.attachment,
    this.title,
    this.extensionFilter,
  });

  /// 附件正文上限。超过就截断——一份 500KB 的日志灌进去只会挤掉真正的对话。
  final int maxChars;

  /// attachment=挑文本/图片附件；anyFile=挑任意文件（ZIP/APK/二进制都行）。
  final LocalFilePickerMode mode;

  /// 面板标题；不传时按附件模式显示“选一个文件当附件”。
  final String? title;

  /// 后缀过滤（不带点，如 zip）。anyFile 模式下只允许该后缀的文件。
  final String? extensionFilter;

  /// 弹出选择器，返回用户挑中的文件；取消返回 null。
  static Future<PickedLocalFile?> pick(
    BuildContext context, {
    int maxChars = 20000,
  }) {
    return showModalBottomSheet<PickedLocalFile>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.86,
        minChildSize: 0.5,
        maxChildSize: 0.94,
        builder: (context, _) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          // 半透明 + 模糊：整块面板是玻璃，底下的页面还看得见轮廓。
          child: BackdropFilter(
            filter: ImageFilter.blur(
                sigmaX: Glass.blurStrong, sigmaY: Glass.blurStrong),
            child: Material(
              color:
                  Theme.of(context).colorScheme.surface.withValues(alpha: 0.86),
              child: LocalFilePicker(maxChars: maxChars),
            ),
          ),
        ),
      ),
    );
  }

  /// 弹出选择器挑任意文件（ZIP/APK/二进制等），只返回路径，不读内容。
  static Future<PickedLocalFile?> pickFile(BuildContext context) {
    return showModalBottomSheet<PickedLocalFile>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.86,
        minChildSize: 0.5,
        maxChildSize: 0.94,
        builder: (context, _) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: BackdropFilter(
            filter: ImageFilter.blur(
                sigmaX: Glass.blurStrong, sigmaY: Glass.blurStrong),
            child: Material(
              color:
                  Theme.of(context).colorScheme.surface.withValues(alpha: 0.86),
              child: const LocalFilePicker(
                mode: LocalFilePickerMode.anyFile,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 挑 ZIP 主题包：标题明确、只显示 .zip 文件、返回路径不读内容。
  static Future<PickedLocalFile?> pickZip(BuildContext context) {
    return showModalBottomSheet<PickedLocalFile>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.86,
        minChildSize: 0.5,
        maxChildSize: 0.94,
        builder: (context, _) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: BackdropFilter(
            filter: ImageFilter.blur(
                sigmaX: Glass.blurStrong, sigmaY: Glass.blurStrong),
            child: Material(
              color:
                  Theme.of(context).colorScheme.surface.withValues(alpha: 0.86),
              child: const LocalFilePicker(
                mode: LocalFilePickerMode.anyFile,
                title: '选择 ZIP 主题包',
                extensionFilter: 'zip',
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  State<LocalFilePicker> createState() => _LocalFilePickerState();
}

class _LocalFilePickerState extends State<LocalFilePicker> {
  final _bridge = ProotBridge();

  bool _appScope = false;
  String _path = '/workspace';
  List<ShellFileEntry> _entries = const [];

  /// 当前作用域的根目录（原生侧报回来的，两套树各自不同）。
  List<String> _roots = const [];
  List<String> _rootLabels = const [];
  bool _loading = true;
  String? _error;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    _load(_path);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = _appScope
          ? await _bridge.listAppFiles(path: path.isEmpty ? null : path)
          : await _bridge.listFiles(path: path);
      if (!mounted) return;
      setState(() {
        _path = listing.path;
        // 隐藏文件对"挑附件"没什么用，但 .env / .bashrc 这类恰恰常被问到，
        // 所以照旧显示，只把目录排在前面。
        _entries = listing.entries;
        _roots = listing.roots;
        _rootLabels = listing.rootLabels;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _switchScope(bool app) async {
    if (app == _appScope) return;
    setState(() {
      _appScope = app;
      _entries = const [];
    });
    await _load(app ? '' : '/workspace');
  }

  String get _parent {
    if (_roots.contains(_path)) return _path;
    final i = _path.lastIndexOf('/');
    if (i < 0) return _path;
    if (i == 0) return _appScope ? _path : '/';
    return _path.substring(0, i);
  }

  Future<void> _choose(ShellFileEntry entry, FileKind kind) async {
    if (_reading) return;
    if (widget.mode == LocalFilePickerMode.anyFile) {
      if (widget.extensionFilter != null &&
          !entry.name.toLowerCase().endsWith('.${widget.extensionFilter!}')) {
        _rejectNotAllowed();
        return;
      }
      Navigator.of(context).pop(
        PickedLocalFile(
          path: entry.path,
          name: entry.name,
          content: '',
          size: entry.size,
          truncated: false,
          scope: _appScope ? 'app' : 'shell',
          mime: FileKinds.mimeOf(entry.name),
        ),
      );
      return;
    }
    setState(() => _reading = true);
    try {
      if (kind.category == FileCategory.image) {
        Navigator.of(context).pop(
          PickedLocalFile(
            path: entry.path,
            name: entry.name,
            content: '',
            size: entry.size,
            truncated: false,
            scope: _appScope ? 'app' : 'shell',
            mime: FileKinds.mimeOf(entry.name),
          ),
        );
        return;
      }
      final raw = await _bridge.readFile(
        path: entry.path,
        scope: _appScope ? 'app' : 'shell',
      );
      if (!mounted) return;
      final truncated = raw.length > widget.maxChars;
      Navigator.of(context).pop(
        PickedLocalFile(
          path: entry.path,
          name: entry.name,
          content: truncated ? raw.substring(0, widget.maxChars) : raw,
          size: entry.size,
          truncated: truncated,
          language: kind.language,
          scope: _appScope ? 'app' : 'shell',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = e.toString();
      });
    }
  }

  /// 从别的 APP 传文件进当前目录。
  ///
  /// 只传了一个、且是能当附件的文本类文件时，直接选中它返回——
  /// 用户点"上传"的意图本来就是"把这个文件给 AI"，不该再让他在列表里找一遍。
  Future<void> _import() async {
    setState(() => _reading = true);
    try {
      final result = await _bridge.importFiles(
        path: _path,
        scope: _appScope ? 'app' : 'shell',
      );
      if (!mounted) return;
      setState(() => _reading = false);
      if (result.canceled) return;
      if (result.failed.isNotEmpty) {
        setState(() => _error =
            '${result.failed.first.name}：${result.failed.first.error}');
      }
      if (result.files.isEmpty) return;
      await _load(_path);
      if (!mounted) return;
      if (result.files.length == 1) {
        final one = result.files.first;
        final kind = FileKinds.of(one.name);
        if (kind.isTextLike || kind.category == FileCategory.image) {
          await _choose(one, kind);
          return;
        }
        // 传进来的是压缩包/可执行这类：文件留在目录里，但当不了附件，说清楚原因。
        _rejectBinary(kind);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = e.toString();
      });
    }
  }

  void _rejectBinary(FileKind kind) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${kind.label}没法当附件：AI 读的是文字，二进制内容塞进去只会挤掉对话'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _rejectNotAllowed() {
    final ext = widget.extensionFilter ?? '该类型';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('只能选择 .$ext 文件'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sorted = [..._entries]..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 4, 0),
            child: Row(
              children: [
                Icon(
                  widget.title == null
                      ? Icons.attach_file_rounded
                      : Icons.folder_open_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.title ?? '选一个文件当附件',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '上传手机文件',
                  onPressed: _loading || _reading ? null : _import,
                  icon: Icon(
                    Icons.file_upload_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                ),
                IconButton(
                  tooltip: '取消',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.terminal, size: 17),
                  label: Text('终端文件'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.phone_android, size: 17),
                  label: Text('APP 文件'),
                ),
              ],
              selected: {_appScope},
              showSelectedIcon: false,
              onSelectionChanged: (v) => _switchScope(v.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上一级',
                  visualDensity: VisualDensity.compact,
                  onPressed: _loading ? null : () => _load(_parent),
                  icon: const Icon(Icons.arrow_upward_rounded, size: 19),
                ),
                Expanded(
                  child: Text(
                    _path.isEmpty ? 'APP 沙箱根' : _path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  visualDensity: VisualDensity.compact,
                  onPressed: _loading ? null : () => _load(_path),
                  icon: const Icon(Icons.refresh_rounded, size: 19),
                ),
              ],
            ),
          ),
          if (_roots.isNotEmpty)
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (var i = 0; i < _roots.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GlassPill(
                        icon: Icons.folder_open_rounded,
                        label:
                            i < _rootLabels.length && _rootLabels[i].isNotEmpty
                                ? _rootLabels[i]
                                : _roots[i],
                        dense: true,
                        color: _path == _roots[i] ? scheme.primary : null,
                        onTap: () => _load(_roots[i]),
                      ),
                    ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                _error!,
                maxLines: 3,
                style: TextStyle(fontSize: 11.5, color: scheme.error),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : sorted.isEmpty
                    ? Center(
                        child: Text(
                          '这个目录是空的',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                        itemCount: sorted.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (context, i) {
                          final entry = sorted[i];
                          final kind = FileKinds.of(
                            entry.name,
                            isDirectory: entry.isDirectory,
                          );
                          final extensionAllowed = widget.mode ==
                                  LocalFilePickerMode.anyFile &&
                              (widget.extensionFilter == null ||
                                  entry.name
                                      .toLowerCase()
                                      .endsWith('.${widget.extensionFilter!}'));
                          final usable = entry.isDirectory ||
                              extensionAllowed ||
                              kind.isTextLike ||
                              kind.category == FileCategory.image;
                          return _Tile(
                            entry: entry,
                            kind: kind,
                            usable: usable,
                            onTap: () {
                              if (entry.isDirectory) {
                                _load(entry.path);
                              } else if (widget.mode ==
                                  LocalFilePickerMode.anyFile) {
                                if (widget.extensionFilter != null &&
                                    !entry.name.toLowerCase().endsWith(
                                        '.${widget.extensionFilter!}')) {
                                  _rejectNotAllowed();
                                } else {
                                  _choose(entry, kind);
                                }
                              } else if (kind.isTextLike ||
                                  kind.category == FileCategory.image) {
                                _choose(entry, kind);
                              } else {
                                _rejectBinary(kind);
                              }
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.entry,
    required this.kind,
    required this.usable,
    required this.onTap,
  });

  final ShellFileEntry entry;
  final FileKind kind;
  final bool usable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dim = usable ? 1.0 : 0.45;
    return Opacity(
      opacity: dim,
      child: GlassPanel(
        radius: 14,
        blur: 10,
        shadowY: 2,
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Row(
              children: [
                Icon(kind.icon, size: 22, color: kind.color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.isDirectory
                            ? '${kind.label} · ${Formatter.dateTime(entry.modified)}'
                            : '${kind.label} · ${FileKinds.sizeText(entry.size)}'
                                ' · ${Formatter.dateTime(entry.modified)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  entry.isDirectory
                      ? Icons.chevron_right_rounded
                      : (usable ? Icons.add_circle_outline : Icons.block),
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
