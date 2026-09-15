import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../local_shell/proot_bridge.dart';

/// 组件锚点：主题包 JS 通过 bridge 查询这些信息，就能知道某个组件
/// 在屏幕上的实际位置/大小，效果才能“挂在组件上”。
class ThemeComponentAnchor {
  const ThemeComponentAnchor({
    required this.page,
    required this.type,
    required this.index,
    required this.rect,
  });

  final String page;
  final String type;
  final int index;
  final Rect rect;

  Map<String, dynamic> toJson() => {
        'page': page,
        'type': type,
        'index': index,
        'x': rect.left,
        'y': rect.top,
        'w': rect.width,
        'h': rect.height,
      };
}

/// 组件锚点注册表：GlassPanel / GlassCard 会自动上报自己的位置。
class ThemeComponentRegistry {
  ThemeComponentRegistry._();

  static final ThemeComponentRegistry instance = ThemeComponentRegistry._();

  final Map<String, ThemeComponentAnchor> _anchors = {};

  String _key(String page, String type, int index) => '$page|$type|$index';

  void register(
    String page,
    String type,
    int index,
    Rect rect,
  ) {
    _anchors[_key(page, type, index)] =
        ThemeComponentAnchor(page: page, type: type, index: index, rect: rect);
  }

  void unregister(String page, String type, int index) {
    _anchors.remove(_key(page, type, index));
  }

  List<ThemeComponentAnchor> query({String? page, String? type}) {
    return _anchors.values
        .where((a) =>
            (page == null || a.page == page) &&
            (type == null || a.type == type))
        .toList();
  }
}

/// 液体玻璃参数（最大逼近苹果 Liquid Glass 的参数面）。
/// 不是像素级 1:1：苹果的渲染是私有系统合成器 + 私有着色器，
/// 这里用“背景模糊 + 动态高光 + 波纹/焦散 + 厚度边缘”做最接近的合成。
class LiquidGlass {
  const LiquidGlass({
    this.blur,
    this.refraction = 0.4,
    this.specular = 0.65,
    this.lightX = 0.72,
    this.lightY = 0.14,
    this.ripple = 0.35,
    this.tint,
    this.tintOpacity = 0.32,
    this.caustic = 0.25,
    this.thickness = 0.5,
    this.edgeHighlight = true,
    this.innerShadow = true,
    this.animated = false,
  });

  /// 背景模糊强度，不传就用 style.blur / 组件默认。
  final double? blur;

  /// 背景“折射扭曲”强度（当前用边缘光晕/波纹模拟，不是真实几何扭曲）。
  final double refraction;

  /// 镜面高光强度 0~1。
  final double specular;

  /// 光源位置，组件内部坐标比例 0~1。
  final double lightX;
  final double lightY;

  /// 高光/波纹流动幅度。
  final double ripple;

  /// 玻璃着色/染色。
  final Color? tint;
  final double tintOpacity;

  /// 焦散光斑强度。
  final double caustic;

  /// 玻璃厚度感（边缘高光宽度/阴影范围）。
  final double thickness;
  final bool edgeHighlight;
  final bool innerShadow;

  /// 是否让高光/焦散/波纹持续流动。
  /// 默认关闭（静态液态玻璃），可避免“一闪一闪”；想保留流动效果设 true。
  final bool animated;

  LiquidGlass copyWith({
    double? blur,
    double? refraction,
    double? specular,
    double? lightX,
    double? lightY,
    double? ripple,
    Color? tint,
    double? tintOpacity,
    double? caustic,
    double? thickness,
    bool? edgeHighlight,
    bool? innerShadow,
    bool? animated,
  }) {
    return LiquidGlass(
      blur: blur ?? this.blur,
      refraction: refraction ?? this.refraction,
      specular: specular ?? this.specular,
      lightX: lightX ?? this.lightX,
      lightY: lightY ?? this.lightY,
      ripple: ripple ?? this.ripple,
      tint: tint ?? this.tint,
      tintOpacity: tintOpacity ?? this.tintOpacity,
      caustic: caustic ?? this.caustic,
      thickness: thickness ?? this.thickness,
      edgeHighlight: edgeHighlight ?? this.edgeHighlight,
      innerShadow: innerShadow ?? this.innerShadow,
      animated: animated ?? this.animated,
    );
  }
}

/// 组件原生风格覆盖：不是画上去的图层，而是直接改 APP 自带组件的
/// 边缘颜色/宽度/圆角/渐变/发光等真实装饰属性。
class ComponentStyle {
  const ComponentStyle({
    this.color,
    this.borderColor,
    this.borderWidth,
    this.borderOpacity,
    this.glowColor,
    this.glowRadius,
    this.glowOpacity,
    this.gradientColors,
    this.gradientAngle = 135,
    this.fillOpacity,
    this.radius,
    this.shadowColor,
    this.shadowOpacity,
    this.shadowBlur,
    this.shadowOffsetY,
    this.innerGlowColor,
    this.innerGlowOpacity,
    this.innerGlowRadius,
    this.innerGlowSide = 'all',
    this.innerShadowColor,
    this.innerShadowOpacity,
    this.innerShadowBlur,
    this.innerShadowOffsetX = 0,
    this.innerShadowOffsetY = 2,
    this.innerShadowSide = 'bottom',
    this.opacity,
    this.blur,
    this.backgroundImage,
    this.backgroundImageFit = 'cover',
    this.backgroundImageOpacity,
    this.liquid,
  });

  /// 纯色填充（覆盖渐变；没传时继续用渐变/默认玻璃填充）。
  final Color? color;
  final Color? borderColor;
  final double? borderWidth;
  final double? borderOpacity;
  final Color? glowColor;
  final double? glowRadius;
  final double? glowOpacity;
  final List<Color>? gradientColors;
  final double gradientAngle;
  final double? fillOpacity;
  final double? radius;
  final Color? shadowColor;
  final double? shadowOpacity;
  final double? shadowBlur;
  final double? shadowOffsetY;

  /// 内发光：组件内部边缘柔和发光，side 支持 all/top/bottom/left/right。
  final Color? innerGlowColor;
  final double? innerGlowOpacity;
  final double? innerGlowRadius;
  final String innerGlowSide;

  /// 内阴影：组件内部边缘暗影，模拟被遮挡/月光照不到的暗部。
  final Color? innerShadowColor;
  final double? innerShadowOpacity;
  final double? innerShadowBlur;
  final double? innerShadowOffsetX;
  final double? innerShadowOffsetY;
  final String innerShadowSide;

