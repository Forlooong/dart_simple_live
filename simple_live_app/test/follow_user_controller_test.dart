import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FollowStatusSite extends LiveSite {
  @override
  Future<LiveRoomStatus> getRoomStatusSnapshot({
    required String roomId,
  }) async => const LiveRoomStatus(live: true);

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) =>
      throw StateError('Follow refresh must not prepare playback');
}

class _DeferredFollowStatusSite extends _FollowStatusSite {
  final started = Completer<void>();
  final result = Completer<LiveRoomStatus>();

  @override
  Future<LiveRoomStatus> getRoomStatusSnapshot({required String roomId}) {
    started.complete();
    return result.future;
  }
}

class _DelayedOrderDB extends DBService {
  Completer<void>? orderGate;
  Completer<void>? updateGate;

  @override
  Future<void> updateFollowTag(FollowUserTag tag) async {
    await updateGate?.future;
    await super.updateFollowTag(tag);
  }

  @override
  Future<void> updateFollowTagOrder(List<FollowUserTag> tags) async {
    await orderGate?.future;
    await super.updateFollowTagOrder(tags);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _DelayedOrderDB database;
  late FollowService service;
  late FollowUserController controller;
  var controllerClosed = false;

  FollowUser room({String siteId = 'follow_test', String roomId = '42'}) =>
      FollowUser(
        id: '${siteId}_$roomId',
        roomId: roomId,
        siteId: siteId,
        userName: 'Room $roomId',
        face: '',
        addTime: DateTime(2026),
      );

  Future<void> drainEvents() => Future<void>.delayed(Duration.zero);

  Future<void> followAndNotify(FollowUser item) async {
    await service.addFollow(item);
    EventBus.instance.emit(Constant.kUpdateFollow, item.id);
    await drainEvents();
  }

  void expectVisibleIds(Iterable<String> ids) {
    expect(controller.list.map((item) => item.id), unorderedEquals(ids));
    expect(controller.pageEmpty.value, ids.isEmpty);
    expect(controller.pageError.value, isFalse);
    expect(controller.pageLoadding.value, isFalse);
    expect(controller.canLoadMore.value, isFalse);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('follow-controller-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(FollowUserAdapter());
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(FollowUserTagAdapter());
    }
    database = _DelayedOrderDB()
      ..followBox = await Hive.openBox<FollowUser>('follows')
      ..tagBox = await Hive.openBox<FollowUserTag>('tags');
    final storage = LocalStorageService()
      ..settingsBox = await Hive.openBox<dynamic>('settings')
      ..shieldBox = await Hive.openBox<String>('shield');
    Get.put<DBService>(database);
    Get.put(storage);
    final settings = Get.put(AppSettingsController());
    settings.autoUpdateFollowEnable.value = false;
    for (final siteId in ['follow_test', 'follow_other']) {
      Sites.allSites[siteId] = Site(
        id: siteId,
        name: siteId,
        logo: '',
        liveSite: _FollowStatusSite(),
      );
    }
    service = Get.put(FollowService());
    controller = FollowUserController();
    controllerClosed = false;
    controller.onInit();
  });

