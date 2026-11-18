import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/widgets/highlight_widget.dart';

void main() {
  testWidgets('directional focus and select activate only the focused action', (
    tester,
  ) async {
    final first = AppFocusNode();
    final second = AppFocusNode();
    var count = 0;
    await tester.pumpWidget(
      ScreenUtilInit(
        builder: (_, _) => MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                HighlightWidget(
                  focusNode: first,
                  autofocus: true,
                  onTap: () => count += 10,
                  child: const SizedBox(
                    width: 100,
                    height: 50,
                    child: Text('返回'),
                  ),
                ),
                HighlightWidget(
                  focusNode: second,
                  onTap: () => count++,
                  child: const SizedBox(
                    width: 100,
                    height: 50,
                    child: Text('刷新'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(first.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(second.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(count, 1);
    await tester.pumpWidget(const SizedBox());
    first.dispose();
    second.dispose();
  });
}