  /// 组件整体透明度（0~1）。
  final double? opacity;

  /// 玻璃/液体玻璃的模糊强度（像素）。null 表示保持组件默认模糊。
  final double? blur;

  /// 背景纹理图（guest 路径），例如木纹图片。
  final String? backgroundImage;
  final String backgroundImageFit;
  final double? backgroundImageOpacity;

  /// 液体玻璃最大逼近参数；非 null 时组件切换成液体玻璃合成层。
  final LiquidGlass? liquid;

  ComponentStyle merge(ComponentStyle? base) {
    if (base == null) return this;
    return ComponentStyle(
      color: color ?? base.color,
      borderColor: borderColor ?? base.borderColor,
      borderWidth: borderWidth ?? base.borderWidth,
      borderOpacity: borderOpacity ?? base.borderOpacity,
      glowColor: glowColor ?? base.glowColor,
      glowRadius: glowRadius ?? base.glowRadius,
      glowOpacity: glowOpacity ?? base.glowOpacity,
      gradientColors: gradientColors ?? base.gradientColors,
      gradientAngle: gradientAngle,
      fillOpacity: fillOpacity ?? base.fillOpacity,
      radius: radius ?? base.radius,
      shadowColor: shadowColor ?? base.shadowColor,
      shadowOpacity: shadowOpacity ?? base.shadowOpacity,
      shadowBlur: shadowBlur ?? base.shadowBlur,
      shadowOffsetY: shadowOffsetY ?? base.shadowOffsetY,
      innerGlowColor: innerGlowColor ?? base.innerGlowColor,
      innerGlowOpacity: innerGlowOpacity ?? base.innerGlowOpacity,
      innerGlowRadius: innerGlowRadius ?? base.innerGlowRadius,
      innerGlowSide: innerGlowSide,
      innerShadowColor: innerShadowColor ?? base.innerShadowColor,
      innerShadowOpacity: innerShadowOpacity ?? base.innerShadowOpacity,
      innerShadowBlur: innerShadowBlur ?? base.innerShadowBlur,
      innerShadowOffsetX: innerShadowOffsetX ?? base.innerShadowOffsetX,
      innerShadowOffsetY: innerShadowOffsetY ?? base.innerShadowOffsetY,
      innerShadowSide: innerShadowSide,
      opacity: opacity ?? base.opacity,
      blur: blur ?? base.blur,
      backgroundImage: backgroundImage ?? base.backgroundImage,
      backgroundImageFit: backgroundImageFit,
      backgroundImageOpacity:
          backgroundImageOpacity ?? base.backgroundImageOpacity,
      liquid: liquid ?? base.liquid,
    );
  }
}

/// 一个覆盖在 Flutter 组件上方的万能效果图层元素。

class ThemeEffect {
  const ThemeEffect({
    required this.id,
    this.paint,
    this.imagePath,
    this.icon,
    this.text,
    this.x = 0,
    this.y = 0,
    this.width = 80,
    this.height = 80,
    this.color = const Color(0xFFFF9EC4),
    this.animation = 'none',
    this.fit = 'contain',
    this.interactive = false,
    this.fontSize = 14,
    this.speechTail = false,
    this.opacity = 1,
    this.rotation = 0,
    this.scale = 1,
    this.durationMs = 1800,
    this.textBackgroundColor,
    this.textBorderColor,
    this.textBorderWidth = 1.2,
    this.textRadius = 12,
    this.textPadding = 8,
  });

  final String id;

  /// 通用组件重绘/发光：主题包传 paint 描述，Flutter 按描述绘制。
  /// 支持 type: solid / gradient / radialGradient / glow / stroke / shadow。
  final Map<String, dynamic>? paint;

  /// 主题包内图片的 guest 路径，例如 /workspace/.ql_themes/packages/x/image/elements/puppet.png。
  final String? imagePath;

  /// 内置图标名（sparkle/star/heart/flower/paw/bolt/smile...）。
  final String? icon;
  final String? text;

  final double x;
  final double y;
  final double width;
  final double height;
  final Color color;

  /// none / float / bounce / spin / fade / pulse / shake / wiggle / blink / slide
  final String animation;

  /// contain / fill / cover
  final String fit;

  /// true 时这个特效可点击/长按；false（默认）整层透明不挡任何控件。
  final bool interactive;
  final double fontSize;
  final bool speechTail;

  /// 整体透明度 0~1，默认 1。
  final double opacity;

  /// 静态旋转角度（度），配合动画 spin/wiggle 时会在动态角度基础上叠加。
  final double rotation;

  /// 整体缩放，默认 1。
  final double scale;

  /// 动画一个循环的时长（毫秒），默认 1800。
  final int durationMs;

  /// 文字气泡背景。
  final Color? textBackgroundColor;
  final Color? textBorderColor;
  final double textBorderWidth;
  final double textRadius;
  final double textPadding;

  Map<String, dynamic> toJson() => {
        'id': id,
        'paint': paint,
        'imagePath': imagePath,
        'icon': icon,
        'text': text,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'color': color.toARGB32(),
        'animation': animation,
        'fit': fit,
        'interactive': interactive,
        'fontSize': fontSize,
        'speechTail': speechTail,
        'opacity': opacity,
        'rotation': rotation,
        'scale': scale,
        'durationMs': durationMs,
        'textBackgroundColor': textBackgroundColor?.toARGB32(),
        'textBorderColor': textBorderColor?.toARGB32(),
        'textBorderWidth': textBorderWidth,
        'textRadius': textRadius,
        'textPadding': textPadding,
      };
}

/// 全局主题效果控制器：主题包 JS 通过 DSHTheme 接口发指令到这里，
/// Flutter 的 ThemeEffectsOverlay 负责绘制。
class ThemeEffectsController extends ChangeNotifier {
  ThemeEffectsController._();

  static final ThemeEffectsController instance = ThemeEffectsController._();

  /// 当前激活主题包 id，导入后实际包目录会变成 pkgxxxx。
  /// 用于把主题包里写死的旧包路径修正到当前包，以及解析相对图片路径。
  String? currentPackageId;

  /// 根 Overlay 自己的全局原点。如果 Overlay 和组件锚点不在同一个坐标原点，
  /// 渲染时把特效坐标减去这个偏移量，保证位置对齐。
  Offset overlayOffset = Offset.zero;

