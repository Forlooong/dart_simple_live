import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

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
  late FollowService service;
  late _StatusSite site;
  late AppSettingsController settings;
  late List<FollowUser> rooms;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('simple-live-follow-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(FollowUserAdapter());
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(FollowUserTagAdapter());
    }
    database = DBService()
      ..followBox = await Hive.openBox<FollowUser>('follows')
      ..tagBox = await Hive.openBox<FollowUserTag>('tags');
    final storage = LocalStorageService()
      ..settingsBox = await Hive.openBox<dynamic>('settings')
      ..shieldBox = await Hive.openBox<String>('shield');
    Get.put(database);
    Get.put(storage);
    settings = Get.put(AppSettingsController());
    settings.autoUpdateFollowEnable.value = false;
    site = _StatusSite();
    Sites.allSites['test'] =
        Site(id: 'test', name: 'test', logo: '', liveSite: site);
    rooms = List.generate(
        12,
        (i) => FollowUser(
              id: 'test_$i',
              roomId: '$i',
              siteId: 'test',
              userName: 'Room $i',
              face: '',
              addTime: DateTime(2026),
            ));
    await database.followBox.putAll({for (final room in rooms) room.id: room});
    service = FollowService();
    service.onInit();
  });

  tearDown(() async {
    service.onClose();
    Sites.allSites.remove('test');
    Get.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> finishRequests() async {
    var completed = 0;
    while (service.updating.value) {
      while (completed < site.requests.length) {
        site.requests[completed++]
            .complete(const LiveRoomStatus(live: true, showTime: '100'));
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('20 refresh calls share one round; watch cap drains existing work',
      () async {
    final round = service.loadData();
    final duplicates = List.generate(20, (_) => service.loadData());
    expect(duplicates.every((future) => identical(future, round)), isTrue);
    expect(site.requests, hasLength(4));
    service.beginWatching();
    site.requests[0].complete(const LiveRoomStatus(live: false));
    site.requests[1].complete(const LiveRoomStatus(live: false));
    await Future<void>.delayed(Duration.zero);
    expect(site.requests, hasLength(4));
    service.endWatching();
    for (final request in site.requests.skip(2)) {
      if (!request.isCompleted) {
        request.complete(const LiveRoomStatus(live: true));
      }
    }
    while (service.updating.value) {
      await Future<void>.delayed(Duration.zero);
      for (final request in site.requests) {
        if (!request.isCompleted) {
          request.complete(const LiveRoomStatus(live: true));
        }
      }
    }
    await round;
    expect(site.requests, hasLength(12));
    expect(service.updatedCount, 12);
    expect(service.updating.value, isFalse);
  });

  test('removed room and old account results cannot update current list',
      () async {
    final round = service.loadData();
    await database.followBox.delete(rooms.first.id);
    await service.loadData(updateStatus: false);
    site.invalidateStatusCache();
    await finishRequests();
    await round;
    expect(rooms.every((room) => room.liveStatus.value == 0), isTrue);
    expect(service.followList, hasLength(11));
    expect(service.liveList, isEmpty);
    expect(service.updating.value, isFalse);
  });

  test(
    'a refresh during polling reconciles persisted membership immediately',
    () async {
      final round = service.loadData();
      await database.deleteFollow(rooms.first.id);
      final added = FollowUser(
        id: 'test_new',
        roomId: 'new',
        siteId: 'test',
        userName: 'New room',
        face: '',
        addTime: DateTime(2026),
      );
      await database.addFollow(added);
      final joined = service.loadData();
      expect(identical(joined, round), isTrue);
      expect(
        service.followList.any((room) => room.id == rooms.first.id),
        isFalse,
      );
      expect(
        service.followList.where((room) => room.id == added.id),
        hasLength(1),
      );
      await finishRequests();
      await round;
      expect(
        service.followList.where((room) => room.id == added.id),
        hasLength(1),
      );
      expect(rooms.first.liveStatus.value, 0);
    },
  );

  test('background stops admission; failures clear refreshing state', () async {
    final round = service.loadData();
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    for (final request in site.requests) {
      request.completeError(StateError('offline'));
    }
    await round;
    expect(site.requests, hasLength(4));
    expect(service.updating.value, isFalse);
    expect(service.updatedCount, 4);
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    final next = service.loadData();
    var completed = 4;
    while (service.updating.value) {
      while (completed < site.requests.length) {
        site.requests[completed++].complete(const LiveRoomStatus(live: false));
      }
      await Future<void>.delayed(Duration.zero);
    }
    await next;
    expect(service.notLiveList, hasLength(12));
  });

  test('legacy CPU-based concurrency migrates to bounded defaults', () {
    settings.updateFollowThreadCount.value = 0;
    expect(service.getOptimalConcurrency(), 4);
    settings.updateFollowThreadCount.value = 20;
    expect(service.getOptimalConcurrency(), 8);
    service.beginWatching();
    expect(service.getOptimalConcurrency(), 2);
    settings.updateFollowThreadCount.value = 1;
    expect(service.getOptimalConcurrency(), 1);
    service.endWatching();
  });

  testWidgets('several overdue background intervals coalesce into one refresh',
      (tester) async {
    service.onClose();
    service = FollowService(now: tester.binding.clock.now);
    settings.autoUpdateFollowEnable.value = true;
    settings.autoUpdateFollowDuration.value = 1;
    service.onInit();
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 3));
    expect(site.requests, isEmpty);
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(Duration.zero);
    expect(site.requests, hasLength(4));
    while (service.updating.value) {
      for (final request in site.requests) {
        if (!request.isCompleted) {
          request.complete(const LiveRoomStatus(live: false));
        }
      }
      await tester.pump();
    }
    expect(site.requests, hasLength(12));
    await tester.pump(const Duration(seconds: 59));
    expect(site.requests, hasLength(12));
    settings.autoUpdateFollowEnable.value = false;
    service.initTimer();
  });
}
