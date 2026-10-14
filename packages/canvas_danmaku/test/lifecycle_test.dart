import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('empty, hidden and disposed overlays schedule no work',
      (tester) async {
    late DanmakuController controller;
    final key = GlobalKey();
    Widget view(bool enabled) => MaterialApp(
          home: SizedBox(
            width: 640,
            height: 360,
            child: DanmakuScreen(
              key: key,
              enabled: enabled,
              option: DanmakuOption(),
              createdController: (value) => controller = value,
            ),
          ),
        );
    await tester.pumpWidget(view(true));
    expect(tester.binding.transientCallbackCount, 0);
    controller.addDanmaku(DanmakuContentItem('visible'));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    for (var i = 0; i < 20; i++) {
      await tester.pumpWidget(view(false));
      controller.resume(); // A manual resume must not override disabled state.
      controller.addDanmaku(DanmakuContentItem('hidden'));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .whereType<ScrollDanmakuPainter>()
          .single;
      expect(painter.scrollDanmakuItems, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(
          tester
              .widgetList<CustomPaint>(find.byType(CustomPaint))
              .map((widget) => widget.painter)
              .whereType<ScrollDanmakuPainter>()
              .single,
          same(painter),
          reason: 'A hidden overlay must not rebuild on a cleanup timer.');
      await tester.pumpWidget(view(true));
      expect(tester.binding.transientCallbackCount, 0);
      controller.addDanmaku(DanmakuContentItem('new $i'));
      await tester.pump();
    }
    controller.clear();
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('createdController can safely pause immediately', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DanmakuScreen(
        option: DanmakuOption(),
        createdController: (controller) => controller.pause(),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