  final Map<String, ThemeEffect> _effects = {};
  final Map<String, ThemeEffect> _pendingEffects = {};
  Timer? _effectFlushTimer;
  final Map<String, ComponentStyle> _styles = {};

  /// guest 图片路径 -> host 文件路径缓存：同一动画帧里多个特效引用同一张图时，
  /// 不再重复走 ProotBridge.hostPath 异步链路。
  final Map<String, String> _imageHostCache = {};

  /// 主题包交互事件回调（由 WebView 背景注册）。
  Function(String id)? onEffectTap;
  Function(String id)? onEffectLongPress;
  List<ThemeEffect> get effects => List.unmodifiable(_effects.values);

  ThemeEffect? byId(String id) => _pendingEffects[id] ?? _effects[id];

  /// 把主题包 JS 传的图片路径解析成宿主可读文件路径。
  /// 支持：绝对 guest 路径、相对包内路径（image/elements/x.png）、
  /// 以及导入后旧包 id 仍写死在 JS 里的容错替换。
  Future<String> resolveImagePath(String guestPath) async {
    final bridge = ProotBridge();
    Future<String> host(String p) async {
      try {
        return await bridge.hostPath(path: p, scope: 'shell');
      } catch (_) {
        return '';
      }
    }

    String path = guestPath.trim();
    if (path.isEmpty) return '';

    // 相对路径：按当前主题包根目录解析。
    if (!path.startsWith('/') && currentPackageId != null) {
      path = '/workspace/.ql_themes/packages/$currentPackageId/$path';
    }

    // 相对路径先规范化再查缓存，避免同一张图重复走 hostPath。
    final cached = _imageHostCache[path];
    if (cached != null && cached.isNotEmpty) return cached;

    final direct = await host(path);
    if (direct.isNotEmpty && File(direct).existsSync()) {
      _imageHostCache[path] = direct;
      return direct;
    }

    // 绝对路径里写死了旧包 id：导入 ZIP 后包目录会变成 pkgxxxx，
    // 把旧 id 替换成当前 id 再试一次。
    if (path.startsWith('/workspace/.ql_themes/packages/') &&
        currentPackageId != null) {
      final fixed = path.replaceFirst(
        RegExp(r'^/workspace/.ql_themes/packages/[^/]+/'),
        '/workspace/.ql_themes/packages/$currentPackageId/',
      );
      if (fixed != path) {
        final retry = await host(fixed);
        if (retry.isNotEmpty && File(retry).existsSync()) {
          _imageHostCache[path] = retry;
          return retry;
        }
      }
    }
    return direct;
  }

  void updateOverlayOffset(Offset offset) {
    if (overlayOffset == offset) return;
    overlayOffset = offset;
    notifyListeners();
  }

  String _styleKey(String page, String type, int index) => '$page|$type|$index';

  ComponentStyle? componentStyleFor(String page, String type, int index) {
    return _styles[_styleKey(page, type, index)];
  }

  void applyComponentStyle({
    required String page,
    required String type,
    required int index,
    required ComponentStyle style,
  }) {
    final old = _styles[_styleKey(page, type, index)];
    _styles[_styleKey(page, type, index)] = style.merge(old);
    notifyListeners();
  }

  void removeComponentStyle(String page, String type, int index) {
    _styles.remove(_styleKey(page, type, index));
    notifyListeners();
  }

  void clearComponentStyles() {
    if (_styles.isEmpty) return;
    _styles.clear();
    notifyListeners();
  }

  void emitEffectTap(String id) => onEffectTap?.call(id);

  void emitEffectLongPress(String id) => onEffectLongPress?.call(id);

  /// 高频特效合批：主题 JS 经常在 requestAnimationFrame 里每帧更新同一个
  /// effect id（桂花飘落、粒子跟随之类），如果每帧都 notifyListeners，
  /// 50 多个特效会把主线程直接打挂（ANR/闪退）。
  /// 这里攒 16ms（约一帧）再一次性落盘 + 通知。
  void upsert(ThemeEffect effect) {
    _pendingEffects[effect.id] = effect;
    _effectFlushTimer ??= Timer(
      const Duration(milliseconds: 16),
      _flushPendingEffects,
    );
  }

  void _flushPendingEffects() {
    _effectFlushTimer = null;
    if (_pendingEffects.isEmpty) return;
    _effects.addAll(_pendingEffects);
    _pendingEffects.clear();
    notifyListeners();
  }

  void remove(String id) {
    _pendingEffects.remove(id);
    if (_effects.remove(id) != null) notifyListeners();
  }

  void clear() {
    _effectFlushTimer?.cancel();
    _effectFlushTimer = null;
    _pendingEffects.clear();
    if (_effects.isEmpty) return;
    _effects.clear();
    notifyListeners();
  }
}

/// 主题包 JS 收到的 bridge 指令解析器。
class ThemeEffectBridge {
  static final _icons = <String, IconData>{
    'sparkle': Icons.auto_awesome,
    'star': Icons.star,
    'heart': Icons.favorite,
    'flower': Icons.local_florist,
    'paw': Icons.pets,
    'fire': Icons.local_fire_department,
    'bolt': Icons.bolt,
    'smile': Icons.sentiment_satisfied_alt,
    'ghost': Icons.mood_bad,
    'magic': Icons.auto_fix_high,
  };

  static IconData icon(String? name) =>
      _icons[name?.toLowerCase()] ?? Icons.auto_awesome;

  static ThemeEffect? parseEffect(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final id = map['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return ThemeEffect(
      id: id,
      paint: map['paint'] is Map
          ? Map<String, dynamic>.from(map['paint'] as Map)
          : null,
      imagePath: map['imagePath']?.toString(),
      icon: map['icon']?.toString(),
      text: map['text']?.toString(),
      x: (map['x'] as num?)?.toDouble() ?? 0,
      y: (map['y'] as num?)?.toDouble() ?? 0,
      width: (map['width'] as num?)?.toDouble() ?? 80,
      height: (map['height'] as num?)?.toDouble() ?? 80,
      color: parseColor(map['color']) ?? const Color(0xFFFF9EC4),
      animation: map['animation']?.toString() ?? 'none',
      fit: map['fit']?.toString() ?? 'contain',
      interactive: map['interactive'] == true,
      fontSize: (map['fontSize'] as num?)?.toDouble() ?? 14,
      speechTail: map['speechTail'] == true,
      opacity: ((map['opacity'] as num?)?.toDouble() ?? 1).clamp(0.0, 1.0),
      rotation: (map['rotation'] as num?)?.toDouble() ?? 0,
      scale: (map['scale'] as num?)?.toDouble() ?? 1,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 1800,
      textBackgroundColor: parseColor(map['textBackgroundColor']),
      textBorderColor: parseColor(map['textBorderColor']),
      textBorderWidth: (map['textBorderWidth'] as num?)?.toDouble() ?? 1.2,
      textRadius: (map['textRadius'] as num?)?.toDouble() ?? 12,
      textPadding: (map['textPadding'] as num?)?.toDouble() ?? 8,
    );
  }

