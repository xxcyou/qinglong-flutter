import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/cpp.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/diff.dart';
import 'package:highlight/languages/dockerfile.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/ini.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/kotlin.dart';
import 'package:highlight/languages/lua.dart';
import 'package:highlight/languages/makefile.dart';
import 'package:highlight/languages/markdown.dart';
import 'package:highlight/languages/php.dart';
import 'package:highlight/languages/properties.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/ruby.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/scss.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';

import 'file_kinds.dart';

/// 语言名 → highlight 的 Mode。语言名由 [FileKinds] 统一给出，
/// 这样"文件图标怎么画"和"代码怎么高亮"永远来自同一张表。
///
/// 不能是 const：highlight 里的语言定义都是 `final Mode`，不是编译期常量。
final Map<String, Mode> _modes = {
  'javascript': javascript,
  'typescript': typescript,
  'python': python,
  'bash': bash,
  'yaml': yaml,
  'json': json,
  'dart': dart,
  'java': java,
  'kotlin': kotlin,
  'go': go,
  'rust': rust,
  'cpp': cpp,
  'php': php,
  'ruby': ruby,
  'lua': lua,
  'sql': sql,
  'xml': xml,
  // HTML 用 xml 模式解析标签；HighlightingCodeController 会额外拆分
  // <script>/<style> 内部做 JS/CSS 高亮，所以这里单独占一个语言名。
  'html': xml,
  'css': css,
  'scss': scss,
  'markdown': markdown,
  'diff': diff,
  'dockerfile': dockerfile,
  'makefile': makefile,
  'ini': ini,
  'properties': properties,
};

/// 根据文件名/路径选择语法高亮语言；不识别时返回 null（纯文本）。
Mode? languageForPath(String path) {
  final name = languageNameForPath(path);
  if (name == null) return null;
  return _modes[name];
}

/// 按高亮语言名取 Mode；[HighlightingCodeController] 拆 HTML 里内嵌
/// script/style 时也要按名字拿 JS/CSS 的定义。
Mode? modeForLanguage(String name) => _modes[name];

/// 返回可被 `package:highlight` 识别的语言名，例如 `javascript`。
String? languageNameForPath(String path) {
  final fileName = path.split('/').last;
  final language = FileKinds.of(fileName).language;
  if (language == null) return null;
  // 表里可能出现还没接入 Mode 的语言名（以后新增类型时），
  // 那种情况按纯文本处理，别让编辑器崩在找不到的 Mode 上。
  return _modes.containsKey(language) ? language : null;
}
