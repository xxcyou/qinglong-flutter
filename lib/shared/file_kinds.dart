import 'package:flutter/material.dart';

/// 文件大类。决定图标、颜色，以及"点开时该怎么打开"。
enum FileCategory {
  directory,

  /// 代码/脚本：进代码编辑器（带高亮）。
  code,

  /// 纯文本/配置/日志：同样进代码编辑器，只是没有语言高亮。
  text,

  /// 图片：APP 内置查看器。
  image,

  audio,
  video,

  /// 压缩包。
  archive,

  /// pdf / office / epub 等。
  document,

  /// 可执行文件、.so、.apk、数据库、未知二进制：交给外部应用。
  binary,
}

/// 一种文件类型的展示与打开方式。
class FileKind {
  const FileKind({
    required this.category,
    required this.label,
    required this.icon,
    required this.color,
    this.language,
  });

  final FileCategory category;

  /// 人话类型名，属性面板里显示。
  final String label;
  final IconData icon;
  final Color color;

  /// 代码高亮语言名（`highlight` 包能识别的那套），没有则为 null。
  final String? language;

  /// 能不能在 APP 内当文本编辑。
  bool get isTextLike =>
      category == FileCategory.code || category == FileCategory.text;

  bool get isDirectory => category == FileCategory.directory;

  /// 需要交给别的 APP 打开。
  bool get needsExternalApp =>
      category == FileCategory.archive ||
      category == FileCategory.document ||
      category == FileCategory.audio ||
      category == FileCategory.video ||
      category == FileCategory.binary;
}

/// 按文件名（扩展名）判断类型。
///
/// 这套东西 MT 管理器那类文件管理器都有：一眼看图标就知道是什么，
/// 点下去也走对应的打开方式，而不是所有文件都丢进同一个文本框。
class FileKinds {
  FileKinds._();

  static const directory = FileKind(
    category: FileCategory.directory,
    label: '文件夹',
    icon: Icons.folder_rounded,
    color: Color(0xFFFFB300),
  );

  static const _unknown = FileKind(
    category: FileCategory.binary,
    label: '未知类型',
    icon: Icons.insert_drive_file_outlined,
    color: Color(0xFF90A4AE),
  );