  static ComponentStyle? parseComponentStyle(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final style = m['style'];
    if (style is! Map) return null;
    final st = Map<String, dynamic>.from(style);
    List<Color>? colors;
    final rawColors = st['colors'];
    if (rawColors is List) {
      final parsed =
          rawColors.map((c) => parseColor(c)).whereType<Color>().toList();
      if (parsed.isNotEmpty) colors = parsed;
    }
    final innerGlow = st['innerGlow'] is Map
        ? Map<String, dynamic>.from(st['innerGlow'] as Map)
        : const <String, dynamic>{};
    final innerShadow = st['innerShadow'] is Map
        ? Map<String, dynamic>.from(st['innerShadow'] as Map)
        : const <String, dynamic>{};
    return ComponentStyle(
      color: parseColor(st['color']),
      borderColor: parseColor(st['borderColor']),
      borderWidth: (st['borderWidth'] as num?)?.toDouble(),
      borderOpacity: (st['borderOpacity'] as num?)?.toDouble(),
      glowColor: parseColor(st['glowColor']),
      glowRadius: (st['glowRadius'] as num?)?.toDouble(),
      glowOpacity: (st['glowOpacity'] as num?)?.toDouble(),
      gradientColors: colors,
      gradientAngle: (st['angle'] as num?)?.toDouble() ?? 135,
      fillOpacity: (st['fillOpacity'] as num?)?.toDouble(),
      radius: (st['radius'] as num?)?.toDouble(),
      shadowColor: parseColor(st['shadowColor']),
      shadowOpacity: (st['shadowOpacity'] as num?)?.toDouble(),
      shadowBlur: (st['shadowBlur'] as num?)?.toDouble(),
      shadowOffsetY: (st['shadowOffsetY'] as num?)?.toDouble(),
      innerGlowColor: parseColor(innerGlow['color'] ??
          innerGlow['innerGlowColor'] ??
          st['innerGlowColor']),
      innerGlowOpacity: (innerGlow['opacity'] ??
              innerGlow['innerGlowOpacity'] ??
              st['innerGlowOpacity'] as num?)
          ?.toDouble(),
      innerGlowRadius: (innerGlow['radius'] ??
              innerGlow['innerGlowRadius'] ??
              st['innerGlowRadius'] as num?)
          ?.toDouble(),
      innerGlowSide: (innerGlow['side'] ??
                  innerGlow['innerGlowSide'] ??
                  st['innerGlowSide'])
              ?.toString() ??
          'all',
      innerShadowColor: parseColor(innerShadow['color'] ??
          innerShadow['innerShadowColor'] ??
          st['innerShadowColor']),
      innerShadowOpacity: (innerShadow['opacity'] ??
              innerShadow['innerShadowOpacity'] ??
              st['innerShadowOpacity'] as num?)
          ?.toDouble(),
      innerShadowBlur: (innerShadow['blur'] ??
              innerShadow['innerShadowBlur'] ??
              st['innerShadowBlur'] as num?)
          ?.toDouble(),
      innerShadowOffsetX: (innerShadow['offsetX'] ??
              innerShadow['innerShadowOffsetX'] ??
              st['innerShadowOffsetX'] as num?)
          ?.toDouble(),
      innerShadowOffsetY: (innerShadow['offsetY'] ??
              innerShadow['innerShadowOffsetY'] ??
              st['innerShadowOffsetY'] as num?)
          ?.toDouble(),
      innerShadowSide: (innerShadow['side'] ??
                  innerShadow['innerShadowSide'] ??
                  st['innerShadowSide'])
              ?.toString() ??
          'bottom',
      opacity: (st['opacity'] as num?)?.toDouble(),
      blur: (st['blur'] as num?)?.toDouble(),
      backgroundImage:
          (st['backgroundImage'] ?? st['texture'] ?? st['bgImage'])?.toString(),
      backgroundImageFit:
          (st['backgroundImageFit'] ?? st['textureFit'] ?? 'cover').toString(),
      backgroundImageOpacity:
          (st['backgroundImageOpacity'] as num?)?.toDouble(),
      liquid: _parseLiquid(st['liquid']),
    );
  }

