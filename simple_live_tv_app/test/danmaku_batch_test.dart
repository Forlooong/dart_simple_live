import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/live_room/live_room_controller.dart';

class _Settings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _Room extends LiveRoomController {
  _Room()
      : super(
          pSite: Site(
              id: 'test',
              liveSite: LiveSite(),
              logo: '',
              name: 'test',
              index: 0),
          pRoomId: 'room',
        );

  final batches = <List<DanmakuContentItem>>[];

  @override
  void addDanmaku(List<DanmakuContentItem> items) {
    if (items.isNotEmpty) batches.add(items);
  }
}

void _receive(_Room room, String text) => room.onWSMessage(LiveMessage(
      type: LiveMessageType.chat,
      userName: 'viewer',
      message: text,
      color: LiveMessageColor.white,
    ));

void main() {
  testWidgets('TV publishes one bounded batch and discards background overlay',
      (tester) async {
    Get.put<AppSettingsController>(_Settings());
    final room = _Room();
    room.liveStatus.value = true;
    room.showDanmakuState.value = true;
    room.initDanmau();
    await tester.pump();
    for (var i = 0; i < 1000; i++) {
      _receive(room, '$i');
    }
    await tester.pump(const Duration(milliseconds: 49));
    expect(room.batches, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(room.batches, hasLength(1));
    expect(room.batches.single, hasLength(200));
    expect(room.batches.single.first.text, '800');
    expect(room.droppedDanmakuMessages, 800);

    _receive(room, 'pending before background');
    room.didChangeAppLifecycleState(AppLifecycleState.paused);
    _receive(room, 'during background');
    await tester.pump(const Duration(seconds: 1));
    expect(room.batches, hasLength(1));
    room.didChangeAppLifecycleState(AppLifecycleState.resumed);
    _receive(room, 'returned');
    await tester.pump(const Duration(milliseconds: 50));
    expect(room.batches.last.map((item) => item.text), ['returned']);
    room.didChangeAppLifecycleState(AppLifecycleState.paused);
    room.focusNode.dispose();
    Get.reset();
  });
}
