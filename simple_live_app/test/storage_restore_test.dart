import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/main.dart' show migrateData;
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/remote_sync_webdav_controller.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class _Settings extends AppSettingsController {
  @override
  void reloadSettings({bool initializeLog = false}) {}
}

class _FailingHistoryDB extends DBService {
  @override
  Future<bool> replaceHistoriesIfCurrent(
    List expected,
    List replacement,
  ) async {
    throw StateError('injected history failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalStorageService storage;
  late DBService database;
  late RemoteSyncWebDAVController controller;
  ArchiveFile document(String name, Object data) {
    final bytes = utf8.encode(jsonEncode({'data': data}));
    return ArchiveFile(name, bytes.length, bytes);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('storage-restore-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(FollowUserAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(HistoryAdapter());
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(FollowUserTagAdapter());
    }
    storage = LocalStorageService()
      ..settingsBox = await Hive.openBox<dynamic>('settings')
      ..shieldBox = await Hive.openBox<String>('shield');
    Get.put(storage);
    Get.put<AppSettingsController>(_Settings());
    database = DBService();
    await database.init();
    Get.put(database);
    controller = RemoteSyncWebDAVController();
  });
  tearDown(() async {
    Get.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'ordinary ZIP excludes credentials and legacy settings cannot restore them',
    () async {
      const canary = 'synthetic-cookie-password-canary';
      await storage.settingsBox.putAll({
        LocalStorageService.kBilibiliCookie: canary,
        LocalStorageService.kDouyinCookie: canary,
        LocalStorageService.kWebDAVPassword: canary,
        LocalStorageService.kWebDAVUri: 'https://current.invalid',
        LocalStorageService.kWebDAVUser: 'current-user',
        LocalStorageService.kThemeMode: 1,
      });
      final backupBytes = await controller.createBackup();
      expect(
        WebDavBackup.decode(backupBytes).has(RestoreGroup.settings),
        isTrue,
      );
      final backup = ZipDecoder().decodeBytes(backupBytes);
      expect(
        backup.files.any((file) => file.name.contains('account')),
        isFalse,
      );
      for (final file in backup) {
        expect(utf8.decode(file.content as List<int>), isNot(contains(canary)));
      }
      final legacy = Archive()
        ..addFile(
          document('SimpleLive_Settings.json', {
            LocalStorageService.kBilibiliCookie: 'other-account',
            LocalStorageService.kWebDAVUri: 'https://other.invalid',
            LocalStorageService.kWebDAVPassword: 'other-password',
            LocalStorageService.kThemeMode: 2,
          }),
        )
        ..addFile(
          document('SimpleLive_bilibili_account.json', {
            'cookie': 'other-account',
          }),
        );
      final result = await controller.restoreArchive(legacy);
      expect(result.failed, isEmpty);
      expect(
        storage.settingsBox.get(LocalStorageService.kBilibiliCookie),
        canary,
      );
      expect(
        storage.settingsBox.get(LocalStorageService.kWebDAVUri),
        'https://current.invalid',
      );
      expect(storage.settingsBox.get(LocalStorageService.kThemeMode), 2);
      await storage.settingsBox.close();
      storage.settingsBox = await Hive.openBox<dynamic>('settings');
      expect(
        storage.settingsBox.get(LocalStorageService.kBilibiliCookie),
        canary,
      );
    },
  );

  test('rejects a corrupted WebDAV document before exposing a preview', () {
    final file = document(WebDavBackup.settingsFile, {'ThemeMode': 1})
      ..crc32 = 0;
    expect(
      () => WebDavBackup.read(Archive()..addFile(file)),
      throwsFormatException,
    );
  });

  test(
    'recovers a persisted checkpoint after an interrupted restore',
    () async {
      const key = LocalStorageService.kThemeMode;
      await storage.setValue(key, 2);
      final journal = await Hive.openBox<dynamic>('WebDavRestore');
      final after = sha256
          .convert(utf8.encode(jsonEncode({key: 2})))
          .toString();
      await journal.put('rollback', {
        'current': <String, Object>{},
        'pending': {
          'settings': {
            'before': {key: 1},
            'after': after,
          },
        },
      });
      await journal.flush();
      await journal.close();
      final restore = WebDavRestore();
      expect(await restore.hasRollback(), isTrue);
      expect((await restore.rollback()).succeeded, ['设置']);
      expect(storage.getValue(key, 0), 1);
    },
  );

  test('a stale pending change preserves the last usable rollback', () async {
    const key = LocalStorageService.kThemeMode;
    const shield = 'current';
    await storage.setValue(key, 2);
    await storage.updateShieldRules([shield], replace: true);
    String hash(Object value) =>
        sha256.convert(utf8.encode(jsonEncode(value))).toString();
    final journal = await Hive.openBox<dynamic>('WebDavRestore');
    await journal.put('rollback', {
      'current': {
        'shield': {
          'before': ['old'],
          'after': hash([shield]),
        },
      },
      'pending': {
        'settings': {
          'before': {key: 0},
          'after': hash({key: 1}),
        },
      },
    });
    await journal.flush();
    final restore = WebDavRestore();
    final preview = await restore.preview(
      WebDavBackup.read(
        Archive()..addFile(document(WebDavBackup.settingsFile, {key: 2})),
      ),
    );
    final unchanged = preview.change(RestoreGroup.settings, RestoreMode.merge);
    expect(unchanged.changed, isFalse);
    final result = await restore.apply([unchanged]);
    expect(result.unchanged, ['设置']);
    expect(result.skipped, isEmpty);
    expect((await restore.rollback()).succeeded, ['屏蔽词']);
    expect(storage.shieldBox.values, ['old']);
    expect(storage.getValue(key, 0), 2);
  });

  test(
    'bad settings are rejected before any backup category is written',
    () async {
      final archive = Archive()
        ..addFile(
          document('SimpleLive_Tags.json', [
            {'id': 'a', 'tag': 'A', 'userId': <String>[]},
          ]),
        )
        ..addFile(
          document('SimpleLive_Settings.json', {
            LocalStorageService.kThemeMode: 'bad',
          }),
        );
      await expectLater(
        controller.restoreArchive(archive),
        throwsFormatException,
      );
      expect(database.getFollowTagList(), isEmpty);
    },
  );

  test(
    'preview uses the local tag identity and keeps bells off by default',
    () async {
      final local = FollowUser(
        id: 'douyu_1',
        siteId: 'douyu',
        roomId: '1',
        userName: 'local',
        face: '',
        addTime: DateTime(2025),
        notifyLive: true,
      );
      final incoming = FollowUser(
        id: 'douyu_2',
        siteId: 'douyu',
        roomId: '2',
        userName: 'remote',
        face: '',
        addTime: DateTime(2025),
        notifyLive: true,
      );
      await database.importSnapshot(
        follows: [local.toJson()],
        tags: [
          {
            'id': 'local',
            'tag': '收藏',
            'userId': [local.id],
          },
        ],
        replace: true,
      );
      final backup = WebDavBackup.read(
        Archive()
          ..addFile(document(WebDavBackup.followsFile, [incoming.toJson()]))
          ..addFile(
            document(WebDavBackup.tagsFile, [
              {
                'id': 'remote',
                'tag': '收藏',
                'userId': [incoming.id],
              },
            ]),
          ),
      );
      final restore = WebDavRestore();
      final preview = await restore.preview(backup);
      final change = preview.change(RestoreGroup.follows, RestoreMode.merge);
      expect(change.differences['关注']!.added, 1);
      expect(change.differences['标签']!.added, 0);
      expect(database.followBox.get(incoming.id), isNull);
      expect((await restore.apply([change])).succeeded, ['关注和标签']);
      expect(database.getFollowTagList().single.id, 'local');
      expect(database.getFollowTagList().single.userId, [
        local.id,
        incoming.id,
      ]);
      expect(database.followBox.get(local.id)!.notifyLive, isTrue);
      expect(database.followBox.get(incoming.id)!.notifyLive, isFalse);
      await Hive.box('WebDavRestore').close();
      expect((await WebDavRestore().rollback()).succeeded, ['关注和标签']);
      expect(database.followBox.get(incoming.id), isNull);
      expect(database.followBox.get(local.id)!.notifyLive, isTrue);
    },
  );

  test(
    'commit checks staleness and rollback preserves later changes',
    () async {
      const key = LocalStorageService.kThemeMode;
      await storage.setValue(key, 1);
      final backup = WebDavBackup.read(
        Archive()
          ..addFile(document(WebDavBackup.settingsFile, {key: 2}))
          ..addFile(document(WebDavBackup.shieldFile, ['测试'])),
      );
      final restore = WebDavRestore();
      var preview = await restore.preview(backup);
      await storage.setValue(key, 0);
      final stale = await restore.apply([
        preview.change(RestoreGroup.settings, RestoreMode.merge),
      ]);
      expect(stale.skipped, ['设置']);
      expect(await restore.hasRollback(), isFalse);
      preview = await restore.preview(backup);
      await restore.apply([
        preview.change(RestoreGroup.settings, RestoreMode.merge),
        preview.change(RestoreGroup.shield, RestoreMode.merge),
      ]);
      await storage.setValue(key, 1);
      final undo = await restore.rollback();
      expect(undo.skipped, ['设置']);
      expect(undo.succeeded, ['屏蔽词']);
      expect(storage.getValue(key, 0), 1);
      expect(storage.shieldBox.isEmpty, isTrue);
    },
  );

  test(
    'restore reports partial failure without claiming a full success',
    () async {
      await Get.delete<DBService>(force: true);
      final failing = _FailingHistoryDB();
      await failing.init();
      Get.put<DBService>(failing);
      final archive = Archive()
        ..addFile(
          document('SimpleLive_histories.json', [
            History(
              id: 'douyu_1',
              roomId: '1',
              siteId: 'douyu',
              userName: 'one',
              face: '',
              updateTime: DateTime(2026),
            ).toJson(),
          ]),
        )
        ..addFile(
          document('SimpleLive_Settings.json', {
            LocalStorageService.kThemeMode: 1,
          }),
        );
      final result = await controller.restoreArchive(archive);
      expect(result.failed, ['观看历史']);
      expect(result.succeeded, ['设置']);
      expect(
        storage.settingsBox.get(LocalStorageService.kWebDAVLastRecoverTime),
        isNull,
      );
    },
  );

  test(
    'pending preference restore is rolled back without clearing unrelated values',
    () async {
      await storage.settingsBox.putAll({
        LocalStorageService.kThemeMode: 2,
        'unrelated': 'keep',
        '_pendingSettingsRestore': {
          'previous': {LocalStorageService.kThemeMode: 1},
          'absent': [LocalStorageService.kDanmuSize],
        },
        LocalStorageService.kDanmuSize: 22.0,
      });
      await storage.recoverSettingsRestore();
      expect(storage.settingsBox.get(LocalStorageService.kThemeMode), 1);
      expect(storage.settingsBox.get('unrelated'), 'keep');
      expect(
        storage.settingsBox.containsKey(LocalStorageService.kDanmuSize),
        isFalse,
      );
    },
  );

  test(
    'preference edits queued after a restore keep their newer value',
    () async {
      await Future.wait([
        storage.restoreSettings({LocalStorageService.kThemeMode: 1}),
        storage.setValue(LocalStorageService.kThemeMode, 2),
      ]);
      expect(storage.settingsBox.get(LocalStorageService.kThemeMode), 2);
    },
  );

  test(
    'interrupted desktop migration resumes remaining files and retains originals',
    () async {
      final old = await Directory('${directory.path}/old').create();
      final target = await Directory('${directory.path}/new').create();
      await File('${old.path}/followuser.hive').writeAsBytes([1, 2, 3]);
      await File('${old.path}/hostiry.hive').writeAsBytes([4, 5]);
      await File('${old.path}/localstorage.hive').writeAsBytes([6]);
      await expectLater(
        migrateData(
          source: old,
          destination: target,
          beforeCopy: (name) {
            if (name == 'hostiry') throw StateError('interruption');
          },
        ),
        throwsStateError,
      );
      await File('${target.path}/followuser.hive').writeAsBytes([9]);
      await migrateData(source: old, destination: target);
      expect(await File('${target.path}/followuser.hive').readAsBytes(), [9]);
      expect(await File('${target.path}/history.hive').readAsBytes(), [4, 5]);
      expect(await File('${target.path}/localstorage.hive').readAsBytes(), [6]);
      expect(await File('${old.path}/followuser.hive').readAsBytes(), [
        1,
        2,
        3,
      ]);
      expect(
        target.listSync().any((file) => file.path.endsWith('.migrating')),
        isFalse,
      );
    },
  );
  test(
    'shield replacement validates the full batch before publishing or writing',
    () async {
      final settings = AppSettingsController.instance;
      await settings.importShieldRules(['keep'], replace: true);
      await expectLater(
        settings.importShieldRules(['valid', 42], replace: true),
        throwsFormatException,
      );
      expect(storage.shieldBox.values, ['keep']);
      expect(settings.shieldList, {'keep'});
      await Future.wait([
        settings.importShieldRules(['imported'], replace: true),
        settings.addShieldList('newer'),
      ]);
      expect(settings.shieldList, {'imported', 'newer'});
    },
  );

  test(
    'interrupted shield transaction restores originals and leaves unrelated preferences',
    () async {
      await storage.settingsBox.putAll({
        '_pendingShieldRestore': {'original': 'original'},
        'unrelated': 1,
      });
      await storage.shieldBox.putAll({
        'original': 'original',
        'partial': 'partial',
      });
      await storage.recoverShieldRules();
      expect(storage.shieldBox.toMap(), {'original': 'original'});
      expect(storage.settingsBox.get('unrelated'), 1);
      expect(storage.settingsBox.containsKey('_pendingShieldRestore'), isFalse);
    },
  );

  test('preference font weights accept the full UI range and reject zero', () {
    expect(
      LocalStorageService.validateSettings({
        LocalStorageService.kDanmuFontWeight: 9,
      }),
      {LocalStorageService.kDanmuFontWeight: 9},
    );
    expect(
      () => LocalStorageService.validateSettings({
        LocalStorageService.kDanmuFontWeight: 0,
      }),
      throwsFormatException,
    );
  });
  test(
    'duplicate tag names fail whole WebDAV preflight before valid settings write',
    () async {
      final archive = Archive()
        ..addFile(
          document('SimpleLive_Tags.json', [
            {'id': 'a', 'tag': 'Same', 'userId': <String>[]},
            {'id': 'b', 'tag': 'Same', 'userId': <String>[]},
          ]),
        )
        ..addFile(
          document('SimpleLive_Settings.json', {
            LocalStorageService.kThemeMode: 1,
          }),
        );
      await expectLater(
        controller.restoreArchive(archive),
        throwsFormatException,
      );
      expect(
        storage.settingsBox.containsKey(LocalStorageService.kThemeMode),
        isFalse,
      );
      expect(database.getFollowTagList(), isEmpty);
    },
  );

  test(
    'history clear queued after import cannot be undone by the import',
    () async {
      final item = History(
        id: 'douyu_1',
        roomId: '1',
        siteId: 'douyu',
        userName: 'one',
        face: '',
        updateTime: DateTime(2026),
      );
      await Future.wait([
        database.importHistories([item.toJson()], replace: true),
        database.clearHistories(),
      ]);
      expect(database.getHistores(), isEmpty);
    },
  );
  test('imported navigation order ignores unknown and duplicate IDs', () async {
    final known = Sites.allSites.keys.first;
    await storage.restoreSettings({
      LocalStorageService.kSiteSort: ',unknown,$known,$known',
      LocalStorageService.kHomeSort: ',unknown,unknown',
    });
    final settings = AppSettingsController();
    settings.initSiteSort();
    settings.initHomeSort();
    expect(settings.siteSort.first, known);
    expect(settings.siteSort.toSet(), Sites.allSites.keys.toSet());
    expect(settings.siteSort.length, Sites.allSites.length);
    expect(settings.homeSort.toSet(), Constant.allHomePages.keys.toSet());
    expect(settings.homeSort.length, Constant.allHomePages.length);
  });

  test(
    'unsupported platform is rejected before import can reach platform UI',
    () async {
      final follow = FollowUser(
        id: 'unknown_1',
        siteId: 'unknown',
        roomId: '1',
        userName: 'one',
        face: '',
        addTime: DateTime(2026),
      );
      await expectLater(
        database.importFollows([follow.toJson()], replace: true),
        throwsFormatException,
      );
      expect(database.getFollowList(), isEmpty);
    },
  );
}