  static LiquidGlass? _parseLiquid(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    return LiquidGlass(
      blur: (m['blur'] as num?)?.toDouble(),
      refraction:
          ((m['refraction'] as num?)?.toDouble() ?? 0.4).clamp(0.0, 2.0),
      specular: ((m['specular'] as num?)?.toDouble() ?? 0.65).clamp(0.0, 1.0),
      lightX: ((m['lightX'] ?? m['light_x'] ?? m['lx']) as num?)?.toDouble() ??
          0.72,
      lightY: ((m['lightY'] ?? m['light_y'] ?? m['ly']) as num?)?.toDouble() ??
          0.14,
      ripple: ((m['ripple'] as num?)?.toDouble() ?? 0.35).clamp(0.0, 2.0),
      tint: parseColor(m['tint'] ?? m['color']),
      tintOpacity:
          ((m['tintOpacity'] ?? m['tint_opacity']) as num?)?.toDouble() ?? 0.32,
      caustic: ((m['caustic'] as num?)?.toDouble() ?? 0.25).clamp(0.0, 1.0),
      thickness: ((m['thickness'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 2.0),
      edgeHighlight:
          (m['edgeHighlight'] ?? m['edge_highlight'] ?? true) == true,
      innerShadow: (m['innerShadow'] ?? m['inner_shadow'] ?? true) == true,
      animated: (m['animated'] ?? false) == true,
    );
  }

  static Color? parseColor(Object? v) {
    if (v is int) return Color(v);
    if (v is String) {
      final raw = v.trim();
      if (raw.startsWith('rgb')) {
        final match = RegExp(r'^rgba?\(([^)]+)\)$').firstMatch(raw);
        if (match != null) {
          final parts =
              match.group(1)!.split(',').map((e) => e.trim()).toList();
          if (parts.length >= 3) {
            final r = int.tryParse(parts[0]) ?? 0;
            final g = int.tryParse(parts[1]) ?? 0;
            final b = int.tryParse(parts[2]) ?? 0;
            final a = parts.length > 3
                ? (double.tryParse(parts[3]) ?? 1).clamp(0.0, 1.0)
                : 1.0;
            return Color.fromRGBO(r, g, b, a);
          }
        }
        return null;
      }
      final s = raw.replaceFirst('#', '');
      final i = int.tryParse(s, radix: 16);
      if (i == null) return null;
      return s.length == 6 ? Color(0xFF000000 | i) : Color(i);
    }
    return null;
  }
}

/// Flutter 覆盖层：渲染主题包 JS 通过 DSHTheme.effect 发来的特效。
/// 全局特效覆盖层。
///
/// 放在根 Overlay 里而不是 GlassBackdrop 本地 Stack：
/// 1. 坐标直接用组件锚点的全局坐标，不会因为页面内边距/标题条发生偏移；
/// 2. 整层 IgnorePointer，特效永远不会挡住输入框/按钮/列表点击。
class ThemeEffectsOverlay extends StatefulWidget {
  const ThemeEffectsOverlay({super.key});

  @override
  State<ThemeEffectsOverlay> createState() => _ThemeEffectsOverlayState();
}

class _ThemeEffectsOverlayState extends State<ThemeEffectsOverlay> {
  static int _activeInstances = 0;
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_activeInstances > 0) {
        _activeInstances++;
        return;
      }
      _entry = OverlayEntry(
        builder: (_) => Positioned.fill(
          child: _ThemeOverlayContent(),
        ),
      );
      Overlay.of(context, rootOverlay: true).insert(_entry!);
      _activeInstances++;
    });
  }

  @override
  void dispose() {
    if (_activeInstances > 0) _activeInstances--;
    if (_activeInstances == 0 && _entry != null) {
      _entry!.remove();
      _entry = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _ThemeOverlayContent extends StatefulWidget {
  @override
  State<_ThemeOverlayContent> createState() => _ThemeOverlayContentState();
}

class _ThemeOverlayContentState extends State<_ThemeOverlayContent> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureOrigin());
  }

  void _measureOrigin() {
    if (!mounted) return;
    final render = context.findRenderObject();
    if (render is RenderBox && render.attached) {
      final origin = render.localToGlobal(Offset.zero);
      if (origin != ThemeEffectsController.instance.overlayOffset) {
        ThemeEffectsController.instance.updateOverlayOffset(origin);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeEffectsController.instance,
      builder: (context, _) {
        final controller = ThemeEffectsController.instance;
        final effects = controller.effects;
        if (effects.isEmpty) {
          return const SizedBox.expand();
        }
        final origin = controller.overlayOffset;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final e in effects)
              Positioned(
                left: e.x - origin.dx,
                top: e.y - origin.dy,
                width: e.width,
                height: e.height,
                // 每个特效独立重绘边界：动画只重绘自己的小区域，
                // 不会让整个全屏 Stack 跟着每帧重绘。
                child: RepaintBoundary(child: _EffectWidget(effect: e)),
              ),
          ],
        );
      },
    );
  }
}

class _PaintEffect extends StatelessWidget {
  const _PaintEffect({required this.effect});

  final ThemeEffect effect;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ComponentPaintPainter(effect),
      size: Size.infinite,
    );
  }
}

class _ComponentPaintPainter extends CustomPainter {
  _ComponentPaintPainter(this.effect);

  final ThemeEffect effect;

  List<Color> _colors(Object? raw, Color fallback) {
    if (raw is List) {
      final list = raw
          .map((v) => ThemeEffectBridge.parseColor(v))
          .whereType<Color>()
          .toList();
      if (list.isNotEmpty) return list;
    }
    return [fallback];
  }

  double _num(Map<String, dynamic> p, String key, double fallback) {
    final v = p[key];
    return v is num ? v.toDouble() : fallback;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = effect.paint;
    if (p == null || size.width <= 0 || size.height <= 0) return;

    final type = (p['type']?.toString() ?? 'solid').toLowerCase();
    final colors = _colors(p['colors'], effect.color);
    final opacity = _num(p, 'opacity', 1).clamp(0.0, 1.0);
    final strokeWidth = _num(p, 'borderWidth', 2).clamp(0.5, 20.0);
    final blurRadius = _num(p, 'radius', 10);
    final cornerRadius = _num(p, 'cornerRadius', 16);
    final angle = _num(p, 'angle', 0);
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(
          cornerRadius.clamp(0, math.min(size.width, size.height) / 2)),
    );

    switch (type) {
      case 'gradient':
        final rad = angle * math.pi / 180;
        final dx = math.cos(rad).toDouble();
        final dy = math.sin(rad).toDouble();
        final shader = LinearGradient(
          colors: colors,
          begin: Alignment(-dx, -dy),
          end: Alignment(dx, dy),
        ).createShader(rect);
        canvas.drawRRect(
          rrect,
          Paint()
            ..shader = shader
            ..color = colors.first.withValues(alpha: opacity),
        );
        break;
      case 'radialGradient':
        final radius = _num(p, 'radius', 0.8).clamp(0.0, 1.2);
        final shader = RadialGradient(
          colors: colors,
          radius: radius,
        ).createShader(rect);
        canvas.drawRRect(
          rrect,
          Paint()..shader = shader,
        );
        break;
      case 'glow':
        final blur = blurRadius.clamp(0.5, 60.0);
        final glowPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = colors.first.withValues(alpha: opacity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
        canvas.drawRRect(rrect, glowPaint);
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..color = colors.first,
        );
        break;
      case 'stroke':
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..color = colors.first.withValues(alpha: opacity),
        );
        break;
      case 'shadow':
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = colors.first.withValues(alpha: opacity)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurRadius),
        );
        break;
      case 'ellipse':
        canvas.drawOval(
          rect,
          Paint()..color = colors.first.withValues(alpha: opacity),
        );
        break;
      case 'ring':
        canvas.drawOval(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..color = colors.first.withValues(alpha: opacity),
        );
        break;
      case 'line':
        {
          final rad = angle * math.pi / 180;
          final cx = size.width / 2;
          final cy = size.height / 2;
          final len = size.longestSide;
          final from = Offset(
              cx - math.cos(rad) * len / 2, cy - math.sin(rad) * len / 2);
          final to = Offset(
              cx + math.cos(rad) * len / 2, cy + math.sin(rad) * len / 2);
          canvas.drawLine(
            from,
            to,
            Paint()
              ..strokeWidth = strokeWidth
              ..strokeCap = StrokeCap.round
              ..color = colors.first.withValues(alpha: opacity),
          );
        }
        break;
      case 'dashed':
        {
          final path = Path()..addRRect(rrect);
          final dashWidth = _num(p, 'dashWidth', 6).clamp(1.0, 80.0);
          final dashGap = _num(p, 'dashGap', 4).clamp(0.0, 80.0);
          final strokePaint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeCap = StrokeCap.round
            ..color = colors.first.withValues(alpha: opacity);
          for (final metric in path.computeMetrics()) {
            var dist = 0.0;
            while (dist < metric.length) {
              final end = math.min(dist + dashWidth, metric.length);
              canvas.drawPath(metric.extractPath(dist, end), strokePaint);
              dist = end + dashGap;
            }
          }
        }
        break;
      case 'solid':
      default:
        canvas.drawRRect(
          rrect,
          Paint()..color = colors.first.withValues(alpha: opacity),
        );
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _ComponentPaintPainter oldDelegate) =>
      oldDelegate.effect != effect;
}