  tearDown(() async {
    if (!controllerClosed) controller.onClose();
    await Get.delete<FollowService>(force: true);
    Get.reset();
    Sites.allSites.remove('follow_test');
    Sites.allSites.remove('follow_other');
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'following from an empty page immediately clears the empty state',
    () async {
      await controller.loadData();
      expectVisibleIds([]);

      final item = room();
      await followAndNotify(item);

      expectVisibleIds([item.id]);
      expect(database.followBox.length, 1);
    },
  );

  test(
    'a service event queued before initial load cannot append a duplicate',
    () async {
      final item = room();
      await database.addFollow(item);
      // loadData publishes its snapshot synchronously and queues a stream event.
      // The old controller then awaited getData while this event assigned the
      // same room, and appended that snapshot when its continuation resumed.
      final serviceLoad = service.loadData(updateStatus: false);
      final pageLoad = controller.loadData();
      await Future.wait([serviceLoad, pageLoad]);
      await drainEvents();

      expectVisibleIds([item.id]);
      expect(database.followBox.length, 1);
    },
  );

  test('repeated refresh and load calls keep one complete snapshot', () async {
    final items = List.generate(30, (index) => room(roomId: '$index'));
    await database.followBox.putAll({for (final item in items) item.id: item});
    for (var round = 0; round < 3; round++) {
      await controller.refreshData();
      await drainEvents();
      expectVisibleIds(items.map((item) => item.id));
      await controller.loadData();
      expectVisibleIds(items.map((item) => item.id));
    }
  });

  test(
    'adding to a populated list during overlapping refreshes stays unique',
    () async {
      final original = room();
      await followAndNotify(original);
      await controller.refreshData();
      await drainEvents();

      final added = room(roomId: '43');
      await database.addFollow(added);
      final reconcile = service.loadData(updateStatus: false);
      service.filterData();
      final refresh = controller.refreshData();
      final load = controller.loadData();
      final secondRefresh = controller.refreshData();
      await Future.wait([reconcile, refresh, load, secondRefresh]);
      await drainEvents();

      expectVisibleIds([original.id, added.id]);
      expect(database.followBox.length, 2);
    },
  );

  test(
    'live and offline filters update empty state on changes and events',
    () async {
      final item = room();
      await followAndNotify(item);
      controller.setFilterMode(controller.tagList[1]);
      expectVisibleIds([]);

      item.liveStatus.value = 2;
      service.filterData();
      await drainEvents();
      expectVisibleIds([item.id]);

      controller.setFilterMode(controller.tagList[2]);
      expectVisibleIds([]);
      item.liveStatus.value = 1;
      service.filterData();
      await drainEvents();
      expectVisibleIds([item.id]);

      controller.setFilterMode(controller.tagList[1]);
      expectVisibleIds([]);
      controller.setFilterMode(controller.tagList[0]);
      expectVisibleIds([item.id]);
    },
  );

  test('custom tag empty state follows tag membership updates', () async {
    final item = room();
    await followAndNotify(item);
    final tag = FollowUserTag(id: 'favorites', tag: 'Favorites', userId: []);
    await database.tagBox.put(tag.id, tag);
    controller.setFilterMode(tag);
    expectVisibleIds([]);

    tag.userId.add(item.id);
    service.filterData();
    await drainEvents();
    expectVisibleIds([item.id]);

    tag.userId.clear();
    service.filterData();
    await drainEvents();
    expectVisibleIds([]);
  });

  test(
    'remove then follow again replaces the room without stale duplicates',
    () async {
      final original = room();
      await followAndNotify(original);
      await database.deleteFollow(original.id);
      EventBus.instance.emit(Constant.kUpdateFollow, original.id);
      await drainEvents();
      expectVisibleIds([]);

      final replacement = room()..userName = 'Updated name';
      await followAndNotify(replacement);
      expectVisibleIds([replacement.id]);
      expect(controller.list.single, same(replacement));
      expect(database.followBox.length, 1);
    },
  );

  test('equal numeric room IDs on different sites remain distinct', () async {
    final first = room();
    final second = room(siteId: 'follow_other');
    await followAndNotify(first);
    await followAndNotify(second);
    await controller.refreshData();
    await drainEvents();

    expectVisibleIds([first.id, second.id]);
    expect(database.followBox.length, 2);
  });

  test(
    'reopening persisted follows preserves identity and preferences',
    () async {
      final first = room()
        ..tag = 'Favorites'
        ..notifyLive = true;
      final otherSite = room(siteId: 'follow_other');
      await service.addFollow(first);
      await service.addFollow(first);
      await service.addFollow(otherSite);
      expect(database.followBox.length, 2);

      await database.followBox.close();
      database.followBox = await Hive.openBox<FollowUser>('follows');
      await service.loadData(updateStatus: false);
      await controller.loadData();
      await drainEvents();

      expectVisibleIds([first.id, otherSite.id]);
      expect(database.followBox.length, 2);
      final restored = database.followBox.get(first.id)!;
      expect(restored.tag, 'Favorites');
      expect(restored.notifyLive, isTrue);
      expect(restored.siteId, first.siteId);
      expect(restored.roomId, first.roomId);
      expect(database.followBox.get(otherSite.id)!.notifyLive, isFalse);
    },
  );

  test(
    'refresh finishing after close does not repopulate the controller',
    () async {
      final deferredSite = _DeferredFollowStatusSite();
      Sites.allSites['follow_test'] = Site(
        id: 'follow_test',
        name: 'follow_test',
        logo: '',
        liveSite: deferredSite,
      );
      final item = room();
      await database.addFollow(item);
      controller.setFilterMode(controller.tagList[1]);
      final refresh = controller.refreshData();
      await deferredSite.started.future;
      await drainEvents();
      expectVisibleIds([]);

      controller.onClose();
      controllerClosed = true;
      deferredSite.result.complete(const LiveRoomStatus(live: true));
      await refresh;
      await drainEvents();

      expect(service.liveList.map((item) => item.id), [item.id]);
      expectVisibleIds([]);
    },
  );

  test(
    'status completion preserves reordered tags in service and controller',
    () async {
      final deferredSite = _DeferredFollowStatusSite();
      Sites.allSites['follow_test'] = Site(
        id: 'follow_test',
        name: 'test',
        logo: '',
        liveSite: deferredSite,
      );
      await database.addFollow(room());
      await database.addFollowTag('A');
      await database.addFollowTag('B');
      await service.loadData(updateStatus: false);
      controller.updateTagList();
      final refresh = service.loadData(automatic: true);
      await deferredSite.started.future;
      database.orderGate = Completer<void>();
      final reorder = controller.updateTagOrder(0, 2);
      await service.loadData(updateStatus: false);
      await drainEvents();
      expect(service.followTagList.map((tag) => tag.tag), ['B', 'A']);
      deferredSite.result.complete(const LiveRoomStatus(live: true));
      await refresh;
      await drainEvents();
      expect(controller.userTagList.map((tag) => tag.tag), ['B', 'A']);
      database.orderGate!.complete();
      await reorder;
      expect(database.getFollowTagList().map((tag) => tag.tag), ['B', 'A']);
    },
  );

  test('delayed tag rename reconciles an intervening storage reload', () async {
    final tag = await database.addFollowTag('Before');
    await service.loadData(updateStatus: false);
    database.updateGate = Completer<void>();
    final rename = service.updateFollowUserTag(tag.copyWith(tag: 'After'));
    await service.loadData(updateStatus: false);
    expect(service.followTagList.single.tag, 'Before');
    database.updateGate!.complete();
    await rename;
    await drainEvents();
    expect(service.followTagList.single.tag, 'After');
    expect(controller.userTagList.single.tag, 'After');
  });

  test(
    'delayed rename never recreates a tag deleted before its write',
    () async {
      final tag = await database.addFollowTag('Before');
      await service.loadData(updateStatus: false);
      database.updateGate = Completer<void>();
      final rename = service.updateFollowUserTag(tag.copyWith(tag: 'After'));
      await database.deleteFollowTag(tag.id);
      database.updateGate!.complete();
      await rename;
      await drainEvents();
      expect(service.followTagList, isEmpty);
      expect(controller.userTagList, isEmpty);
    },
  );

  test(
    'controller rename stops if tag is deleted while its write waits',
    () async {
      final item = room();
      await database.addFollow(item);
      final tag = await database.addFollowTag('Before');
      tag.userId.add(item.id);
      await database.updateFollowTag(tag);
      await service.loadData(updateStatus: false);
      controller.updateTagList();
      database.updateGate = Completer<void>();
      final rename = controller.updateTagName(tag, 'After');
      await database.deleteFollowTag(tag.id);
      database.updateGate!.complete();
      await rename;
      expect(database.followBox.get(item.id)!.tag, '全部');
      expect(database.getFollowTagList(), isEmpty);
    },
  );

  test('closed controller stops receiving service snapshots', () async {
    await controller.loadData();
    service.followList.add(room());
    service.filterData();
    controller.onClose();
    controllerClosed = true;
    await drainEvents();
    await followAndNotify(room());

    expect(controller.list, isEmpty);
    expect(controller.pageEmpty.value, isTrue);
  });
}
