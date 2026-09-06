import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/core/theme/app_theme.dart';

void main() {
  test('app theme has light and dark variants', () {
    expect(AppTheme.light().brightness, isNotNull);
    expect(AppTheme.dark().brightness, isNotNull);
  });
}