/// 组件内部发光/内部阴影绘制器。
///
/// 这些是真实“内”效果：先 clip 到组件圆角矩形，再在内部边缘画淡出/淡入的
/// 线性渐变。`innerGlow` 模拟被月光/灯照亮的边缘，`innerShadow` 模拟没有被
/// 照到、暗下来的边缘（默认底部）。
class ThemeInnerDecorPainter extends CustomPainter {
  ThemeInnerDecorPainter({
    required this.style,
    required this.cornerRadius,
  });

  final ComponentStyle style;
  final double cornerRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rr = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(cornerRadius),
    );
    canvas.save();
    canvas.clipRRect(rr);
    _paintGlow(canvas, size);
    _paintShadow(canvas, size);
    canvas.restore();
  }

  List<String> _sides(String? raw) {
    return switch (raw) {
      'top' => const ['top'],
      'bottom' => const ['bottom'],
      'left' => const ['left'],
      'right' => const ['right'],
      _ => const ['top', 'bottom', 'left', 'right'],
    };
  }

  void _paintGlow(Canvas canvas, Size size) {
    final color = style.innerGlowColor;
    final opacity = style.innerGlowOpacity ?? 0.6;
    final band =
        (style.innerGlowRadius ?? 12).clamp(0.0, size.shortestSide * 0.5);
    if (color == null ||
        opacity <= 0 ||
        band <= 0 ||
        size.width <= 2 ||
        size.height <= 2) {
      return;
    }
    final paint = Paint();
    final sides = _sides(style.innerGlowSide);
    void face(String side) {
      switch (side) {
        case 'top':
          final rect = Rect.fromLTWH(0, 0, size.width, band * 2);
          paint.shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect);
          canvas.drawRect(rect, paint);
        case 'bottom':
          final rect =
              Rect.fromLTWH(0, size.height - band * 2, size.width, band * 2);
          paint.shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect);
          canvas.drawRect(rect, paint);
        case 'left':
          final rect = Rect.fromLTWH(0, 0, band * 2, size.height);
          paint.shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect);
          canvas.drawRect(rect, paint);
        case 'right':
          final rect =
              Rect.fromLTWH(size.width - band * 2, 0, band * 2, size.height);
          paint.shader = LinearGradient(
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect);
          canvas.drawRect(rect, paint);
      }
    }

    for (final side in sides) {
      face(side);
    }
  }

  void _paintShadow(Canvas canvas, Size size) {
    final color = style.innerShadowColor ?? Colors.black;
    final opacity = style.innerShadowOpacity ?? 0.32;
    final band =
        (style.innerShadowBlur ?? 10).clamp(0.0, size.shortestSide * 0.5);
    if (opacity <= 0 || band <= 0 || size.width <= 2 || size.height <= 2) {
      return;
    }
    final paint = Paint();
    final ox = style.innerShadowOffsetX ?? 0;
    final oy = style.innerShadowOffsetY ?? 2;
    final sides = _sides(style.innerShadowSide);
    void face(String side) {
      switch (side) {
        case 'top':
          final rect = Rect.fromLTWH(ox, oy, size.width, band * 2);
          paint.shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect);
          canvas.drawRect(rect, paint);
        case 'bottom':
          final rect = Rect.fromLTWH(
              ox, size.height - band * 2 + oy, size.width, band * 2);
          paint.shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect);
          canvas.drawRect(rect, paint);
        case 'left':
          final rect = Rect.fromLTWH(ox, oy, band * 2, size.height);
          paint.shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect);
          canvas.drawRect(rect, paint);
        case 'right':
          final rect = Rect.fromLTWH(
              size.width - band * 2 + ox, oy, band * 2, size.height);
          paint.shader = LinearGradient(
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect);
          canvas.drawRect(rect, paint);
      }
    }

    for (final side in sides) {
      face(side);
    }
  }

  @override
  bool shouldRepaint(covariant ThemeInnerDecorPainter oldDelegate) =>
      oldDelegate.style != style || oldDelegate.cornerRadius != cornerRadius;
}

/// 液体玻璃合成层：在组件背景上叠加动态高光、焦散、折射波纹与厚度边缘。
/// 这是“最大逼近版”，不是苹果像素级 1:1。
class LiquidGlassOverlay extends StatefulWidget {
  const LiquidGlassOverlay({
    super.key,
    required this.liquid,
    required this.cornerRadius,
  });

  final LiquidGlass liquid;
  final double cornerRadius;

  @override
  State<LiquidGlassOverlay> createState() => _LiquidGlassOverlayState();
}

