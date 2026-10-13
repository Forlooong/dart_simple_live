import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_import.dart';
import 'package:simple_live_app/services/follow_service.dart';

Map<String, dynamic> _legacyJson() => {
      'id': 'bilibili_123',
      'siteId': 'bilibili',
      'roomId': '123',
      'userName': '主播',
      'face': '',
      'addTime': '2026-10-13 10:00:00.000',
      'tag': '游戏',
    };

FollowUser _follow({bool notifyLive = false}) => FollowUser.fromJson({
      ..._legacyJson(),
      'notifyLive': notifyLive,
    });

// Writes exactly the on-disk schema used before room notification preferences.
// Reopening this file with the production adapter tests the actual upgrade.
class _LegacyFollowUserAdapter extends TypeAdapter<FollowUser> {
  @override
  final int typeId = 1;

  @override
  FollowUser read(BinaryReader reader) =>
      throw UnsupportedError('This fixture only writes legacy records.');

  @override
  void write(BinaryWriter writer, FollowUser obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.roomId)
      ..writeByte(2)
      ..write(obj.siteId)
      ..writeByte(3)
      ..write(obj.userName)
      ..writeByte(4)
      ..write(obj.face)
      ..writeByte(5)
      ..write(obj.addTime)
      ..writeByte(6)
      ..write(obj.tag);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new follows do not subscribe to live notifications by default', () {
    final follow = FollowUser(
      id: 'bilibili_123',
      roomId: '123',
      siteId: 'bilibili',
      userName: '主播',
      face: '',
      addTime: DateTime(2026, 10, 13),
    );

