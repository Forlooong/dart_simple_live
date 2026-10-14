import 'dart:async';

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

class _DelayedFilter extends LiveDanmaku {
  Completer<void>? installing;
  int stops = 0;

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> updateFilterRules(List<DanmakuFilterRule> rules) async {
    filterRules = rules;
    await installing?.future;
  }

  @override
  Future<List<LiveMessage>> refilterMessages(
          List<LiveMessage> messages) async =>
      messages
          .where((message) =>
              !filterRules.any((rule) => message.message.contains(rule.text)))
          .toList();
}

class _FilterSite extends LiveSite {
  _FilterSite(this.danmaku);
  final _DelayedFilter danmaku;

  @override
  LiveDanmaku getDanmaku() => danmaku;
}

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
  testWidgets(
      'super chats publish in batches and their visible list is bounded',
      (tester) async {
    final filter = _DelayedFilter();
    final room = LiveRoomController(
      pSite: Site(
          id: 'test', liveSite: _FilterSite(filter), logo: '', name: 'test'),
      pRoomId: 'room',
    );
    void receiveSuperChat() => room.onWSMessage(LiveMessage(
          type: LiveMessageType.superChat,
          userName: '',
          message: '',
          color: LiveMessageColor.white,
          data: LiveSuperChatMessage(
            userName: 'viewer',
            face: '',
            message: 'x' * 160000,
            price: 1,
            startTime: DateTime.now(),
            endTime: DateTime.now().add(const Duration(hours: 1)),
            backgroundColor: '',
            backgroundBottomColor: '',
          ),
        ));
    await _withRoom(tester, (controller) async {
      _background(tester);
      receiveSuperChat();
      await tester.pump(const Duration(milliseconds: 60));
      expect(controller.superChats, isEmpty);
      _foreground(tester);
      await tester.pump(const Duration(milliseconds: 60));
      expect(controller.superChats, hasLength(1));
      for (var i = 0; i < 4; i++) {
        receiveSuperChat();
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(controller.superChats, hasLength(3));
      expect(filter.stops, 1,
          reason: 'Overflow is reported once and must not grow the UI list.');
    }, room: room);
  });

  testWidgets(
      'rule barrier refilters unpublished messages and preserves history',
      (tester) async {
    final filter = _DelayedFilter();
    final room = LiveRoomController(
      pSite: Site(
          id: 'test', liveSite: _FilterSite(filter), logo: '', name: 'test'),
      pRoomId: 'room',
    );
    await _withRoom(tester, (controller) async {
      _receive(controller, 'blocked but already shown');
      await tester.pump(const Duration(milliseconds: 60));
      controller.freezeChatHistory();
      _receive(controller, 'blocked and unpublished');
      filter.installing = Completer<void>();
      AppSettingsController.instance.shieldList.add('blocked');
      await tester.pump();
      _receive(controller, 'keep this');
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.messages.map((message) => message.message),
          ['blocked but already shown']);
      controller.showLatestMessages();
      expect(controller.messages, hasLength(1),
          reason: 'The latest button also waits for the rule barrier.');
      filter.installing!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(controller.messages.map((message) => message.message),
          ['blocked but already shown', 'keep this']);
    }, room: room);
  });

  testWidgets('history freezes while latest messages stay bounded and batched',
      (tester) async {
    await _withRoom(tester, (controller) async {
      var publications = 0;
      final subscription = controller.messages.listen((_) => publications++);
      for (var i = 0; i < 200; i++) {
        _receive(controller, 'message $i');
      }
      expect(controller.messages, isEmpty);
      await tester.pump(const Duration(milliseconds: 60));
      expect(publications, 1);
      expect(controller.messages.length, 200);
      controller.freezeChatHistory();
      final history = controller.messages.toList();
      for (var i = 200; i < 10000; i++) {
        _receive(controller, 'message $i');
      }
      await tester.pump(const Duration(milliseconds: 60));
      expect(controller.messages, history);
      expect(publications, 1);
      controller.showLatestMessages();
      await tester.pump();
      expect(controller.messages.length, 200);
      expect(controller.messages.first.message, 'message 9800');
      expect(controller.messages.last.message, 'message 9999');
      expect(publications, 2);
      await subscription.cancel();
    });
  });

  testWidgets('hidden overlay discards pending batch and stays idle',
      (tester) async {
    await _withRoom(tester, (controller) async {
      _receive(controller, 'queued before hiding');
      controller.showDanmakuState.value = false;
      await tester.pump();
      controller.showDanmakuState.value = true;
      await tester.pump(const Duration(milliseconds: 60));
      expect(controller.messages.single.message, 'queued before hiding');
      expect(_scrollPainter(tester).scrollDanmakuItems, isEmpty);
      controller.showDanmakuState.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  testWidgets('new chat is painted after returning from the background',
      (tester) async {
    await _withRoom(tester, (controller) async {
      _receive(controller, 'before background');
      await tester.pump(const Duration(milliseconds: 60));

      final initial = _scrollPainter(tester).scrollDanmakuItems.single;
      expect(initial.content.text, 'before background');
      expect(initial.lastDrawTick, isNotNull,
          reason: 'The baseline message must reach the real canvas painter.');

      for (var cycle = 0; cycle < 3; cycle++) {
        _background(tester);
        await tester.pump(const Duration(milliseconds: 110));
        _receive(controller, 'background $cycle');
        expect(controller.messages.last.message,
            cycle == 0 ? 'before background' : 'returned ${cycle - 1}',
            reason: 'Background messages are buffered without publishing UI.');
        expect(_scrollPainter(tester).scrollDanmakuItems, isEmpty,
            reason: 'Chat stays connected while the overlay is cleared.');

        _foreground(tester);
        _receive(controller, 'returned $cycle');
        await tester.pump(const Duration(milliseconds: 60));

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
      await tester.pump(const Duration(milliseconds: 60));

      expect(controller.showDanmakuState.value, isFalse,
          reason: 'Returning must preserve the user\'s overlay preference.');
      expect(controller.messages.last.message, 'still hidden');
      expect(_scrollPainter(tester).scrollDanmakuItems, isEmpty);

      controller.showDanmakuState.value = true;
      await tester.pump();
      _receive(controller, 'manually enabled');
      await tester.pump(const Duration(milliseconds: 60));

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
      await tester.pump(const Duration(milliseconds: 60));
      expect(_scrollPainter(tester).scrollDanmakuItems, hasLength(1));

      _background(tester);
      await tester.pump(const Duration(milliseconds: 110));
      controller.closing = true;
      _foreground(tester);
      _receive(controller, 'after close');
      await tester.pump(const Duration(milliseconds: 60));

      expect(controller.messages.map((message) => message.message),
          ['before close']);
      expect(_scrollPainter(tester).running, isFalse,
          reason: 'A late lifecycle callback must not restart a closing room.');
      expect(_scrollPainter(tester).scrollDanmakuItems, isEmpty);
      expect(tester.takeException(), isNull);
    }, room: controller);
  });
}