class _LiquidGlassOverlayState extends State<LiquidGlassOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Offset _lastGlobal = Offset.zero;
  Offset _motion = Offset.zero;
  bool _hasLast = false;
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5200),
    );
    if (widget.liquid.animated) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant LiquidGlassOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.liquid.animated && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.liquid.animated && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 悬浮窗/面板滑动时，记录它全局位置的变化，作为液体高光“被带着走”的
  /// 惯性输入。没有这个的话，玻璃滑了但高光钉在组件内部坐标里，看起来不跟手。
  /// 每 6 帧跟踪一次，避免每个液体组件每帧都做 localToGlobal 拖慢界面。
  void _trackMotion() {
    _frame++;
    if (_frame % 6 != 0) return;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached) return;
    final global = render.localToGlobal(Offset.zero);
    if (_hasLast) {
      final delta = global - _lastGlobal;
      _motion = Offset.lerp(_motion, delta, 0.25) ?? Offset.zero;
    }
    _lastGlobal = global;
    _hasLast = true;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          _trackMotion();
          return CustomPaint(
            painter: _LiquidGlassPainter(
              liquid: widget.liquid,
              cornerRadius: widget.cornerRadius,
              t: widget.liquid.animated ? _controller.value : 0.0,
              motion: _motion,
            ),
          );
        },
      ),
    );
  }
}

class _LiquidGlassPainter extends CustomPainter {
  _LiquidGlassPainter({
    required this.liquid,
    required this.cornerRadius,
    required this.t,
    this.motion = Offset.zero,
  });

  final LiquidGlass liquid;
  final double cornerRadius;
  final double t;
  final Offset motion;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(cornerRadius),
    );
    canvas.save();
    canvas.clipRRect(rrect);
    _paintTint(canvas, size, rrect);
    _paintRefraction(canvas, size);
    _paintCaustics(canvas, size);
    _paintSpecular(canvas, size);
    _paintEdges(canvas, size);
    canvas.restore();
  }

  void _paintTint(Canvas canvas, Size size, RRect rrect) {
    final color = liquid.tint ?? Colors.white;
    final opacity = liquid.tintOpacity.clamp(0.0, 1.0);
    if (opacity <= 0) return;
    canvas.drawRRect(
      rrect,
      Paint()..color = color.withValues(alpha: opacity),
    );
  }

  void _paintRefraction(Canvas canvas, Size size) {
    final strength = liquid.refraction.clamp(0.0, 2.0);
    if (strength <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.white.withValues(alpha: 0.10 * strength);
    final mid = Offset(size.width * 0.5, size.height * 0.5);
    final radius = size.longestSide * 0.42;
    for (var i = 0; i < 3; i++) {
      final phase = (liquid.animated ? t * 2 * math.pi : 0.0) + i * 2.399;
      final path = Path();
      final rr = radius + (i - 1) * size.longestSide * 0.06;
      const points = 24;
      for (var p = 0; p <= points; p++) {
        final a = p / points * 2 * math.pi;
        final wobble =
            math.sin(a * 3 + phase) * size.longestSide * 0.012 * strength;
        final px = mid.dx + math.cos(a) * (rr + wobble);
        final py = mid.dy + math.sin(a) * ((rr + wobble) * 0.72);
        if (p == 0) {
          path.moveTo(px, py);
        } else {
          path.lineTo(px, py);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  void _paintCaustics(Canvas canvas, Size size) {
    final strength = liquid.caustic.clamp(0.0, 1.0);
    if (strength <= 0) return;
    final at = liquid.animated ? t : 0.0;
    for (var i = 0; i < 4; i++) {
      final px = size.width *
              (0.2 + 0.6 * (0.5 + 0.5 * math.sin(at * 1.7 + i * 1.9))) -
          motion.dx * 0.35;
      final py = size.height *
              (0.2 + 0.6 * (0.5 + 0.5 * math.cos(at * 1.3 + i * 2.3))) -
          motion.dy * 0.35;
      final r = size.shortestSide * (0.08 + 0.10 * liquid.thickness);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.16 * strength),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: Offset(px, py), radius: r));
      canvas.drawCircle(Offset(px, py), r, paint);
    }
  }

  void _paintSpecular(Canvas canvas, Size size) {
    final strength = liquid.specular.clamp(0.0, 1.0);
    if (strength <= 0) return;
    final moveX = motion.dx / math.max(size.width, 1) * 0.9;
    final moveY = motion.dy / math.max(size.height, 1) * 0.9;
    final at = liquid.animated ? t : 0.0;
    final lx = (liquid.lightX +
            liquid.ripple * 0.08 * math.sin(at * 2 * math.pi) -
            moveX)
        .clamp(0.0, 1.0);
    final ly = (liquid.lightY +
            liquid.ripple * 0.1 * math.cos(at * 1.3 * math.pi) -
            moveY)
        .clamp(0.0, 1.0);
    final center = Offset(size.width * lx, size.height * ly);
    final radius = size.longestSide * (0.18 + 0.22 * liquid.thickness);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.55 * strength),
          Colors.white.withValues(alpha: 0.12 * strength),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const [0, 0.45, 1],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  void _paintEdges(Canvas canvas, Size size) {
    if (liquid.edgeHighlight) {
      final band = size.shortestSide * (0.05 + 0.08 * liquid.thickness);
      final paint = Paint();
      paint.shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.34),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, band));
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, band), paint);
    }
    if (liquid.innerShadow) {
      final band = size.shortestSide * (0.08 + 0.10 * liquid.thickness);
      final paint = Paint();
      paint.shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          Colors.black.withValues(alpha: 0.30),
          Colors.black.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTWH(0, size.height - band, size.width, band));
      canvas.drawRect(
          Rect.fromLTWH(0, size.height - band, size.width, band), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LiquidGlassPainter oldDelegate) {
    return oldDelegate.liquid.animated != liquid.animated ||
        oldDelegate.t != t ||
        oldDelegate.motion != motion ||
        oldDelegate.cornerRadius != cornerRadius;
  }
}

class _EffectWidget extends StatefulWidget {
  const _EffectWidget({required this.effect});

  final ThemeEffect effect;

  @override
  State<_EffectWidget> createState() => _EffectWidgetState();
}