  /// 扩展名（小写，不含点）→ 类型。
  static const Map<String, FileKind> _byExtension = {
    // ---------------- 脚本 / 代码 ----------------
    'js': FileKind(
      category: FileCategory.code,
      label: 'JavaScript',
      icon: Icons.javascript_rounded,
      color: Color(0xFFF7DF1E),
      language: 'javascript',
    ),
    'mjs': FileKind(
      category: FileCategory.code,
      label: 'JavaScript 模块',
      icon: Icons.javascript_rounded,
      color: Color(0xFFF7DF1E),
      language: 'javascript',
    ),
    'cjs': FileKind(
      category: FileCategory.code,
      label: 'CommonJS',
      icon: Icons.javascript_rounded,
      color: Color(0xFFF7DF1E),
      language: 'javascript',
    ),
    'ts': FileKind(
      category: FileCategory.code,
      label: 'TypeScript',
      icon: Icons.code_rounded,
      color: Color(0xFF3178C6),
      language: 'typescript',
    ),
    'tsx': FileKind(
      category: FileCategory.code,
      label: 'TypeScript React',
      icon: Icons.code_rounded,
      color: Color(0xFF3178C6),
      language: 'typescript',
    ),
    'jsx': FileKind(
      category: FileCategory.code,
      label: 'React',
      icon: Icons.code_rounded,
      color: Color(0xFF61DAFB),
      language: 'javascript',
    ),
    'py': FileKind(
      category: FileCategory.code,
      label: 'Python',
      icon: Icons.code_rounded,
      color: Color(0xFF4B8BBE),
      language: 'python',
    ),
    'sh': FileKind(
      category: FileCategory.code,
      label: 'Shell 脚本',
      icon: Icons.terminal_rounded,
      color: Color(0xFF6BD968),
      language: 'bash',
    ),
    'bash': FileKind(
      category: FileCategory.code,
      label: 'Bash 脚本',
      icon: Icons.terminal_rounded,
      color: Color(0xFF6BD968),
      language: 'bash',
    ),
    'zsh': FileKind(
      category: FileCategory.code,
      label: 'Zsh 脚本',
      icon: Icons.terminal_rounded,
      color: Color(0xFF6BD968),
      language: 'bash',
    ),
    'dart': FileKind(
      category: FileCategory.code,
      label: 'Dart',
      icon: Icons.code_rounded,
      color: Color(0xFF29B6F6),
      language: 'dart',
    ),
    'java': FileKind(
      category: FileCategory.code,
      label: 'Java',
      icon: Icons.code_rounded,
      color: Color(0xFFEF6C00),
      language: 'java',
    ),
    'kt': FileKind(
      category: FileCategory.code,
      label: 'Kotlin',
      icon: Icons.code_rounded,
      color: Color(0xFF9575CD),
      language: 'kotlin',
    ),
    'go': FileKind(
      category: FileCategory.code,
      label: 'Go',
      icon: Icons.code_rounded,
      color: Color(0xFF00ACC1),
      language: 'go',
    ),
    'rs': FileKind(
      category: FileCategory.code,
      label: 'Rust',
      icon: Icons.code_rounded,
      color: Color(0xFFD84315),
      language: 'rust',
    ),
    'c': FileKind(
      category: FileCategory.code,
      label: 'C',
      icon: Icons.code_rounded,
      color: Color(0xFF5C6BC0),
      language: 'cpp',
    ),
    'h': FileKind(
      category: FileCategory.code,
      label: 'C 头文件',
      icon: Icons.code_rounded,
      color: Color(0xFF5C6BC0),
      language: 'cpp',
    ),
    'cpp': FileKind(
      category: FileCategory.code,
      label: 'C++',
      icon: Icons.code_rounded,
      color: Color(0xFF5C6BC0),
      language: 'cpp',
    ),
    'php': FileKind(
      category: FileCategory.code,
      label: 'PHP',
      icon: Icons.php_rounded,
      color: Color(0xFF7E57C2),
      language: 'php',
    ),
    'rb': FileKind(
      category: FileCategory.code,
      label: 'Ruby',
      icon: Icons.code_rounded,
      color: Color(0xFFE53935),
      language: 'ruby',
    ),
    'lua': FileKind(
      category: FileCategory.code,
      label: 'Lua',
      icon: Icons.code_rounded,
      color: Color(0xFF3F51B5),
      language: 'lua',
    ),
    'sql': FileKind(
      category: FileCategory.code,
      label: 'SQL',
      icon: Icons.storage_rounded,
      color: Color(0xFF26A69A),
      language: 'sql',
    ),
    'html': FileKind(
      category: FileCategory.code,
      label: 'HTML',
      icon: Icons.html_rounded,
      color: Color(0xFFE44D26),
      language: 'xml',
    ),
    'htm': FileKind(
      category: FileCategory.code,
      label: 'HTML',
      icon: Icons.html_rounded,
      color: Color(0xFFE44D26),
      language: 'xml',
    ),
    'xml': FileKind(
      category: FileCategory.code,
      label: 'XML',
      icon: Icons.data_object_rounded,
      color: Color(0xFFFF7043),
      language: 'xml',
    ),
    'css': FileKind(
      category: FileCategory.code,
      label: 'CSS',
      icon: Icons.css_rounded,
      color: Color(0xFF42A5F5),
      language: 'css',
    ),
    'scss': FileKind(
      category: FileCategory.code,
      label: 'SCSS',
      icon: Icons.css_rounded,
      color: Color(0xFFEC407A),
      language: 'scss',
    ),
    'vue': FileKind(
      category: FileCategory.code,
      label: 'Vue',
      icon: Icons.code_rounded,
      color: Color(0xFF41B883),
      language: 'xml',
    ),

    // ---------------- 配置 / 数据 / 文本 ----------------
    'json': FileKind(
      category: FileCategory.code,
      label: 'JSON',
      icon: Icons.data_object_rounded,
      color: Color(0xFFAB47BC),
      language: 'json',
    ),
    'yaml': FileKind(
      category: FileCategory.code,
      label: 'YAML',
      icon: Icons.data_object_rounded,
      color: Color(0xFF7E57C2),
      language: 'yaml',
    ),
    'yml': FileKind(
      category: FileCategory.code,
      label: 'YAML',
      icon: Icons.data_object_rounded,
      color: Color(0xFF7E57C2),
      language: 'yaml',
    ),
    'toml': FileKind(
      category: FileCategory.code,
      label: 'TOML',
      icon: Icons.tune_rounded,
      color: Color(0xFF8D6E63),
      language: 'ini',
    ),
    'ini': FileKind(
      category: FileCategory.code,
      label: 'INI 配置',
      icon: Icons.tune_rounded,
      color: Color(0xFF8D6E63),
      language: 'ini',
    ),
    'conf': FileKind(
      category: FileCategory.code,
      label: '配置文件',
      icon: Icons.tune_rounded,
      color: Color(0xFF8D6E63),
      language: 'ini',
    ),
    'properties': FileKind(
      category: FileCategory.code,
      label: 'Properties',
      icon: Icons.tune_rounded,
      color: Color(0xFF8D6E63),
      language: 'properties',
    ),
    'env': FileKind(
      category: FileCategory.code,
      label: '环境变量',
      icon: Icons.tune_rounded,
      color: Color(0xFF66BB6A),
      language: 'bash',
    ),
    'md': FileKind(
      category: FileCategory.code,
      label: 'Markdown',
      icon: Icons.article_rounded,
      color: Color(0xFF26C6DA),
      language: 'markdown',
    ),
    'markdown': FileKind(
      category: FileCategory.code,
      label: 'Markdown',
      icon: Icons.article_rounded,
      color: Color(0xFF26C6DA),
      language: 'markdown',
    ),
    'diff': FileKind(
      category: FileCategory.code,
      label: '补丁',
      icon: Icons.difference_rounded,
      color: Color(0xFF78909C),
      language: 'diff',
    ),
    'patch': FileKind(
      category: FileCategory.code,
      label: '补丁',
      icon: Icons.difference_rounded,
      color: Color(0xFF78909C),
      language: 'diff',
    ),
    'dockerfile': FileKind(
      category: FileCategory.code,
      label: 'Dockerfile',
      icon: Icons.inventory_2_rounded,
      color: Color(0xFF2496ED),
      language: 'dockerfile',
    ),
    'txt': FileKind(
      category: FileCategory.text,
      label: '文本',
      icon: Icons.text_snippet_rounded,
      color: Color(0xFF90A4AE),
    ),
    'log': FileKind(
      category: FileCategory.text,
      label: '日志',
      icon: Icons.receipt_long_rounded,
      color: Color(0xFF78909C),
    ),
    'csv': FileKind(
      category: FileCategory.text,
      label: 'CSV 表格',
      icon: Icons.table_chart_rounded,
      color: Color(0xFF43A047),
    ),
    'list': FileKind(
      category: FileCategory.text,
      label: '列表文件',
      icon: Icons.list_alt_rounded,
      color: Color(0xFF90A4AE),
    ),
    'lock': FileKind(
      category: FileCategory.text,
      label: '锁文件',
      icon: Icons.lock_outline_rounded,
      color: Color(0xFF90A4AE),
    ),

    // ---------------- 图片 ----------------
    'png': FileKind(
      category: FileCategory.image,
      label: 'PNG 图片',
      icon: Icons.image_rounded,
      color: Color(0xFFEC407A),
    ),
    'jpg': FileKind(
      category: FileCategory.image,
      label: 'JPEG 图片',
      icon: Icons.image_rounded,
      color: Color(0xFFEC407A),
    ),
    'jpeg': FileKind(
      category: FileCategory.image,
      label: 'JPEG 图片',
      icon: Icons.image_rounded,
      color: Color(0xFFEC407A),
    ),
    'gif': FileKind(
      category: FileCategory.image,
      label: 'GIF 动图',
      icon: Icons.gif_box_rounded,
      color: Color(0xFFEC407A),
    ),
    'webp': FileKind(
      category: FileCategory.image,
      label: 'WebP 图片',
      icon: Icons.image_rounded,
      color: Color(0xFFEC407A),
    ),
    'bmp': FileKind(
      category: FileCategory.image,
      label: 'BMP 图片',
      icon: Icons.image_rounded,
      color: Color(0xFFEC407A),
    ),
    'ico': FileKind(
      category: FileCategory.image,
      label: '图标',
      icon: Icons.image_rounded,
      color: Color(0xFFEC407A),
    ),
    'svg': FileKind(
      category: FileCategory.code,
      label: 'SVG 矢量图',
      icon: Icons.image_rounded,
      color: Color(0xFFFFB74D),
      language: 'xml',
    ),

    // ---------------- 音视频 ----------------
    'mp3': FileKind(
      category: FileCategory.audio,
      label: '音频',
      icon: Icons.audiotrack_rounded,
      color: Color(0xFF7E57C2),
    ),
    'wav': FileKind(
      category: FileCategory.audio,
      label: '音频',
      icon: Icons.audiotrack_rounded,
      color: Color(0xFF7E57C2),
    ),
    'flac': FileKind(
      category: FileCategory.audio,
      label: '无损音频',
      icon: Icons.audiotrack_rounded,
      color: Color(0xFF7E57C2),
    ),
    'm4a': FileKind(
      category: FileCategory.audio,
      label: '音频',
      icon: Icons.audiotrack_rounded,
      color: Color(0xFF7E57C2),
    ),
    'ogg': FileKind(
      category: FileCategory.audio,
      label: '音频',
      icon: Icons.audiotrack_rounded,
      color: Color(0xFF7E57C2),
    ),
    'mp4': FileKind(
      category: FileCategory.video,
      label: '视频',
      icon: Icons.movie_rounded,
      color: Color(0xFF5C6BC0),
    ),
    'mkv': FileKind(
      category: FileCategory.video,
      label: '视频',
      icon: Icons.movie_rounded,
      color: Color(0xFF5C6BC0),
    ),
    'avi': FileKind(
      category: FileCategory.video,
      label: '视频',
      icon: Icons.movie_rounded,
      color: Color(0xFF5C6BC0),
    ),
    'mov': FileKind(
      category: FileCategory.video,
      label: '视频',
      icon: Icons.movie_rounded,
      color: Color(0xFF5C6BC0),
    ),
    'webm': FileKind(
      category: FileCategory.video,
      label: '视频',
      icon: Icons.movie_rounded,
      color: Color(0xFF5C6BC0),
    ),

    // ---------------- 压缩包 ----------------
    'zip': FileKind(
      category: FileCategory.archive,
      label: 'ZIP 压缩包',
      icon: Icons.folder_zip_rounded,
      color: Color(0xFFFF8F00),
    ),
    'tar': FileKind(
      category: FileCategory.archive,
      label: 'TAR 包',
      icon: Icons.folder_zip_rounded,
      color: Color(0xFFFF8F00),
    ),
    'gz': FileKind(
      category: FileCategory.archive,
      label: 'GZip 压缩包',
      icon: Icons.folder_zip_rounded,
      color: Color(0xFFFF8F00),
    ),
    'xz': FileKind(
      category: FileCategory.archive,
      label: 'XZ 压缩包',
      icon: Icons.folder_zip_rounded,
      color: Color(0xFFFF8F00),
    ),
    'bz2': FileKind(
      category: FileCategory.archive,
      label: 'BZip2 压缩包',
      icon: Icons.folder_zip_rounded,
      color: Color(0xFFFF8F00),
    ),
    'zst': FileKind(
      category: FileCategory.archive,
      label: 'Zstd 压缩包',
      icon: Icons.folder_zip_rounded,
      color: Color(0xFFFF8F00),
    ),
    '7z': FileKind(
      category: FileCategory.archive,
      label: '7-Zip 压缩包',
      icon: Icons.folder_zip_rounded,
      color: Color(0xFFFF8F00),
    ),
    'rar': FileKind(
      category: FileCategory.archive,
      label: 'RAR 压缩包',
      icon: Icons.folder_zip_rounded,
      color: Color(0xFFFF8F00),
    ),
    'deb': FileKind(
      category: FileCategory.archive,
      label: 'Debian 包',
      icon: Icons.inventory_2_rounded,
      color: Color(0xFFD32F2F),
    ),

    // ---------------- 文档 ----------------
    'pdf': FileKind(
      category: FileCategory.document,
      label: 'PDF 文档',
      icon: Icons.picture_as_pdf_rounded,
      color: Color(0xFFE53935),
    ),
    'doc': FileKind(
      category: FileCategory.document,
      label: 'Word 文档',
      icon: Icons.description_rounded,
      color: Color(0xFF1E88E5),
    ),
    'docx': FileKind(
      category: FileCategory.document,
      label: 'Word 文档',
      icon: Icons.description_rounded,
      color: Color(0xFF1E88E5),
    ),
    'xls': FileKind(
      category: FileCategory.document,
      label: 'Excel 表格',
      icon: Icons.table_view_rounded,
      color: Color(0xFF2E7D32),
    ),
    'xlsx': FileKind(
      category: FileCategory.document,
      label: 'Excel 表格',
      icon: Icons.table_view_rounded,
      color: Color(0xFF2E7D32),
    ),
    'ppt': FileKind(
      category: FileCategory.document,
      label: 'PPT 演示',
      icon: Icons.slideshow_rounded,
      color: Color(0xFFD84315),
    ),
    'pptx': FileKind(
      category: FileCategory.document,
      label: 'PPT 演示',
      icon: Icons.slideshow_rounded,
      color: Color(0xFFD84315),
    ),
    'epub': FileKind(
      category: FileCategory.document,
      label: '电子书',
      icon: Icons.menu_book_rounded,
      color: Color(0xFF00897B),
    ),

    // ---------------- 二进制 ----------------
    'apk': FileKind(
      category: FileCategory.binary,
      label: 'Android 安装包',
      icon: Icons.android_rounded,
      color: Color(0xFF43A047),
    ),
    'so': FileKind(
      category: FileCategory.binary,
      label: '动态库',
      icon: Icons.memory_rounded,
      color: Color(0xFF8D6E63),
    ),
    'db': FileKind(
      category: FileCategory.binary,
      label: '数据库',
      icon: Icons.storage_rounded,
      color: Color(0xFF546E7A),
    ),
    'sqlite': FileKind(
      category: FileCategory.binary,
      label: 'SQLite 数据库',
      icon: Icons.storage_rounded,
      color: Color(0xFF546E7A),
    ),
    'bin': FileKind(
      category: FileCategory.binary,
      label: '二进制',
      icon: Icons.memory_rounded,
      color: Color(0xFF8D6E63),
    ),
    'ttf': FileKind(
      category: FileCategory.binary,
      label: '字体',
      icon: Icons.font_download_rounded,
      color: Color(0xFF6D4C41),
    ),
    'otf': FileKind(
      category: FileCategory.binary,
      label: '字体',
      icon: Icons.font_download_rounded,
      color: Color(0xFF6D4C41),
    ),
  };

