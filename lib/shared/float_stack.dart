import 'package:flutter/foundation.dart';

/// 悬浮窗层级栈：谁最后被"碰"到，谁画在最上面。
///
/// 为什么需要它：AI 聊天窗和浏览器窗都挂在 `MaterialApp.builder` 的同一个
/// [Stack] 里。Stack 的绘制顺序就是 children 的书写顺序，写死的话必然有一个
/// 永远压着另一个——浏览器压着聊天窗时，用户点聊天窗只能点到浏览器；
/// 反过来又会挡住网页上的验证码。所以顺序必须是运行时可变的。
///
/// 规则只有两条，和桌面窗口管理器一致：
///  1. 新弹出来的窗口自动置前（[raise]）；
///  2. 点到哪个窗口，那个窗口置前。
///
/// 用普通的 [ChangeNotifier] 而不是 Riverpod：浏览器那一半是
/// `ValueNotifier` 单例体系，AI 那一半是 Riverpod，放在这里两边都能用，
/// 也不用把 UI 依赖倒灌进 engine 层。
class FloatStack extends ChangeNotifier {
  FloatStack._();

  static final FloatStack instance = FloatStack._();

  /// AI 聊天窗（含提问窗、画布窗——它们跟着聊天窗一起升降）。
  static const String ai = 'ai';

  /// 浏览器窗（含它自己的抓包脚本编辑器）。
  static const String browser = 'browser';

  /// 从底到顶。默认让浏览器在上：它一亮出来就是要用户在上面点验证/登录的。
  final List<String> _order = <String>[ai, browser];

  List<String> get order => List<String>.unmodifiable(_order);

  /// 层内序号，越大越靠上。不在栈里返回 -1。
  int indexOf(String id) => _order.indexOf(id);

  bool isTop(String id) => _order.isNotEmpty && _order.last == id;

  /// 置前。已经在最上面就什么都不做——每次触摸都通知一遍会让整层白重建。
  void raise(String id) {
    if (_order.isNotEmpty && _order.last == id) return;
    _order.remove(id);
    _order.add(id);
    notifyListeners();
  }
}