class _EffectWidgetState extends State<_EffectWidget>
    with SingleTickerProviderStateMixin {
  /// 全局动画预算：主题包一上来挂十几个带 repeat 的 effect widget，
  /// 每个都 60fps 重建，手机上直接卡死。这里只允许少量特效有本地循环动画，
  /// 其余保持静态；需要“动起来”的桂花等，位置仍由桥接层按帧更新。
  static const _maxConcurrentAnimations = 4;
  static int _runningAnimations = 0;

  late final AnimationController _controller;
  bool _ownsAnimation = false;
  Future<String>? _imageFuture;

  void _prepareImage() {
    final p = widget.effect.imagePath;
    _imageFuture = (p != null && p.isNotEmpty)
        ? ThemeEffectsController.instance.resolveImagePath(p)
        : null;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.effect.durationMs),
    );
    _prepareImage();
    _syncAnimation();
  }

  void _syncAnimation() {
    final want = widget.effect.animation != 'none';
    if (want &&
        !_ownsAnimation &&
        _runningAnimations < _maxConcurrentAnimations) {
      _ownsAnimation = true;
      _runningAnimations++;
      _controller.repeat();
    } else if (!want && _ownsAnimation) {
      _ownsAnimation = false;
      _runningAnimations--;
      _controller.stop();
    }
  }

  @override
  void didUpdateWidget(covariant _EffectWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.effect.durationMs != widget.effect.durationMs) {
      _controller.duration = Duration(milliseconds: widget.effect.durationMs);
    }
    if (oldWidget.effect.imagePath != widget.effect.imagePath) {
      _prepareImage();
    }
    _syncAnimation();
  }

  @override
  void dispose() {
    if (_ownsAnimation) _runningAnimations--;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.effect;
    Widget child;
    if (e.paint != null) {
      child = _PaintEffect(effect: e);
    } else if (e.imagePath != null && e.imagePath!.isNotEmpty) {
      child = FutureBuilder<String>(
        future: _imageFuture ??
            ThemeEffectsController.instance.resolveImagePath(e.imagePath!),
        builder: (context, snap) {
          final host = snap.data ?? '';
          if (host.isNotEmpty) {
            return Image.file(
              File(host),
              fit: e.fit == 'fill'
                  ? BoxFit.fill
                  : e.fit == 'cover'
                      ? BoxFit.cover
                      : BoxFit.contain,
              errorBuilder: (_, __, ___) => _iconOrText(e),
            );
          }
          return _iconOrText(e);
        },
      );
    } else {
      child = _iconOrText(e);
    }
    // 闭包引用局部变量时按引用捕获：先把当前 child 存成不可变局部变量，
    // 否则闭包拿到的是重新赋值后的 child（AnimatedBuilder 自身），
    // 会无限嵌套并触发 Stack Overflow。
    final baseChild = child;
    if (e.animation != 'none') {
      child = AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          var offset = Offset.zero;
          var angle = e.rotation * math.pi / 180;
          var scale = e.scale;
          var opacity = e.opacity;
          switch (e.animation) {
            case 'float':
              offset = Offset(0, 6 * math.sin(t * 2 * math.pi));
            case 'bounce':
              offset = Offset(0, -10 * math.sin(t * math.pi));
            case 'spin':
              angle += t * 2 * math.pi;
            case 'fade':
              opacity = e.opacity *
                  (0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * 2 * math.pi)));
            case 'pulse':
              scale = e.scale * (0.85 + 0.15 * math.sin(t * 2 * math.pi));
            case 'shake':
              offset = Offset(8 * math.sin(t * 2 * math.pi), 0);
            case 'wiggle':
              angle += 0.18 * math.sin(t * 2 * math.pi);
            case 'blink':
              opacity = e.opacity * (t < 0.5 ? 1 : 0.12);
            case 'slide':
              offset = Offset(-e.width * (1 - t), 0);
          }
          return Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: offset,
              child: Transform.rotate(
                angle: angle,
                child: Transform.scale(scale: scale, child: baseChild),
              ),
            ),
          );
        },
      );
    } else if (e.opacity < 1 || e.scale != 1 || e.rotation != 0) {
      child = Opacity(
        opacity: e.opacity.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: e.rotation * math.pi / 180,
          child: Transform.scale(scale: e.scale, child: child),
        ),
      );
    }
    if (e.interactive) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ThemeEffectsController.instance.emitEffectTap(e.id),
        onLongPress: () =>
            ThemeEffectsController.instance.emitEffectLongPress(e.id),
        child: child,
      );
    } else {
      child = IgnorePointer(child: child);
    }
    return child;
  }

  Widget _iconOrText(ThemeEffect e) {
    if (e.text != null && e.text!.isNotEmpty) {
      final bg = e.textBackgroundColor ?? e.color.withValues(alpha: 0.16);
      final border = e.textBorderColor ?? e.color.withValues(alpha: 0.6);
      // 气泡文本必须在给定 width/height 内显示；空间不足时整体缩放而不是
      // 触发 RenderFlex/Text overflow（红黄 Overflow 警告斜线）。
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: e.textPadding,
            vertical: e.textPadding * 0.5,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(e.textRadius),
            border: Border.all(
              color: border,
              width: e.textBorderWidth,
            ),
          ),
          child: Text(
            e.text!,
            maxLines: 2,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: e.color,
              fontSize: e.fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    return Icon(
      ThemeEffectBridge.icon(e.icon),
      size: e.width < e.height ? e.width : e.height,
      color: e.color,
    );
  }
}

/// 组件锚点跟踪器：包在 GlassPanel/GlassCard 外面，自动上报组件在屏幕上的
/// 位置给 ThemeComponentRegistry，主题 JS 就能通过 DSHTheme.queryComponents
/// 查到真实坐标。它不做任何绘制，不影响性能。
class ComponentAnchorTracker extends StatefulWidget {
  const ComponentAnchorTracker({
    super.key,
    required this.type,
    required this.child,
    this.index,
  });

  final String type;
  final int? index;
  final Widget child;

  @override
  State<ComponentAnchorTracker> createState() => _ComponentAnchorTrackerState();
}

class _ComponentAnchorTrackerState extends State<ComponentAnchorTracker> {
  final _key = GlobalKey();
  String _page = 'default';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _register());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _page = ModalRoute.of(context)?.settings.name ?? 'default';
    WidgetsBinding.instance.addPostFrameCallback((_) => _register());
  }

  void _register() {
    final render = _key.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.attached) return;
    final box = render.localToGlobal(Offset.zero) & render.size;
    ThemeComponentRegistry.instance.register(
      _page,
      widget.type,
      widget.index ?? 0,
      box,
    );
  }

  @override
  void dispose() {
    ThemeComponentRegistry.instance.unregister(
      _page,
      widget.type,
      widget.index ?? 0,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _key,
      child: widget.child,
    );
  }
}