  /// 没有扩展名但一眼就知道是什么的常见文件名（小写全名匹配）。
  static const Map<String, FileKind> _byName = {
    'dockerfile': FileKind(
      category: FileCategory.code,
      label: 'Dockerfile',
      icon: Icons.inventory_2_rounded,
      color: Color(0xFF2496ED),
      language: 'dockerfile',
    ),
    'makefile': FileKind(
      category: FileCategory.code,
      label: 'Makefile',
      icon: Icons.build_rounded,
      color: Color(0xFF8D6E63),
      language: 'makefile',
    ),
    'readme': FileKind(
      category: FileCategory.code,
      label: '说明文档',
      icon: Icons.article_rounded,
      color: Color(0xFF26C6DA),
      language: 'markdown',
    ),
    'license': FileKind(
      category: FileCategory.text,
      label: '许可证',
      icon: Icons.gavel_rounded,
      color: Color(0xFF90A4AE),
    ),
    '.bashrc': FileKind(
      category: FileCategory.code,
      label: 'Bash 配置',
      icon: Icons.terminal_rounded,
      color: Color(0xFF6BD968),
      language: 'bash',
    ),
    '.profile': FileKind(
      category: FileCategory.code,
      label: 'Shell 配置',
      icon: Icons.terminal_rounded,
      color: Color(0xFF6BD968),
      language: 'bash',
    ),
    '.gitignore': FileKind(
      category: FileCategory.text,
      label: 'Git 忽略表',
      icon: Icons.rule_rounded,
      color: Color(0xFF90A4AE),
    ),
    'hosts': FileKind(
      category: FileCategory.text,
      label: 'hosts',
      icon: Icons.dns_rounded,
      color: Color(0xFF90A4AE),
    ),
  };

