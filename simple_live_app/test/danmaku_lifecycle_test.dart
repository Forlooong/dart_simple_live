import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/player/player_controls.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _Settings extends AppSettingsController {
  // Defaults suffice for this renderer test; do not initialize device storage.
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _VideoContext extends VideoState {
  _VideoContext(this._context);

  final BuildContext _context;

  // buildDanmuView only needs the layout context, not a native video player.
  @override
  BuildContext get context => _context;
}

Site _site() => Site(id: 'test', liveSite: LiveSite(), logo: '', name: 'test');

class _ClosingRoom extends LiveRoomController {
  _ClosingRoom() : super(pSite: _site(), pRoomId: 'room');

  bool closing = false;

  // Exercise the real lifecycle handler's guard without native media disposal.
  @override
  bool get playerClosing => closing || super.playerClosing;
}

ScrollDanmakuPainter _scrollPainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint, skipOffstage: false))
    .map((widget) => widget.painter)
    .whereType<ScrollDanmakuPainter>()
    .single;

void _receive(LiveRoomController controller, String text) {
  controller.liveDanmaku.onMessage!(LiveMessage(
    type: LiveMessageType.chat,
    userName: 'viewer',
    message: text,
    color: LiveMessageColor.white,
  ));
}

Future<LiveRoomController> _mountRoom(
  WidgetTester tester, {
  LiveRoomController? room,
}) async {
  Get.put<AppSettingsController>(_Settings());
  final controller =
      room ?? LiveRoomController(pSite: _site(), pRoomId: 'room');
  controller.liveStatus.value = true;
  controller.showDanmakuState.value = true;
  controller.initDanmau();
  // Register in the same order as a room: controller first, renderer second.
  tester.binding.addObserver(controller);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

  await tester.pumpWidget(MaterialApp(
    home: Center(
      child: SizedBox(
        width: 640,
        height: 360,
        child: Builder(builder: (context) {
          return Stack(children: [
            buildDanmuView(_VideoContext(context), controller),
          ]);
        }),
      ),
    ),
  ));

  return controller;
}

Future<void> _withRoom(
  WidgetTester tester,
  Future<void> Function(LiveRoomController) body, {
  LiveRoomController? room,
}) async {
  final controller = await _mountRoom(tester, room: room);
  try {
    await body(controller);
  } finally {
    tester.binding.removeObserver(controller);
    await tester.pumpWidget(const SizedBox.shrink());
    // The dependency has one delayed cleanup tick after widget disposal.
    await tester.pump(const Duration(milliseconds: 110));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    controller.scrollController.dispose();
    Get.reset();
  }
}

void _background(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _foreground(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  testWidgets('new chat is painted after returning from the background',
      (tester) async {
    await _withRoom(tester, (controller) async {
      _receive(controller, 'before background');
      await tester.pump(const Duration(milliseconds: 16));

      final initial = _scrollPainter(tester).scrollDanmakuItems.single;
      expect(initial.content.text, 'before background');
      expect(initial.lastDrawTick, isNotNull,
          reason: 'The baseline message must reach the real canvas painter.');

      for (var cycle = 0; cycle < 3; cycle++) {
        _background(tester);
        await tester.pump(const Duration(milliseconds: 110));
        _receive(controller, 'background $cycle');
        expect(controller.messages.last.message, 'background $cycle');
        expect(_scrollPainter(tester).scrollDanmakuItems, isEmpty,
            reason: 'Chat stays connected while the overlay is cleared.');

        _foreground(tester);
        _receive(controller, 'returned $cycle');
        await tester.pump(const Duration(milliseconds: 16));

        expect(controller.messages.last.message, 'returned $cycle');
        final painter = _scrollPainter(tester);
        expect(painter.running, isTrue);
        expect(painter.scrollDanmakuItems.map((item) => item.content.text),
            ['returned $cycle'],
            reason: 'New messages must reach the overlay as well as chat.');
        expect(painter.scrollDanmakuItems.single.lastDrawTick, isNotNull,
            reason:
                'The restored message must be painted by the real renderer.');
      }
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('resume preserves hidden overlay and manual enabling still works',
      (tester) async {
    await _withRoom(tester, (controller) async {
      controller.showDanmakuState.value = false;
      await tester.pump();

      _background(tester);
      await tester.pump(const Duration(milliseconds: 110));
      _foreground(tester);
      _receive(controller, 'still hidden');
      await tester.pump(const Duration(milliseconds: 16));

      expect(controller.showDanmakuState.value, isFalse,
          reason: 'Returning must preserve the user\'s overlay preference.');
      expect(controller.messages.last.message, 'still hidden');
      expect(_scrollPainter(tester).scrollDanmakuItems, isEmpty);

      controller.showDanmakuState.value = true;
      await tester.pump();
      _receive(controller, 'manually enabled');
      await tester.pump(const Duration(milliseconds: 16));

      final painter = _scrollPainter(tester);
      expect(painter.running, isTrue);
      expect(painter.scrollDanmakuItems.map((item) => item.content.text),
          ['manually enabled']);
      expect(painter.scrollDanmakuItems.single.lastDrawTick, isNotNull);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a closing room cannot resume its paused renderer',
      (tester) async {
    final controller = _ClosingRoom();
    await _withRoom(tester, (_) async {
      _receive(controller, 'before close');
      await tester.pump(const Duration(milliseconds: 16));
      expect(_scrollPainter(tester).scrollDanmakuItems, hasLength(1));

      _background(tester);
      await tester.pump(const Duration(milliseconds: 110));
      controller.closing = true;
      _foreground(tester);
      _receive(controller, 'after close');
      await tester.pump(const Duration(milliseconds: 16));

      expect(controller.messages.map((message) => message.message),
          ['before close']);
      expect(_scrollPainter(tester).running, isFalse,
          reason: 'A late lifecycle callback must not restart a closing room.');
      expect(_scrollPainter(tester).scrollDanmakuItems, isEmpty);
      expect(tester.takeException(), isNull);
    }, room: controller);
  });
}