    expect(follow.notifyLive, isFalse);
  });

  test('old JSON adds a follow without enabling notifications', () {
    expect(FollowUser.fromJson(_legacyJson()).notifyLive, isFalse);
  });

  test('old JSON preserves an existing room notification choice', () {
    for (final enabled in [true, false]) {
      final existing = _follow(notifyLive: enabled);
      final imported = FollowUser.fromJson(_legacyJson(), existing: existing);

      expect(imported.notifyLive, enabled);
      expect(imported.userName, '主播');
      expect(existing.notifyLive, enabled);
    }
  });

  test('old JSON cannot inherit another room notification choice', () {
    final existing = _follow(notifyLive: true);
    for (final changedIdentity in [
      {'id': 'bilibili_456'},
      {'roomId': '456'},
      {'siteId': 'douyu'},
    ]) {
      final imported = FollowUser.fromJson(
        {..._legacyJson(), ...changedIdentity},
        existing: existing,
      );
      expect(imported.notifyLive, isFalse);
    }
  });

  test('explicit JSON preferences override the previous choice', () {
    for (final enabled in [true, false]) {
      final existing = _follow(notifyLive: !enabled);
      final imported = FollowUser.fromJson(
        {..._legacyJson(), 'notifyLive': enabled},
        existing: existing,
      );

      expect(imported.notifyLive, enabled);
      expect(existing.notifyLive, !enabled);
    }
  });

  test('malformed JSON preference cannot silently enable notifications', () {
    for (final value in [null, 'true', 1, [], {}]) {
      final imported = FollowUser.fromJson(
        {..._legacyJson(), 'notifyLive': value},
        existing: _follow(notifyLive: true),
      );
      expect(imported.notifyLive, isFalse);
    }
  });

  test('JSON export and import retain enabled and disabled preferences', () {
    for (final enabled in [true, false]) {
      final original = _follow(notifyLive: enabled);
      final exported =
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>;
      final imported = FollowUser.fromJson(exported);

      expect(exported['notifyLive'], enabled);
      expect(imported.notifyLive, enabled);
      expect(imported.id, original.id);
      expect(imported.tag, original.tag);
      expect(imported.addTime, original.addTime);
    }
  });

  group('Hive notification preference migration', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('simple_live_notify_');
      Hive.init(directory.path);
    });

    tearDown(() async {
      Get.reset();
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test('reads existing seven-field follows without opting them in', () async {
      Hive.registerAdapter(_LegacyFollowUserAdapter(), override: true);
      var box = await Hive.openBox<FollowUser>('follow');
      final original = _follow(notifyLive: true);
      await box.put(original.id, original);
      await box.close();

      Hive.registerAdapter(FollowUserAdapter(), override: true);
      box = await Hive.openBox<FollowUser>('follow');
      final migrated = box.get(original.id)!;

      expect(migrated.notifyLive, isFalse);
      expect(migrated.id, original.id);
      expect(migrated.userName, original.userName);
      expect(migrated.addTime, original.addTime);
      expect(migrated.tag, original.tag);
    });

    test('persists enabling and disabling through database reopen', () async {
      Hive.registerAdapter(FollowUserAdapter(), override: true);
      var box = await Hive.openBox<FollowUser>('follow');
      final follow = _follow(notifyLive: true);
      await box.put(follow.id, follow);
      await box.close();

      box = await Hive.openBox<FollowUser>('follow');
      expect(box.get(follow.id)!.notifyLive, isTrue);

      final saved = box.get(follow.id)!;
      saved.notifyLive = false;
      await box.put(saved.id, saved);
      await box.close();

      box = await Hive.openBox<FollowUser>('follow');
      expect(box.get(follow.id)!.notifyLive, isFalse);
    });

    test('follow import preserves old choices and exports explicit changes',
        () async {
      Hive.registerAdapter(FollowUserAdapter(), override: true);
      final box = await Hive.openBox<FollowUser>('follow');
      final existing = _follow(notifyLive: true)..tag = '全部';
      await box.put(existing.id, existing);
      Get.put<DBService>(DBService()..followBox = box);
      // Do not register the service: this exercises import/export without
      // starting the app's periodic live-status polling.
      final service = FollowService();

      await service.inputJson(jsonEncode([
        {..._legacyJson(), 'tag': '全部'},
      ]));
      expect(box.get(existing.id)!.notifyLive, isTrue);

      service.followList.assignAll(box.values);
      final exported = jsonDecode(service.generateJson()) as List;
      expect(exported.single['notifyLive'], isTrue);

      exported.single['notifyLive'] = false;
      await service.inputJson(jsonEncode(exported));
      expect(box.get(existing.id)!.notifyLive, isFalse);
      expect(box.length, 1);
      service.followList.assignAll(box.values);
      final disabledExport = jsonDecode(service.generateJson()) as List;
      expect(disabledExport.single['notifyLive'], isFalse);
      service.onClose();
    });

    test('replacement retains selected rooms in every Hive snapshot', () async {
      Hive.registerAdapter(FollowUserAdapter(), override: true);
      final box = await Hive.openBox<FollowUser>('follow');
      final retained = _follow(notifyLive: true);
      final removed = _follow(notifyLive: true)
        ..id = 'bilibili_456'
        ..roomId = '456';
      await box.putAll({retained.id: retained, removed.id: removed});
      final selectedSnapshots = <Set<String>>[];
      final subscription = box.watch().listen((_) {
        selectedSnapshots.add(box.values
            .where((room) => room.notifyLive)
            .map((room) => room.id)
            .toSet());
      });
      try {
        await importFollowUsers(
            box,
            [
              _legacyJson(),
              {
                ..._legacyJson(),
                'id': 'bilibili_789',
                'roomId': '789',
                'notifyLive': true,
              },
            ],
            replace: true);
        await Future<void>.delayed(Duration.zero);

        expect(selectedSnapshots, isNotEmpty);
        expect(selectedSnapshots.every((ids) => ids.contains(retained.id)),
            isTrue);
        expect(box.get(retained.id)!.notifyLive, isTrue);
        expect(box.containsKey(removed.id), isFalse);
        expect(box.get('bilibili_789')!.notifyLive, isTrue);
      } finally {
        await subscription.cancel();
      }
    });

    test('malformed replacement batch leaves all existing follows untouched',
        () async {
      Hive.registerAdapter(FollowUserAdapter(), override: true);
      final box = await Hive.openBox<FollowUser>('follow');
      final existing = _follow(notifyLive: true);
      await box.put(existing.id, existing);
      var events = 0;
      final subscription = box.watch().listen((_) => events++);
      try {
        await expectLater(
          importFollowUsers(
              box,
              [
                {..._legacyJson(), 'notifyLive': false},
                {..._legacyJson(), 'id': 'bilibili_456', 'addTime': 'invalid'},
              ],
              replace: true),
          throwsFormatException,
        );
        await Future<void>.delayed(Duration.zero);

        expect(events, 0);
        expect(box.length, 1);
        expect(box.get(existing.id)!.notifyLive, isTrue);
      } finally {
        await subscription.cancel();
      }
    });

    test('empty merge retains follows while empty replacement removes them',
        () async {
      Hive.registerAdapter(FollowUserAdapter(), override: true);
      final box = await Hive.openBox<FollowUser>('follow');
      final existing = _follow(notifyLive: true);
      await box.put(existing.id, existing);

      await importFollowUsers(box, [], replace: false);
      expect(box.get(existing.id)!.notifyLive, isTrue);
      await importFollowUsers(box, [], replace: true);
      expect(box.isEmpty, isTrue);
    });
  });
}
