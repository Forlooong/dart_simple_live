import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/services/local_storage_service.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/services/db_service.dart';

void main() {
  late Directory directory;
  late DBService database;
  FollowUser user(String id) => FollowUser(
    id: 'douyu_$id',
    roomId: id,
    siteId: 'douyu',
    userName: id,
    face: '',
    addTime: DateTime(2026),
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tv-import-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(FollowUserAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(HistoryAdapter());
    database = DBService();
    await database.init();
  });
  tearDown(() async {
    Get.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'bad later follow does not clear or partially replace local data',
    () async {
      await database.addFollow(user('1'));
      await expectLater(
        database.importFollows([
          user('2').toJson(),
          {'id': 'bad'},
        ], replace: true),
        throwsA(anything),
      );
      expect(database.getFollowList().single.id, 'douyu_1');
    },
  );

  test('replace-empty and merge have distinct behavior', () async {
    await database.addFollow(user('1'));
    await database.importFollows([user('2').toJson()], replace: false);
    expect(database.getFollowList().map((user) => user.id), [
      'douyu_1',
      'douyu_2',
    ]);
    await database.importFollows([], replace: true);
    expect(database.getFollowList(), isEmpty);
  });

  test('pending journal recovers a half-written import on startup', () async {
    await database.addFollow(user('1'));
    final journal = await Hive.openBox<dynamic>('tvfollowuser_restore');
    await journal.put('previous', [user('1').toJson()]);
    await journal.flush();
    await database.followBox.put('douyu_2', user('2'));
    await Hive.close();
    database = DBService();
    await database.init();
    expect(database.getFollowList().single.id, 'douyu_1');
    expect(Hive.box<dynamic>('tvfollowuser_restore').get('previous'), isNull);
  });

  test(
    'history import validates before writes and preserves newer local times',
    () async {
      final history = History(
        id: 'douyu_1',
        roomId: '1',
        siteId: 'douyu',
        userName: 'one',
        face: '',
        updateTime: DateTime(2026),
      );
      await database.addOrUpdateHistory(history);
      await expectLater(
        database.importHistories([
          history.toJson(),
          {'id': 'bad'},
        ], replace: true),
        throwsA(anything),
      );
      expect(database.getHistores().single.updateTime, history.updateTime);
      await database.importHistories([
        {...history.toJson(), 'updateTime': DateTime(2025).toString()},
      ], replace: true);
      expect(database.getHistores().single.updateTime, history.updateTime);
    },
  );
  test(
    'TV shield import validates before mutation and restores interrupted writes',
    () async {
      final storage = LocalStorageService()
        ..settingsBox = await Hive.openBox<dynamic>('settings')
        ..shieldBox = await Hive.openBox<String>('shield');
      Get.put(storage);
      final settings = Get.put(AppSettingsController());
      await settings.importShieldRules(['keep'], replace: true);
      await expectLater(
        settings.importShieldRules(['valid', 42], replace: true),
        throwsFormatException,
      );
      expect(storage.shieldBox.values, ['keep']);
      expect(settings.shieldList, {'keep'});
      await storage.settingsBox.put('_pendingShieldRestore', {'keep': 'keep'});
      await storage.shieldBox.put('partial', 'partial');
      await storage.recoverShieldRules();
      expect(storage.shieldBox.values, ['keep']);
    },
  );
}
