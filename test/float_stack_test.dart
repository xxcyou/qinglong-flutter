import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/shared/float_stack.dart';

void main() {
  // 单例：每个用例先复位成默认顺序，免得互相污染。
  setUp(() {
    FloatStack.instance.raise(FloatStack.ai);
    FloatStack.instance.raise(FloatStack.browser);
  });

  test('默认浏览器在上（它一亮就是要用户在上面点）', () {
    expect(FloatStack.instance.isTop(FloatStack.browser), isTrue);
    expect(FloatStack.instance.order.length, 2);
  });

  test('raise 把窗口挪到栈顶', () {
    FloatStack.instance.raise(FloatStack.ai);
    expect(FloatStack.instance.isTop(FloatStack.ai), isTrue);
    expect(FloatStack.instance.isTop(FloatStack.browser), isFalse);
  });

  test('两个窗口能来回置前', () {
    FloatStack.instance.raise(FloatStack.ai);
    FloatStack.instance.raise(FloatStack.browser);
    expect(FloatStack.instance.isTop(FloatStack.browser), isTrue);
    FloatStack.instance.raise(FloatStack.ai);
    expect(FloatStack.instance.isTop(FloatStack.ai), isTrue);
  });

  test('raise 不丢窗口、不产生重复项', () {
    FloatStack.instance.raise(FloatStack.ai);
    FloatStack.instance.raise(FloatStack.ai);
    final order = FloatStack.instance.order;
    expect(order.length, 2);
    expect(order.toSet().length, 2);
  });

  test('已在顶层时不再通知（避免整层白重建）', () {
    FloatStack.instance.raise(FloatStack.ai);
    var notified = 0;
    void listener() => notified++;
    FloatStack.instance.addListener(listener);
    FloatStack.instance.raise(FloatStack.ai);
    expect(notified, 0);
    FloatStack.instance.raise(FloatStack.browser);
    expect(notified, 1);
    FloatStack.instance.removeListener(listener);
  });

  test('indexOf 反映层级，未知 id 返回 -1', () {
    FloatStack.instance.raise(FloatStack.ai);
    expect(
      FloatStack.instance.indexOf(FloatStack.ai),
      greaterThan(FloatStack.instance.indexOf(FloatStack.browser)),
    );
    expect(FloatStack.instance.indexOf('nope'), -1);
  });
}
