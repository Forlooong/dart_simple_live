import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';

void main() {
  testWidgets('TV remote button expands for system large text', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final focus = AppFocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1920, 1080),
        builder: (_, __) => MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(1920, 1080),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: Center(
                child: HighlightButton(text: '返回', focusNode: focus),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      MediaQuery.textScalerOf(tester.element(find.text('返回'))).scale(28),
      56,
    );
    expect(tester.takeException(), isNull);
  });
}
