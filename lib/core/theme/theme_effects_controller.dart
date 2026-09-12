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

/// 一个覆盖在 Flutter 组件上方的万能效果图层元素。
class ThemeEffect {
  const ThemeEffect({
    required this.id,
    this.kind = 'image',
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
    this.borderWidth = 2,
    this.glowRadius = 8,
    this.glowOpacity = 0.6,
    this.fontSize = 14,
    this.speechTail = false,
  });

  final String id;

  /// image / border；border 是原生边缘发光，不依赖图片。
  final String kind;

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

  /// none / float / bounce / spin
  final String animation;

  /// contain / fill / cover
  final String fit;
  final double fontSize;

  /// border 效果专用。
  final double borderWidth;
  final double glowRadius;
  final double glowOpacity;
  final bool speechTail;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
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
        'borderWidth': borderWidth,
        'glowRadius': glowRadius,
        'glowOpacity': glowOpacity,
        'fontSize': fontSize,
        'speechTail': speechTail,
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

  List<ThemeEffect> get effects => List.unmodifiable(_effects.values);

  ThemeEffect? byId(String id) => _effects[id];

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

    final direct = await host(path);
    if (direct.isNotEmpty && File(direct).existsSync()) return direct;

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
        if (retry.isNotEmpty && File(retry).existsSync()) return retry;
      }
    }
    return direct;
  }

  void updateOverlayOffset(Offset offset) {
    if (overlayOffset == offset) return;
    overlayOffset = offset;
    notifyListeners();
  }

  void upsert(ThemeEffect effect) {
    _effects[effect.id] = effect;
    notifyListeners();
  }

  void remove(String id) {
    if (_effects.remove(id) != null) notifyListeners();
  }

  void clear() {
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
      kind: map['kind']?.toString() ?? 'image',
      imagePath: map['imagePath']?.toString(),
      icon: map['icon']?.toString(),
      text: map['text']?.toString(),
      x: (map['x'] as num?)?.toDouble() ?? 0,
      y: (map['y'] as num?)?.toDouble() ?? 0,
      width: (map['width'] as num?)?.toDouble() ?? 80,
      height: (map['height'] as num?)?.toDouble() ?? 80,
      color: _color(map['color']?.toString()) ?? const Color(0xFFFF9EC4),
      animation: map['animation']?.toString() ?? 'none',
      fit: map['fit']?.toString() ?? 'contain',
      borderWidth: (map['borderWidth'] as num?)?.toDouble() ?? 2,
      glowRadius: (map['glowRadius'] as num?)?.toDouble() ?? 8,
      glowOpacity: (map['glowOpacity'] as num?)?.toDouble() ?? 0.6,
      fontSize: (map['fontSize'] as num?)?.toDouble() ?? 14,
      speechTail: map['speechTail'] == true,
    );
  }

  static Color? _color(Object? v) {
    if (v is int) return Color(v);
    if (v is String) {
      final s = v.replaceFirst('#', '');
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
          child: IgnorePointer(
            child: _ThemeOverlayContent(),
          ),
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
        final effects = ThemeEffectsController.instance.effects;
        if (effects.isEmpty) return const SizedBox.expand();
        final origin = ThemeEffectsController.instance.overlayOffset;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final e in effects)
              Positioned(
                left: e.x - origin.dx,
                top: e.y - origin.dy,
                width: e.width,
                height: e.height,
                child: _EffectWidget(effect: e),
              ),
          ],
        );
      },
    );
  }
}

/// 原生边缘发光：主题包不需要再拿一张图硬拉伸，效果精确贴住组件边缘。
class _BorderEffect extends StatelessWidget {
  const _BorderEffect({required this.effect});

  final ThemeEffect effect;

  @override
  Widget build(BuildContext context) {
    final e = effect;
    final radius = BorderRadius.circular(math.min(e.width, e.height) * 0.12);
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: e.color,
            width: e.borderWidth,
          ),
          boxShadow: [
            BoxShadow(
              color: e.color.withValues(alpha: e.glowOpacity),
              blurRadius: e.glowRadius,
              spreadRadius: 0,
            ),
          ],
        ),
      ),
    );
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
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.effect.animation != 'none') {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.effect;
    if (e.kind == 'border') return _BorderEffect(effect: e);
    Widget child;
    if (e.imagePath != null && e.imagePath!.isNotEmpty) {
      child = FutureBuilder<String>(
        future: ThemeEffectsController.instance.resolveImagePath(e.imagePath!),
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
    if (e.animation == 'none') return child;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        Offset offset = Offset.zero;
        double angle = 0;
        switch (e.animation) {
          case 'float':
            offset = Offset(0, 6 * math.sin(t * 2 * math.pi));
          case 'bounce':
            offset = Offset(0, -10 * (1 - t) * t * 4).scale(1, 1);
            offset = Offset(0, -10 * math.sin(t * math.pi));
          case 'spin':
            angle = t * 2 * math.pi;
        }
        return Transform.translate(
          offset: offset,
          child: Transform.rotate(angle: angle, child: child),
        );
      },
    );
  }

  Widget _iconOrText(ThemeEffect e) {
    if (e.text != null && e.text!.isNotEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: e.color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: e.color.withValues(alpha: 0.6)),
        ),
        child: Text(
          e.text!,
          style: TextStyle(
            color: e.color,
            fontSize: e.fontSize,
            fontWeight: FontWeight.w600,
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
