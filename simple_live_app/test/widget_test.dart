import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/app_style.dart';

void main() {
  const data = MediaQueryData(
    size: Size(400, 600),
    viewPadding: EdgeInsets.fromLTRB(12, 60, 14, 40),
    padding: EdgeInsets.fromLTRB(12, 60, 14, 40),
    textScaler: TextScaler.linear(2),
  );
  test('valid safe areas and system font scale survive by default', () {
    for (final flags in [
      (false, true, true),
      (true, false, true),
      (true, true, false),
    ]) {
      expect(
        AppStyle.windowMediaQuery(
          data,
          android: flags.$1,
          windowed: flags.$2,
          workaround: flags.$3,
        ),
        same(data),
      );
    }
  });
  test('opt-in Android window correction retains sides and accessibility', () {
    final result = AppStyle.windowMediaQuery(
      data,
      android: true,
      windowed: true,
      workaround: true,
    );
    expect(result.viewPadding, const EdgeInsets.fromLTRB(12, 25, 14, 35));
    expect(result.textScaler.scale(20), 40);
    final keyboard = data.copyWith(
      viewInsets: const EdgeInsets.only(bottom: 300),
    );
    expect(
      AppStyle.windowMediaQuery(
        keyboard,
        android: true,
        windowed: true,
        workaround: true,
      ),
      same(keyboard),
    );
    final fullscreen = data.copyWith(viewPadding: EdgeInsets.zero);
    expect(
      AppStyle.windowMediaQuery(
        fullscreen,
        android: true,
        windowed: true,
        workaround: true,
      ),
      same(fullscreen),
    );
  });
}