  /// 判断类型。[isDirectory] 优先——目录不看扩展名。
  static FileKind of(String name, {bool isDirectory = false}) {
    if (isDirectory) return directory;
    final lower = name.toLowerCase();
    final byName = _byName[lower];
    if (byName != null) return byName;
    final dot = lower.lastIndexOf('.');
    if (dot > 0 && dot < lower.length - 1) {
      final ext = lower.substring(dot + 1);
      final hit = _byExtension[ext];
      if (hit != null) return hit;
      // 双扩展名：a.tar.gz 之类已被 gz 命中；.d.ts 走 ts。
    }
    // 没有扩展名的文件，多数是脚本或说明；给个中性的文本身份，
    // 真打不开时会在读取阶段报错，而不是一上来就当二进制丢给别的 APP。
    if (dot <= 0) {
      return const FileKind(
        category: FileCategory.text,
        label: '无扩展名文件',
        icon: Icons.description_outlined,
        color: Color(0xFF90A4AE),
      );
    }
    return _unknown;
  }

  /// 交给外部 APP 时用的 MIME。拿不准就 `*/*`，让系统弹选择器。
  static String mimeOf(String name) {
    final kind = of(name);
    final lower = name.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot > 0 ? lower.substring(dot + 1) : '';
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      case 'pdf':
        return 'application/pdf';
      case 'apk':
        return 'application/vnd.android.package-archive';
      case 'zip':
        return 'application/zip';
      case 'mp3':
        return 'audio/mpeg';
      case 'mp4':
        return 'video/mp4';
      case 'txt':
      case 'log':
        return 'text/plain';
    }
    return switch (kind.category) {
      FileCategory.image => 'image/*',
      FileCategory.audio => 'audio/*',
      FileCategory.video => 'video/*',
      FileCategory.text => 'text/plain',
      _ => '*/*',
    };
  }

  /// 人类可读的大小，MT 那种风格：B / KB / MB / GB。
  static String sizeText(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}
