import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// 终端配色方案。
///
/// xterm 包只自带 defaultTheme / whiteOnBlack 两套，都是"能用但不好看"的
/// 级别：前景灰白、蓝色暗到看不清路径、选区和光标同色。这里把市面上主流终端
/// （iTerm2 / Windows Terminal / VS Code）用的几套配色搬进来，让用户能选。
///
/// 每套配色都是完整 16 色 + 光标 + 选区，因为 shell 的着色（ls 的目录蓝、
/// git 的红绿、PS1 的用户名绿）全靠这 16 个槽位，缺一个就有一处看不清。
class TerminalPalette {
  const TerminalPalette({
    required this.id,
    required this.name,
    required this.description,
    required this.theme,
    required this.isDark,
  });

  final String id;
  final String name;
  final String description;
  final TerminalTheme theme;
  final bool isDark;

  Color get background => theme.background;

  static const List<TerminalPalette> all = [
    _oneDark,
    _dracula,
    _tokyoNight,
    _gruvboxDark,
    _nord,
    _solarizedDark,
    _monokaiPro,
    _campbell,
    _solarizedLight,
  ];

  static const String defaultId = 'one_dark';

  static TerminalPalette byId(String? id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return all.first;
  }

  // ---------------------------------------------------------------- 配色表

  /// Atom One Dark：目前最主流的深色终端/编辑器配色，对比度温和不刺眼。
  static const _oneDark = TerminalPalette(
    id: 'one_dark',
    name: 'One Dark',
    description: '主流深色，长时间看不累',
    isDark: true,
    theme: TerminalTheme(
      cursor: Color(0xFF528BFF),
      selection: Color(0x593E4451),
      foreground: Color(0xFFABB2BF),
      background: Color(0xFF282C34),
      black: Color(0xFF3F4451),
      red: Color(0xFFE05561),
      green: Color(0xFF8CC265),
      yellow: Color(0xFFD18F52),
      blue: Color(0xFF4AA5F0),
      magenta: Color(0xFFC162DE),
      cyan: Color(0xFF42B3C2),
      white: Color(0xFFD7DAE0),
      brightBlack: Color(0xFF4F5666),
      brightRed: Color(0xFFFF616E),
      brightGreen: Color(0xFFA5E075),
      brightYellow: Color(0xFFF0A45D),
      brightBlue: Color(0xFF4DC4FF),
      brightMagenta: Color(0xFFDE73FF),
      brightCyan: Color(0xFF4CD1E0),
      brightWhite: Color(0xFFE6E6E6),
      searchHitBackground: Color(0xFFE5C07B),
      searchHitBackgroundCurrent: Color(0xFF98C379),
      searchHitForeground: Color(0xFF282C34),
    ),
  );

  /// Dracula：辨识度最高的紫色系配色。
  static const _dracula = TerminalPalette(
    id: 'dracula',
    name: 'Dracula',
    description: '紫调深色，语法色分得最开',
    isDark: true,
    theme: TerminalTheme(
      cursor: Color(0xFFF8F8F2),
      selection: Color(0x5944475A),
      foreground: Color(0xFFF8F8F2),
      background: Color(0xFF282A36),
      black: Color(0xFF21222C),
      red: Color(0xFFFF5555),
      green: Color(0xFF50FA7B),
      yellow: Color(0xFFF1FA8C),
      blue: Color(0xFFBD93F9),
      magenta: Color(0xFFFF79C6),
      cyan: Color(0xFF8BE9FD),
      white: Color(0xFFF8F8F2),
      brightBlack: Color(0xFF6272A4),
      brightRed: Color(0xFFFF6E6E),
      brightGreen: Color(0xFF69FF94),
      brightYellow: Color(0xFFFFFFA5),
      brightBlue: Color(0xFFD6ACFF),
      brightMagenta: Color(0xFFFF92DF),
      brightCyan: Color(0xFFA4FFFF),
      brightWhite: Color(0xFFFFFFFF),
      searchHitBackground: Color(0xFFF1FA8C),
      searchHitBackgroundCurrent: Color(0xFF50FA7B),
      searchHitForeground: Color(0xFF282A36),
    ),
  );

