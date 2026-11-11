import 'package:chuk_chat/constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the scale is 4/8/12/16/20/28', () {
    expect(kRadiusScale, <double>[4, 8, 12, 16, 20, 28]);
  });

  test('radiusForHeight picks the step for the height', () {
    expect(radiusForHeight(16), kRadiusXs);
    expect(radiusForHeight(20), kRadiusSm);
    expect(radiusForHeight(28), kRadiusSm);
    expect(radiusForHeight(32), kRadiusMd);
    expect(radiusForHeight(40), kRadiusMd);
    expect(radiusForHeight(48), kRadiusLg);
    expect(radiusForHeight(64), kRadiusXl);
    expect(radiusForHeight(200), kRadiusXxl);
  });

  test('innerRadius is outer minus inset, never below zero', () {
    expect(innerRadius(16, 4), 12);
    expect(innerRadius(8, 1), 7);
    expect(innerRadius(4, 8), 0);
  });
}
