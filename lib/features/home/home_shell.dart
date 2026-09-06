import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/glass.dart';
import '../ai/pages/ai_chat_page.dart';
import '../panels/pages/panel_list_page.dart';
import '../settings/pages/settings_page.dart';
import '../settings/providers/settings_provider.dart';
import '../terminal/pages/terminal_page.dart';
import '../crons/pages/cron_list_page.dart';
import 'module_hub_page.dart';
import 'home_navigation_provider.dart';

/// 主壳：全面屏内容 + 悬浮液体玻璃菜单 + 全局悬浮 AI。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  /// 启动页只应用一次：之后用户点导航栏就该由他说话。
  bool _startupApplied = false;

  /// 菜单是否伸出来。默认收起——菜单常驻太占地方，
  /// 手指从屏幕底边往上一拉就出来，点别处又收回去。
  bool _navOpen = false;

  /// 上拉手势的起点（Listener 自己记，不走手势竞技场）。
  double? _dragStartY;
  double? _dragStartX;

  /// 上拉之后手指还没松：这一段属于"拖拽选页"，横向滑动实时切换高亮。
  bool _dragging = false;

  /// 拖拽中当前落在哪个标签上。用来判断"有没有换格"，只为决定震不震。
  int? _dragIndex;

  /// 横向是否真的动过。没动过就只是"把菜单拉出来"，松手后菜单要留着。
  bool _dragMovedX = false;

  void _openNav() {
    if (_navOpen) return;
    // 键盘顶着的时候菜单会被挡（之前干脆整条不显示，于是"拉出来了却看不见、
    // 切页也切不动"）。正确做法是先把键盘收掉，再让菜单浮上来。
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _navOpen = true);
  }

  void _closeNav() {
    if (!_navOpen) return;
    setState(() {
      _navOpen = false;
      _dragging = false;
      _dragIndex = null;
    });
  }

  /// 拖拽中把横坐标换算成标签下标：**直接切页**，不做额外的预览层。
  ///
  /// 用户要的是"菜单跟着手指走、页面跟着实时换"，所以这里改的是真正的
  /// tab index——菜单的高亮本来就跟着它动，不需要再额外画一套预览高亮。
  void _previewFromX(double dx, double width) {
    // 菜单条左右各留 12 的边距，这里按同样的可视区域换算，
    // 手指落在哪个按钮上就选哪个，不会差半格。
    const margin = 12.0;
    final usable = (width - margin * 2).clamp(1.0, double.infinity);
    final slot = usable / _items.length;
    final ratio = ((dx - margin) / usable).clamp(0.0, 0.9999);
    var index = (ratio * _items.length).floor().clamp(0, _items.length - 1);
    // 迟滞：手指停在两格交界处时，指针一像素的抖动会让下标来回跳，
    // 页面就跟着"一闪一闪"。要换格必须越过边界 10 像素，
    // 这样贴着边界抖也稳在原来那一格。
    final current = _dragIndex;
    if (current != null && index != current) {
      final boundary = margin + slot * (index > current ? index : current);
      if ((dx - boundary).abs() < 10) return;
    }
    if (_dragIndex == index) return;
    HapticFeedback.selectionClick();
    _dragIndex = index;
    ref.read(homeTabIndexProvider.notifier).state = index;
  }

  /// 松手：横向滑过就落到预选页并收起菜单；没滑过就把菜单留在屏幕上。
  /// 拖拽兜底：超时就自己收尾。
  ///
  /// 上拉区就在系统"上滑回桌面"的手势带旁边。系统一旦判定这是它的手势，
  /// 会直接把触摸抢走：APP 收不到 up 也收不到 cancel，_dragging 就永久卡在
  /// true。后果全都对得上用户的描述——把手不见了（拖拽中不画把手）、
  /// 菜单点不动、手指随便一划就跳页（一闪一闪），而 AI 悬浮窗挂在另一棵
  /// Stack 上，不受影响所以照常能点。
  ///
  /// 1.5 秒：既能让卡死状态自己解开，又不会把正常的慢拖拽掐断。
  ///
  /// 试过 700ms，太紧了——debug 包一帧动辄四五十毫秒，真机上拖慢一点、
  /// 或者赶上一次卡顿，移动事件之间就能空出大半秒，结果手指还在屏幕上
  /// 菜单自己收了。宁可多等一会儿：卡死本来就是异常路径。
  static const _dragWatchdog = Duration(milliseconds: 1500);
  Timer? _dragTimer;

  void _armDragWatchdog() {
    _dragTimer?.cancel();
    _dragTimer = Timer(_dragWatchdog, () {
      if (!mounted || !_dragging) return;
      debugPrint('[QL][nav] 拖拽超时兜底：指针事件丢了，强制收尾');
      _endDrag();
    });
  }

  void _endDrag() {
    _dragTimer?.cancel();
    _dragTimer = null;
    if (!_dragging) {
      _dragStartY = null;
      _dragStartX = null;
      return;
    }
    final moved = _dragMovedX;
    _dragStartY = null;
    _dragStartX = null;
    if (moved) {
      // 页面在拖动过程中已经切过去了，这里只负责收菜单。
      HapticFeedback.mediumImpact();
      setState(() {
        _dragging = false;
        _dragIndex = null;
        _navOpen = false;
      });
      return;
    }
    // 只是把菜单拉出来：留着让用户慢慢点。
    setState(() {
      _dragging = false;
      _dragIndex = null;
    });
  }

  @override
  void dispose() {
    _dragTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 切后台时把拖拽状态清干净。
  ///
  /// 从屏幕最下沿上拉，十次里总有一两次被系统的"上滑回桌面"截走：
  /// APP 直接被切走，指针 up 永远不会来。回到 APP 时如果不复位，
  /// 菜单就停在"拖拽中"这个半死状态里。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    if (!_dragging && _dragStartY == null) return;
    _dragTimer?.cancel();
    _dragTimer = null;
    _dragStartY = null;
    _dragStartX = null;
    _dragMovedX = false;
    if (mounted && _dragging) {
      setState(() {
        _dragging = false;
        _dragIndex = null;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 设置是异步读盘的，这里监听到第一个有效值再落位。
    ref.listenManual(settingsProvider, (previous, next) {
      if (_startupApplied) return;
      _startupApplied = true;
      final index = next.startupTabIndex.clamp(0, _items.length - 1);
      if (ref.read(homeTabIndexProvider) == index) return;
      // 构建期间不能直接改 provider，挪到帧后。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(homeTabIndexProvider.notifier).state = index;
      });
    });
  }

  static const _items = <_NavItem>[
    _NavItem(Icons.schedule_outlined, Icons.schedule, '任务'),
    _NavItem(Icons.dns_outlined, Icons.dns, '面板'),
    _NavItem(Icons.auto_awesome_outlined, Icons.auto_awesome, 'AI'),
    _NavItem(Icons.terminal_outlined, Icons.terminal, '终端'),
    _NavItem(Icons.grid_view_outlined, Icons.grid_view, '管理'),
    _NavItem(Icons.settings_outlined, Icons.settings, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(homeTabIndexProvider);
    final media = MediaQuery.of(context);
    final bottomInset = media.padding.bottom;
    // 键盘弹起时**不藏菜单**，而是让它连同拉出区一起浮到键盘上沿。
    //
    // 以前是 keyboard 就整条不渲染：结果"上拉把菜单拉出来了却看不见"，
    // 而且拉出区落在键盘底下，触摸全被输入法吃掉，横滑切页自然也没反应。
    final keyboardInset = media.viewInsets.bottom;
    final keyboard = keyboardInset > 80;
    // 菜单条自己的位置（下面幕和菜单都用这一份，避免两处各算一遍算歪）。
    const navBarHeight = 58.0;
    final navBarBottom =
        keyboard ? keyboardInset + 6 : 4 + bottomInset * 0.15;

    return Scaffold(
      // 内容铺到系统栏之下，导航条自己浮在上面。
      extendBody: true,
      extendBodyBehindAppBar: true,
      // 每个标签页内部还有一层 GlassScaffold，让它去避让键盘。
      // 外壳如果也避让，输入框会被抬两次直接飞出屏幕。
      resizeToAvoidBottomInset: false,
      body: GlassBackdrop(
        child: Stack(
          children: [
            Positioned.fill(
              // === Stack 子节点必须带 key ===
              // 这一层曾经引发一个非常隐蔽的死锁：菜单展开时会往 Stack 里
              // **插入**一层幕，子节点个数从 3 变 4。没有 key 的多子节点按
              // **下标**配对，于是"拉出区的 Listener"那个 Element 被拿去承载
              // 了"幕的 Listener"——手指还按着，后续的 move/up 却被投递给了
              // 换过内容的旧 RenderObject，拉出区的 onPointerUp 永远收不到。
              // _dragging 就此永久卡在 true：_NavButton 的 onTap 是
              // `dragging ? null : …`，于是"菜单出现了却点不了"；拉出区又一直
              // 铺满全屏跟着手指切页，看着就是"一闪一闪"。
              key: const ValueKey('home-content'),
              child: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: Column(
                  children: [
                    Expanded(
                      child: IndexedStack(
                        index: index,
                        children: const [
                          CronListPage(),
                          PanelListPage(),
                          AiChatPage(),
                          TerminalPage(),
                          ModuleHubPage(),
                          SettingsPage(),
                        ],
                      ),
                    ),
                    // 不给底部留任何额外高度：菜单是浮层，把手也是浮层，
                    // 让内容一直铺到屏幕最下沿（各页列表自己留了内边距，
                    // 最后一条不会被把手压住）。之前这里留 30+ 像素，
                    // 屏幕底下就白空一条。
                    const SizedBox.shrink(),
                  ],
                ),
              ),
            ),
            // 菜单展开时铺一层**只旁听、不拦截**的幕：碰到内容区就把菜单收回去，
            // 事件照旧传给下面的页面。
            //
            // 这里以前是 GestureDetector(behavior: opaque)：它把整块屏幕的触摸
            // 全吃掉，于是"菜单一出来整个 APP 就失灵"——点卡片没反应、点 ⋮ 菜单
            // 不弹、列表上下滑都不动，必须先瞎点一下把菜单关掉才能操作。
            // Listener + translucent 只是旁听原始指针事件：自己收到 down，
            // 同时返回"没命中"，Stack 会继续把事件派给下面的页面。
            if (_navOpen)
              Positioned(
                key: const ValueKey('home-scrim'),
                left: 0,
                right: 0,
                top: 0,
                // 幕**不能盖住菜单条自己**（Positioned.fill 就会）。
                // 盖住的后果：点一个标签，幕先收起菜单、菜单条同帧被挪走，
                // 标签的 tap 落空——用户看到的是"菜单出现后点不了"。
                bottom: navBarBottom + navBarHeight + 6,
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) => _closeNav(),
                  child: const SizedBox.expand(),
                ),
              ),
            // 这里原来还有一排"面板切换 chips"（选中的那个带绿勾）：
            // 菜单一拉出来它就浮在上面多占一层，用户明确说不要。
            // 切面板去"面板"页，那里本来就有完整列表。
            // 底边的拉出区：菜单收起时这条带子负责接"往上拉"，
            // 拉出来手指没松时继续负责"左右滑选页"。
            //
            // 三个坑，都踩过了：
            // 1) 不能贴着屏幕最底边。手机是全屏手势导航，最下面几十像素属于
            //    系统的"上滑回桌面"，从那里起滑事件根本到不了 APP。所以整条
            //    带子往上挪，让它落在系统手势区之上。
            // 2) 不能用 GestureDetector 的竖向拖拽。下面盖着各页的 ListView，
            //    手势竞技场里列表会赢，上拉十次九次没反应。Listener 只旁听
            //    原始指针事件，不参与竞争。
            // 3) 必须 translucent。opaque 会把下面输入框、按钮的点击全吞掉。
            if (!_navOpen || _dragging)
              Positioned(
                key: const ValueKey('home-pull-strip'),
                left: 0,
                right: 0,
                // 这条**不可见**的拉出区不能跟着菜单一起贴边：
                // 屏幕最下面那几十像素属于系统"上滑回桌面"，从那里起滑
                // 事件根本到不了 APP（实测把它压到 0.15 就再也拉不出菜单了）。
                // 菜单条本身可以贴边，拉出区必须留在手势区之上。
                // 键盘在的时候贴到键盘上沿（+4 呼吸位），否则留在系统手势区之上。
                // ===== 拖拽时必须 top+bottom 都给，不能只给 top =====
                //
                // 这是"整个 APP 点不动"的真凶。Stack 里的 Positioned 只写
                // top（bottom 和 height 都是 null）时，孩子拿到的竖向约束是
                // **无限**的，而里面是 SizedBox.expand()：
                //   RenderConstrainedBox object was given an infinite size
                //   during layout.
                // performLayout 抛异常后，框架在最近的 relayout boundary 处
                // 把异常吞掉并清掉那一层的脏标记，可失败的子树自己的
                // _needsLayout 永远留在 true —— 它再也不会被 layout，也不会
                // 被 paint。于是：
                //   · 把手和菜单条直接消失（NEEDS-PAINT 一直没清）；
                //   · 任何一次命中测试走到这棵子树就撞上
                //     'RenderBox was not laid out' 断言，**整棵树**的命中测试
                //     当场中断 → 点哪儿都没反应；
                //   · 只有 AI 悬浮球还能点：它在 MaterialApp.builder 的另一个
                //     Stack 分支里，命中顺序上排在前面，够不到这棵坏子树。
                //
                // 为什么"点把手拉出菜单"没事、"上拉后横滑选页"必炸：
                // 前者 _dragging 一直是 false，收尾时 _navOpen=true 让整条
                // 拉出区从树上摘掉，坏掉的 render object 跟着销毁，树自愈了；
                // 后者收尾时 _navOpen=false，拉出区**留在树上**，那些永久脏
                // 的节点就一直留着毒害命中测试。
                bottom: _dragging
                    ? 0
                    : (keyboard ? keyboardInset + 4 : bottomInset * 0.45),
                top: _dragging ? 0 : null,
                height: _dragging ? null : 96,
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) {
                    _dragStartY = event.position.dy;
                    _dragStartX = event.position.dx;
                    _dragMovedX = false;
                  },
                  onPointerMove: (event) {
                    final startY = _dragStartY;
                    if (startY == null) return;
                    if (!_navOpen) {
                      // 往上 8 像素就算"拉"：越早识别越不容易被别人抢走。
                      if (startY - event.position.dy > 8) {
                        HapticFeedback.lightImpact();
                        // 键盘在的话先收掉：不然菜单被键盘压着，
                        // "拉出来了但看不见"就是这么来的。
                        FocusManager.instance.primaryFocus?.unfocus();
                        setState(() {
                          _navOpen = true;
                          _dragging = true;
                          _dragIndex = ref.read(homeTabIndexProvider);
                        });
                        _armDragWatchdog();
                      }
                      return;
                    }
                    if (!_dragging) return;
                    // 每来一个移动就续一次：手指还在动就不算丢事件。
                    _armDragWatchdog();
                    final startX = _dragStartX ?? event.position.dx;
                    // ==== "横滑选页" 的门槛：光看横向位移是不够的 ====
                    //
                    // 只用绝对阈值（哪怕放到 36）会把**长按时的手抖**判成横滑：
                    // 手指在把手上停一秒多，横向轻轻蹭出三四十像素太容易了。
                    // 一旦误判，_previewFromX 就开始跳页（看着就是"菜单一闪、
                    // 页面乱跳"），松手 _endDrag 又把菜单收掉——正好是
                    // "长按滑动菜单，菜单只闪一下不完整显示"。
                    //
                    // 所以加两道：①得先真的往上拉出 40 像素（手抖拉不出来）；
                    // ②再横向走 48 像素以上。真要横滑选页的人一定同时满足。
                    final pulled = startY - event.position.dy;
                    if (pulled > 40 &&
                        (event.position.dx - startX).abs() > 48) {
                      _dragMovedX = true;
                    }
                    // 只有真的横向滑了才切页。
                    // 少了这个判断，"直着往上拉"也会被换算成一个横坐标，
                    // 于是手指一抬页面就跳到起滑点正上方的那个标签去了
                    // （从屏幕中间拉必跳到第 4 格）——纯拉菜单不该切页。
                    if (!_dragMovedX) return;
                    _previewFromX(event.position.dx, media.size.width);
                  },
                  onPointerUp: (_) => _endDrag(),
                  onPointerCancel: (_) => _endDrag(),
                  child: _dragging
                      ? const SizedBox.expand()
                      // 只有**把手本身**接 tap，整条带子不接。
                      //
                      // 之前整条带子都 onTap: _openNav，结果它压在输入框、
                      // 发送键、快捷键条上面：手势竞技场里它在最上层，
                      // 点"发送"会变成"弹出菜单"，消息发不出去。
                      // 竖向拖拽仍由外层 Listener 负责（Listener 只旁听、
                      // 不参与竞技场，所以不会抢别人的点击）。
                      // 把手贴在这条区域的**最下沿**，而且点击区只有把手自己
                      // 那么大。
                      //
                      // 页面底部现在贴边了，输入框一直压到屏幕最下面，
                      // 而这条区域正好盖在它上面：之前整条/靠上都接 tap，
                      // 于是点输入框、点发送键都变成"弹出菜单"，消息发不出去。
                      // 竖向上拉仍由外层 Listener 负责——Listener 只旁听
                      // 原始指针事件，不参与手势竞技场，不会抢别人的点击。
                      : Align(
                          alignment: Alignment.bottomCenter,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _openNav,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 22,
                                vertical: 5,
                              ),
                              child: _NavHandle(),
                            ),
                          ),
                        ),
                ),
              ),
            AnimatedPositioned(
              key: const ValueKey('home-navbar'),
              // 拖着手指拉出来的时候不做动画：手指已经在屏幕上了，
              // 菜单要立刻在指尖下出现，慢 220ms 就会看到"先没有、再滑上来"
              // 的一闪。点开则保留缓动。
              duration: Duration(milliseconds: _dragging ? 0 : 220),
              curve: Curves.easeOutCubic,
              left: 12,
              right: 12,
              // 收起时整条沉到屏幕外，只有把手露在外面。
              // 贴边：只留 4px 呼吸位。系统小白条本身是半透明浮层，
              // 菜单压在它下缘也不挡操作（图标中心离白条还有 30+ 像素）。
              bottom: !_navOpen ? -110 : navBarBottom,
              child: _GlassNavBar(
                items: _items,
                index: index,
                dragging: _dragging,
                onSelected: (i) {
                  // 点着切页时菜单要留着：用户经常连点几个页面看一圈。
                  // 想收起就点页面上任意一处（那层幕负责收）。
                  ref.read(homeTabIndexProvider.notifier).state = i;
                  HapticFeedback.selectionClick();
                },
                onCollapse: _closeNav,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.selectedIcon, this.label);

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// 液体玻璃悬浮菜单：整条浮在内容之上，选中项有一枚流动的高光胶囊。
class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({
    required this.items,
    required this.index,
    required this.onSelected,
    required this.onCollapse,
    this.dragging = false,
  });

  final List<_NavItem> items;
  final int index;
  final ValueChanged<int> onSelected;
  final VoidCallback onCollapse;

  /// 用户正拖着手指选页：高光跟手，按钮本身不接点击（手指还没松）。
  final bool dragging;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      // 在菜单条本身往下甩也收起。
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 120) {
          onCollapse();
        }
      },
      child: GlassPanel(
        radius: 26,
        blur: Glass.blurStrong,
        shadowY: 10,
        child: SizedBox(
          height: 58,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final slot = constraints.maxWidth / items.length;
              return Stack(
                children: [
                  // 流动高光：切换时滑过去，这是"液体"的关键。
                  // 拖拽选页时要跟手，动画就得短，不然手指到了高光还在路上。
                  AnimatedPositioned(
                    duration: Duration(milliseconds: dragging ? 110 : 320),
                    curve: Curves.easeOutCubic,
                    left: slot * index + 6,
                    top: 5,
                    width: slot - 12,
                    height: 48,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            scheme.primary.withValues(alpha: 0.26),
                            scheme.primary.withValues(alpha: 0.10),
                          ],
                        ),
                        border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < items.length; i++)
                        Expanded(
                          child: _NavButton(
                            item: items[i],
                            selected: i == index,
                            // **永远可点**。这里以前是 `dragging ? null : …`，
                            // 于是只要 _dragging 卡住（系统把上滑手势抢走、
                            // APP 被切后台，指针 up/cancel 就再也不来了），
                            // 整条菜单就变成一排点不动的摆设——用户看到的是
                            // "菜单出来了但点不了，只有 AI 悬浮窗还能点"。
                            // 拖拽中手指本来就按着，物理上不可能同时产生 tap，
                            // 所以这个门本来就没必要。
                            onTap: () => onSelected(i),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 收起状态下露在屏幕底边的把手：一条短横杠，暗示"这里能往上拉"。
class _NavHandle extends StatelessWidget {
  const _NavHandle();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 46,
      height: 4,
      decoration: BoxDecoration(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;

  /// null = 拖拽选页中，按钮不接点击（手指还按着，点击没有意义）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              duration: const Duration(milliseconds: 220),
              scale: selected ? 1.12 : 1,
              child: Icon(
                selected ? item.selectedIcon : item.icon,
                size: 21,
                color: color,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              item.label,
              style: TextStyle(
                fontSize: 10.5,
                height: 1,
                color: color,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