  /// Tokyo Night：这两年最流行的深蓝配色。
  static const _tokyoNight = TerminalPalette(
    id: 'tokyo_night',
    name: 'Tokyo Night',
    description: '深蓝夜色，OLED 上很省电',
    isDark: true,
    theme: TerminalTheme(
      cursor: Color(0xFFC0CAF5),
      selection: Color(0x59283457),
      foreground: Color(0xFFC0CAF5),
      background: Color(0xFF1A1B26),
      black: Color(0xFF15161E),
      red: Color(0xFFF7768E),
      green: Color(0xFF9ECE6A),
      yellow: Color(0xFFE0AF68),
      blue: Color(0xFF7AA2F7),
      magenta: Color(0xFFBB9AF7),
      cyan: Color(0xFF7DCFFF),
      white: Color(0xFFA9B1D6),
      brightBlack: Color(0xFF414868),
      brightRed: Color(0xFFFF899D),
      brightGreen: Color(0xFF9FE044),
      brightYellow: Color(0xFFFABD2F),
      brightBlue: Color(0xFF8DB0FF),
      brightMagenta: Color(0xFFC7A9FF),
      brightCyan: Color(0xFFA4DAFF),
      brightWhite: Color(0xFFC0CAF5),
      searchHitBackground: Color(0xFFE0AF68),
      searchHitBackgroundCurrent: Color(0xFF9ECE6A),
      searchHitForeground: Color(0xFF1A1B26),
    ),
  );

  /// Gruvbox Dark：暖褐色，白天在强光下也看得清。
  static const _gruvboxDark = TerminalPalette(
    id: 'gruvbox_dark',
    name: 'Gruvbox Dark',
    description: '暖色复古，强光下也清楚',
    isDark: true,
    theme: TerminalTheme(
      cursor: Color(0xFFEBDBB2),
      selection: Color(0x59504945),
      foreground: Color(0xFFEBDBB2),
      background: Color(0xFF282828),
      black: Color(0xFF282828),
      red: Color(0xFFCC241D),
      green: Color(0xFF98971A),
      yellow: Color(0xFFD79921),
      blue: Color(0xFF458588),
      magenta: Color(0xFFB16286),
      cyan: Color(0xFF689D6A),
      white: Color(0xFFA89984),
      brightBlack: Color(0xFF928374),
      brightRed: Color(0xFFFB4934),
      brightGreen: Color(0xFFB8BB26),
      brightYellow: Color(0xFFFABD2F),
      brightBlue: Color(0xFF83A598),
      brightMagenta: Color(0xFFD3869B),
      brightCyan: Color(0xFF8EC07C),
      brightWhite: Color(0xFFEBDBB2),
      searchHitBackground: Color(0xFFFABD2F),
      searchHitBackgroundCurrent: Color(0xFFB8BB26),
      searchHitForeground: Color(0xFF282828),
    ),
  );

  /// Nord：低饱和冷色，看着最"安静"。
  static const _nord = TerminalPalette(
    id: 'nord',
    name: 'Nord',
    description: '低饱和冷色，克制干净',
    isDark: true,
    theme: TerminalTheme(
      cursor: Color(0xFFD8DEE9),
      selection: Color(0x59434C5E),
      foreground: Color(0xFFD8DEE9),
      background: Color(0xFF2E3440),
      black: Color(0xFF3B4252),
      red: Color(0xFFBF616A),
      green: Color(0xFFA3BE8C),
      yellow: Color(0xFFEBCB8B),
      blue: Color(0xFF81A1C1),
      magenta: Color(0xFFB48EAD),
      cyan: Color(0xFF88C0D0),
      white: Color(0xFFE5E9F0),
      brightBlack: Color(0xFF4C566A),
      brightRed: Color(0xFFCF7A81),
      brightGreen: Color(0xFFB5D19E),
      brightYellow: Color(0xFFF2D79E),
      brightBlue: Color(0xFF95B4D1),
      brightMagenta: Color(0xFFC5A0BE),
      brightCyan: Color(0xFF9BD0DE),
      brightWhite: Color(0xFFECEFF4),
      searchHitBackground: Color(0xFFEBCB8B),
      searchHitBackgroundCurrent: Color(0xFFA3BE8C),
      searchHitForeground: Color(0xFF2E3440),
    ),
  );

  /// Solarized Dark：老牌配色，对比度经过视觉校准。
  static const _solarizedDark = TerminalPalette(
    id: 'solarized_dark',
    name: 'Solarized Dark',
    description: '老牌配色，对比度做过校准',
    isDark: true,
    theme: TerminalTheme(
      cursor: Color(0xFF93A1A1),
      selection: Color(0x59073642),
      foreground: Color(0xFF93A1A1),
      background: Color(0xFF002B36),
      black: Color(0xFF073642),
      red: Color(0xFFDC322F),
      green: Color(0xFF859900),
      yellow: Color(0xFFB58900),
      blue: Color(0xFF268BD2),
      magenta: Color(0xFFD33682),
      cyan: Color(0xFF2AA198),
      white: Color(0xFFEEE8D5),
      brightBlack: Color(0xFF586E75),
      brightRed: Color(0xFFCB4B16),
      brightGreen: Color(0xFF6C9E00),
      brightYellow: Color(0xFF657B83),
      brightBlue: Color(0xFF839496),
      brightMagenta: Color(0xFF6C71C4),
      brightCyan: Color(0xFF93A1A1),
      brightWhite: Color(0xFFFDF6E3),
      searchHitBackground: Color(0xFFB58900),
      searchHitBackgroundCurrent: Color(0xFF859900),
      searchHitForeground: Color(0xFF002B36),
    ),
  );

