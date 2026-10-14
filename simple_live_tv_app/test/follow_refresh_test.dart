import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';

class _Settings extends AppSettingsController {
  @override
  void onInit() {}
}

class _StatusSite extends LiveSite {
  final requests = <Completer<LiveRoomStatus>>[];

  @override
  Future<LiveRoomStatus> getRoomStatusSnapshot({required String roomId}) {
    final gate = Completer<LiveRoomStatus>();
    requests.add(gate);
    return gate.future;
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) =>
      throw StateError('Follow polling must not prepare playback');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DBService database;
  late FollowUserService service;
  late _StatusSite site;
  late List<FollowUser> rooms;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('simple-live-tv-follow-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(FollowUserAdapter());
    database = DBService()
      ..followBox = await Hive.openBox<FollowUser>('follows');
    Get.put(database);
    Get.put<AppSettingsController>(
        _Settings()..autoUpdateFollowEnable.value = false);
    site = _StatusSite();
    Sites.allSites['test'] =
        Site(id: 'test', name: 'test', logo: '', index: 4, liveSite: site);
    rooms = List.generate(
        12,
        (i) => FollowUser(
            id: 'test_$i',
            roomId: '$i',
            siteId: 'test',
            userName: 'Room $i',
            face: '',
            addTime: DateTime(2026)));
    await database.followBox.putAll({for (final room in rooms) room.id: room});
    service = FollowUserService();
    // Keep startup from beginning a request before the test chooses its watch state.
    service.list.assignAll(rooms);
    service.onInit();
  });

  tearDown(() async {
    service.onClose();
    Sites.allSites.remove('test');
    Get.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> finishRound() async {
    while (service.updating.value) {
      for (final request in site.requests) {
        if (!request.isCompleted)
          request.complete(const LiveRoomStatus(live: true));
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('TV refresh is single flight and playback admits only two requests',
      () async {
    service.beginWatching();
    final round = service.refreshData();
    expect(
        List.generate(20, (_) => service.refreshData())
            .every((other) => identical(round, other)),
        isTrue);
    expect(site.requests, hasLength(2));
    expect(service.list, hasLength(12));
    await finishRound();
    await round;
    expect(site.requests, hasLength(12));
    expect(service.livingList, hasLength(12));
    expect(service.updatedCount, 12);
    service.endWatching();
  });

  test('TV background drains and old account results cannot change the list',
      () async {
    final round = service.refreshData();
    expect(site.requests, hasLength(4));
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    site.invalidateStatusCache();
    await database.followBox.delete(rooms.first.id);
    await finishRound();
    await round;
    expect(site.requests, hasLength(4));
    expect(service.livingList, isEmpty);
    expect(rooms.every((room) => room.liveStatus.value == 0), isTrue);
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    final next = service.refreshData();
    await finishRound();
    await next;
    expect(service.list, hasLength(11));
    expect(service.livingList, hasLength(11));
  });
}
