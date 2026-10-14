import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DBService database;

  FollowUserTag tag(String id, String name, [List<String> users = const []]) =>
      FollowUserTag(id: id, tag: name, userId: List<String>.from(users));

  Future<DBService> openDatabase({
    FutureOr<void> Function(String, Object?)? beforeTagWrite,
  }) async => DBService(beforeTagWrite: beforeTagWrite)
    ..tagBox = await Hive.openBox<FollowUserTag>('tags')
    ..followBox = await Hive.openBox<FollowUser>('follows');

  Future<void> restart() async {
    await Hive.close();
    database = await openDatabase();
    await database.repairFollowTagStorage();
  }

  Box<dynamic> getMetadata() => Hive.box<dynamic>('tags_order');
  Box<dynamic> getBackup() => Hive.box<dynamic>('tags_legacy_backup');

  List<Map<String, dynamic>> readTags() =>
      database.getFollowTagList().map((value) => value.toJson()).toList();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('db-follow-tags-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(FollowUserAdapter());
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(FollowUserTagAdapter());
    }
    database = await openDatabase();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('production init repairs tags before returning', () async {
    final legacy = await Hive.openBox<FollowUserTag>('FollowUserTag');
    final original = tag('startup-id', 'Startup', ['existing_room']);
    await legacy.put(0, original);
    await Hive.close();

    database = DBService();
    await database.init();
    expect(database.tagBox.keys, ['startup-id']);
    expect(readTags(), [original.toJson()]);
    expect(Hive.box<dynamic>('followusertag_order').get('repairVersion'), 1);
    await Hive.close();
    database = DBService();
    await database.init();
    expect(readTags(), [original.toJson()]);
  });

  test(
    'repairs legacy aliases and keeps memberships and unrelated follows',
    () async {
      final beta = tag('beta-id', 'Beta', ['site_2', 'unknown_room']);
      final alpha = tag('alpha-id', 'Alpha', ['site_1']);
      final imported = tag('imported/non-uuid', 'Imported', ['site_3']);
      final malformed = tag('', 'Unrecoverable identity', ['keep_me']);
      await database.tagBox.putAll({
        0: beta,
        1: alpha,
        'wrong-key': imported,
        'unrecognized-record': malformed,
      });
      final follow = FollowUser(
        id: 'site_1',
        roomId: '1',
        siteId: 'site',
        userName: 'User',
        face: '',
        addTime: DateTime(2026),
        notifyLive: true,
      );
      await database.followBox.put(follow.id, follow);

      await database.repairFollowTagStorage();
      expect(
        database.tagBox.keys,
        unorderedEquals([
          'beta-id',
          'alpha-id',
          'imported/non-uuid',
          'unrecognized-record',
        ]),
      );
      expect(readTags(), [beta.toJson(), alpha.toJson(), imported.toJson()]);
      expect(
        database.tagBox.get('unrecognized-record')!.toJson(),
        malformed.toJson(),
      );
      expect(database.followBox.get('site_1')!.toJson(), follow.toJson());
      expect(getMetadata().get('repairVersion'), 1);
      expect(getMetadata().containsKey('pendingRepair'), isFalse);
      expect(getBackup().length, 4);

      await restart();
      expect(readTags(), [beta.toJson(), alpha.toJson(), imported.toJson()]);
      expect(database.followBox.get('site_1')!.toJson(), follow.toJson());
      expect(
        database.tagBox.get('unrecognized-record')!.toJson(),
        malformed.toJson(),
      );
    },
  );

  test(
    'canonical record wins a conflict and both originals survive restart',
    () async {
      final stale = tag('a', 'Old name', ['old_room']);
      final current = tag('a', 'New name', ['new_room']);
      await database.tagBox.putAll({0: stale, 'a': current});
      await database.repairFollowTagStorage();

      expect(readTags(), [current.toJson()]);
      expect(getBackup().get('int:0'), {
        'sourceKey': 0,
        'record': stale.toJson(),
      });
      expect(getBackup().get('string:a'), {
        'sourceKey': 'a',
        'record': current.toJson(),
      });
      final originals = Map<dynamic, dynamic>.from(getBackup().toMap());
      await restart();
      expect(readTags(), [current.toJson()]);
      final backup = await Hive.openBox<dynamic>('tags_legacy_backup');
      expect(backup.toMap(), originals);
    },
  );

  test(
    'integer and string source keys receive distinct durable backups',
    () async {
      await database.tagBox.putAll({0: tag('a', 'A'), '0': tag('b', 'B')});
      await database.repairFollowTagStorage();
      expect(getBackup().keys, unorderedEquals(['int:0', 'string:0']));
      expect(getBackup().get('int:0')['record']['id'], 'a');
      expect(getBackup().get('string:0')['record']['id'], 'b');
      await restart();
      expect(database.tagBox.keys, unorderedEquals(['a', 'b']));
    },
  );

  test('first backup is never replaced after a partial migration', () async {
    final original = tag('a', 'Original', ['original_room']);
    await database.tagBox.put(0, original);
    database = await openDatabase(
      beforeTagWrite: (operation, _) {
        if (operation == 'metadata.plan') throw StateError('disk full');
      },
    );
    await expectLater(database.repairFollowTagStorage(), throwsStateError);
    expect(database.tagBox.containsKey(0), isTrue);
    expect(getMetadata().containsKey('repairVersion'), isFalse);

    await Hive.close();
    database = await openDatabase();
    // Simulate an older writer changing the alias between launch attempts.
    final later = tag('a', 'Later', ['later_room']);
    await database.tagBox.put(0, later);
    await database.repairFollowTagStorage();
    expect(readTags(), [later.toJson()]);
    expect(getBackup().get('int:0')['record'], original.toJson());
    await restart();
    final backup = await Hive.openBox<dynamic>('tags_legacy_backup');
    expect(backup.get('int:0')['record'], original.toJson());
  });

  for (final failure in <(String, int)>[
    ('backup.put', 2),
    ('backup.flush', 1),
    ('metadata.plan', 1),
    ('metadata.flush', 1),
    ('tags.put', 2),
    ('tags.flush', 1),
    ('metadata.order', 1),
    ('metadata.flush', 2),
    ('tags.deleteAlias', 2),
    ('tags.flush', 2),
    ('metadata.clearPlan', 1),
    ('metadata.flush', 3),
    ('metadata.version', 1),
  ]) {
    test('repair resumes after ${failure.$1} failure ${failure.$2}', () async {
      final alpha = tag('a', 'Alpha', ['room_a']);
      final beta = tag('b', 'Beta', ['room_b']);
      await database.tagBox.putAll({0: alpha, 1: beta});
      var calls = 0;
      database = await openDatabase(
        beforeTagWrite: (operation, _) {
          if (operation == failure.$1 && ++calls == failure.$2) {
            throw StateError('injected storage failure');
          }
        },
      );
      await expectLater(database.repairFollowTagStorage(), throwsStateError);
      expect(getMetadata().containsKey('repairVersion'), isFalse);
      // No alias removal is allowed before records AND ordering are durable.
      if ({
            'backup.put',
            'backup.flush',
            'metadata.plan',
            'tags.put',
            'metadata.order',
          }.contains(failure.$1) ||
          (failure.$1 == 'tags.flush' && failure.$2 == 1) ||
          (failure.$1 == 'metadata.flush' && failure.$2 <= 2)) {
        expect(database.tagBox.containsKey(0), isTrue);
        expect(database.tagBox.containsKey(1), isTrue);
      }

      await restart();
      expect(database.tagBox.keys, unorderedEquals(['a', 'b']));
      expect(readTags(), [alpha.toJson(), beta.toJson()]);
      expect(getMetadata().get('ids'), ['a', 'b']);
      expect(getMetadata().get('repairVersion'), 1);
      expect(getMetadata().containsKey('pendingRepair'), isFalse);
      final backup = await Hive.openBox<dynamic>('tags_legacy_backup');
      expect(backup.get('int:0')['record'], alpha.toJson());
      expect(backup.get('int:1')['record'], beta.toJson());
      final originalBackup = Map<dynamic, dynamic>.from(backup.toMap());
      await database.repairFollowTagStorage();
      expect(readTags(), [alpha.toJson(), beta.toJson()]);
      expect(backup.toMap(), originalBackup);
    });
  }

  test(
    'interrupted mismatched-key cycle replays the original repair plan',
    () async {
      final a = tag('a', 'A', ['room_a']);
      final b = tag('b', 'B', ['room_b']);
      final c = tag('c', 'C', ['room_c']);
      await database.tagBox.putAll({'a': b, 'b': c, 'c': a});
      var canonicalWrites = 0;
      database = await openDatabase(
        beforeTagWrite: (operation, _) {
          if (operation == 'tags.put' && ++canonicalWrites == 2) {
            throw StateError('interrupted canonical writes');
          }
        },
      );
      await expectLater(database.repairFollowTagStorage(), throwsStateError);
      expect(getMetadata().containsKey('pendingRepair'), isTrue);
      final originals = Map<dynamic, dynamic>.from(getBackup().toMap());

      await restart();
      expect(readTags(), [b.toJson(), c.toJson(), a.toJson()]);
      expect(database.tagBox.get('a')!.toJson(), a.toJson());
      expect(database.tagBox.get('b')!.toJson(), b.toJson());
      expect(database.tagBox.get('c')!.toJson(), c.toJson());
      final backup = await Hive.openBox<dynamic>('tags_legacy_backup');
      expect(backup.toMap(), originals);
      await restart();
      expect(readTags(), [b.toJson(), c.toJson(), a.toJson()]);
    },
  );

  test(
    'reorder, rename, delete and stale reorder never duplicate or resurrect',
    () async {
      final alpha = await database.addFollowTag('Alpha');
      final beta = await database.addFollowTag('Beta');
      final gamma = await database.addFollowTag('Gamma');
      final stale = [beta, alpha];
      await database.updateFollowTagOrder(stale);
      expect(database.getFollowTagList().map((tag) => tag.id), [
        beta.id,
        alpha.id,
        gamma.id,
      ]);
      final renamed = beta.copyWith(tag: 'Renamed', userId: ['retained_room']);
      await database.updateFollowTag(renamed);
      // Stale objects must not overwrite a rename or omit a newly created tag.
      await database.updateFollowTagOrder(stale);
      expect(database.tagBox.get(beta.id)!.toJson(), renamed.toJson());
      expect(database.tagBox.length, 3);
      expect(database.tagBox.keys.every((key) => key is String), isTrue);

      await database.deleteFollowTag(beta.id);
      await database.updateFollowTagOrder(stale);
      await database.updateFollowTag(renamed);
      await restart();
      expect(database.getFollowTagList().map((tag) => tag.id), [
        alpha.id,
        gamma.id,
      ]);
      expect(database.tagBox.containsKey(beta.id), isFalse);
      expect(database.tagBox.length, 2);
    },
  );

  test(
    'invalid saved order falls back without dropping unknown valid IDs',
    () async {
      await database.tagBox.putAll({
        'a': tag('a', 'A'),
        'b': tag('b', 'B'),
        'external/import': tag('external/import', 'External'),
      });
      final metadata = await Hive.openBox<dynamic>('tags_order');
      await metadata.put('ids', ['b', 'missing', 42, 'b']);
      await database.repairFollowTagStorage();
      expect(database.getFollowTagList().map((tag) => tag.id), [
        'b',
        'a',
        'external/import',
      ]);
      await database.updateFollowTagOrder([tag('missing', 'Stale')]);
      await restart();
      expect(database.getFollowTagList().map((tag) => tag.id), [
        'b',
        'a',
        'external/import',
      ]);
    },
  );

  test(
    'serialized repair cannot resurrect a concurrently deleted tag',
    () async {
      await database.tagBox.putAll({0: tag('a', 'A'), 1: tag('b', 'B')});
      final started = Completer<void>();
      final resume = Completer<void>();
      database = await openDatabase(
        beforeTagWrite: (operation, _) async {
          if (operation == 'metadata.plan') {
            started.complete();
            await resume.future;
          }
        },
      );
      final repair = database.repairFollowTagStorage();
      await started.future;
      final deletion = database.deleteFollowTag('a');
      final reorder = database.updateFollowTagOrder([
        tag('a', 'A'),
        tag('b', 'B'),
      ]);
      resume.complete();
      await Future.wait([repair, deletion, reorder]);
      await restart();
      expect(database.tagBox.keys, ['b']);
      expect(getMetadata().get('ids'), ['b']);
    },
  );

  test('a failed queued mutation does not poison subsequent writes', () async {
    final alpha = await database.addFollowTag('Alpha');
    var shouldFail = true;
    database = await openDatabase(
      beforeTagWrite: (operation, _) {
        if (operation == 'tags.update' && shouldFail) {
          shouldFail = false;
          throw StateError('one failed write');
        }
      },
    );
    final failed = database.updateFollowTag(alpha.copyWith(tag: 'Failed'));
    final succeeded = database.updateFollowTag(
      alpha.copyWith(tag: 'Succeeded'),
    );
    await expectLater(failed, throwsStateError);
    await succeeded;
    await restart();
    expect(database.getFollowTagList().single.tag, 'Succeeded');
  });

  test(
    'returned tags and queued update inputs do not alias stored records',
    () async {
      final alpha = await database.addFollowTag('Alpha');
      alpha.userId.add('not_saved');
      expect(database.tagBox.get(alpha.id)!.userId, isEmpty);
      final read = database.getFollowTagList().single;
      read.userId.add('also_not_saved');
      expect(database.tagBox.get(alpha.id)!.userId, isEmpty);

      final update = tag(alpha.id, 'Renamed', ['saved']);
      final pending = database.updateFollowTag(update);
      update.userId.add('late_mutation');
      await pending;
      await restart();
      expect(database.tagBox.get(alpha.id)!.userId, ['saved']);
    },
  );
}