  /// Monokai Pro：和代码编辑器现用的 monokai 高亮同源，两边看起来是一套。
  static const _monokaiPro = TerminalPalette(
    id: 'monokai_pro',
    name: 'Monokai Pro',
    description: '和代码编辑器同一套配色',
    isDark: true,
    theme: TerminalTheme(
      cursor: Color(0xFFFCFCFA),
      selection: Color(0x594A4A47),
      foreground: Color(0xFFFCFCFA),
      background: Color(0xFF2D2A2E),
      black: Color(0xFF403E41),
      red: Color(0xFFFF6188),
      green: Color(0xFFA9DC76),
      yellow: Color(0xFFFFD866),
      blue: Color(0xFFFC9867),
      magenta: Color(0xFFAB9DF2),
      cyan: Color(0xFF78DCE8),
      white: Color(0xFFFCFCFA),
      brightBlack: Color(0xFF727072),
      brightRed: Color(0xFFFF7A9B),
      brightGreen: Color(0xFFBBE68F),
      brightYellow: Color(0xFFFFE18B),
      brightBlue: Color(0xFFFFAE85),
      brightMagenta: Color(0xFFC0B6F5),
      brightCyan: Color(0xFF95E5EE),
      brightWhite: Color(0xFFFFFFFF),
      searchHitBackground: Color(0xFFFFD866),
      searchHitBackgroundCurrent: Color(0xFFA9DC76),
      searchHitForeground: Color(0xFF2D2A2E),
    ),
  );

  /// Campbell：Windows Terminal 的默认配色，很多人最熟这一套。
  static const _campbell = TerminalPalette(
    id: 'campbell',
    name: 'Campbell',
    description: 'Windows Terminal 默认',
    isDark: true,
    theme: TerminalTheme(
      cursor: Color(0xFFCCCCCC),
      selection: Color(0x59FFFFFF),
      foreground: Color(0xFFCCCCCC),
      background: Color(0xFF0C0C0C),
      black: Color(0xFF0C0C0C),
      red: Color(0xFFC50F1F),
      green: Color(0xFF13A10E),
      yellow: Color(0xFFC19C00),
      blue: Color(0xFF0037DA),
      magenta: Color(0xFF881798),
      cyan: Color(0xFF3A96DD),
      white: Color(0xFFCCCCCC),
      brightBlack: Color(0xFF767676),
      brightRed: Color(0xFFE74856),
      brightGreen: Color(0xFF16C60C),
      brightYellow: Color(0xFFF9F1A5),
      brightBlue: Color(0xFF3B78FF),
      brightMagenta: Color(0xFFB4009E),
      brightCyan: Color(0xFF61D6D6),
      brightWhite: Color(0xFFF2F2F2),
      searchHitBackground: Color(0xFFF9F1A5),
      searchHitBackgroundCurrent: Color(0xFF16C60C),
      searchHitForeground: Color(0xFF0C0C0C),
    ),
  );

  /// Solarized Light：唯一的浅色方案，白天户外用。
  static const _solarizedLight = TerminalPalette(
    id: 'solarized_light',
    name: 'Solarized Light',
    description: '浅色，户外阳光下用',
    isDark: false,
    theme: TerminalTheme(
      cursor: Color(0xFF657B83),
      selection: Color(0x59EEE8D5),
      foreground: Color(0xFF586E75),
      background: Color(0xFFFDF6E3),
      black: Color(0xFFEEE8D5),
      red: Color(0xFFDC322F),
      green: Color(0xFF859900),
      yellow: Color(0xFFB58900),
      blue: Color(0xFF268BD2),
      magenta: Color(0xFFD33682),
      cyan: Color(0xFF2AA198),
      white: Color(0xFF073642),
      brightBlack: Color(0xFF93A1A1),
      brightRed: Color(0xFFCB4B16),
      brightGreen: Color(0xFF586E75),
      brightYellow: Color(0xFF657B83),
      brightBlue: Color(0xFF839496),
      brightMagenta: Color(0xFF6C71C4),
      brightCyan: Color(0xFF002B36),
      brightWhite: Color(0xFF002B36),
      searchHitBackground: Color(0xFFB58900),
      searchHitBackgroundCurrent: Color(0xFF859900),
      searchHitForeground: Color(0xFFFDF6E3),
    ),
  );
}
