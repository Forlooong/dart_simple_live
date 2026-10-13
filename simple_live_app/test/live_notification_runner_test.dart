import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/live_notifications/live_check_runner.dart';
import 'package:simple_live_app/services/live_notifications/notification_store.dart';
import 'package:simple_live_app/services/live_notifications/notification_subscription.dart';

NotificationSubscription _room(String roomId, {String generation = 'first'}) =>
    NotificationSubscription(
      id: 'bilibili_$roomId',
      siteId: 'bilibili',
      roomId: roomId,
      userName: '主播 $roomId',
      generation: generation,
    );

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

// Match the persisted store's snapshot semantics: callers cannot mutate stored
// state through a reference returned from an earlier read.
class _MemoryStore implements NotificationStore {
  _MemoryStore(List<NotificationSubscription> rooms)
      : config = NotificationConfig(rooms: rooms);

  NotificationConfig config;
  Map<String, dynamic> _state = {};
  Future<void> Function()? afterWrite;

  @override
  Future<NotificationConfig> readConfig() async =>
      NotificationConfig.fromJson(config.toJson());

  @override
  Future<Map<String, dynamic>> readState() async => _copy(_state);

  @override
  Future<void> writeState(Map<String, dynamic> state) async {
    _state = _copy(state);
    await afterWrite?.call();
  }
}

LiveCheckRunner _runner(
  NotificationStore store, {
  required LiveStatusCheck check,
  List<String>? shown,
  List<String>? cancelled,
  Duration roomTimeout = const Duration(seconds: 20),
  Duration budget = const Duration(minutes: 7),
  LiveAlert? show,
}) =>
    LiveCheckRunner(
      store: store,
      check: check,
      show: show ?? (room) async => shown?.add(room.id),
      cancel: (room) async => cancelled?.add(room.id),
      roomTimeout: roomTimeout,
      budget: budget,
    );

Future<Directory> _temporaryDirectory() async {
  final directory =
      await Directory.systemTemp.createTemp('simple-live-notifications-');
  addTearDown(() async {
    await directory.delete(recursive: true);
  });
  return directory;
}

void main() {
  group('LiveCheckRunner', () {
    test('an empty selection never checks or alerts', () async {
      final checked = <String>[];
      final shown = <String>[];
      await _runner(
        _MemoryStore([]),
        check: (room) async {
          checked.add(room.id);
          return true;
        },
        shown: shown,
      ).run();
      expect(checked, isEmpty);
      expect(shown, isEmpty);
    });

    test('the first successful live sample establishes a silent baseline',
        () async {
      final room = _room('a');
      final store = _MemoryStore([room]);
      final shown = <String>[];
      final runner = _runner(store, check: (_) async => true, shown: shown);
      await runner.run();
      await runner.run();
      expect(shown, isEmpty);
      expect((await store.readState())['rooms'][room.id]['live'], isTrue);
    });

    test('offline to live alerts once until another offline sample', () async {
      final room = _room('a');
      final store = _MemoryStore([room]);
      final shown = <String>[];
      var live = false;
      final runner = _runner(store, check: (_) async => live, shown: shown);
      await runner.run();
      live = true;
      await runner.run();
      await runner.run();
      expect(shown, [room.id]);
      live = false;
      await runner.run();
      live = true;
      await runner.run();
      expect(shown, [room.id, room.id]);
    });

    for (final previousLive in [false, true]) {
      test('a request failure preserves the previous $previousLive state',
          () async {
        final room = _room('a');
        final store = _MemoryStore([room]);
        final shown = <String>[];
        await _runner(store, check: (_) async => previousLive).run();
        await _runner(
          store,
          check: (_) async => throw const SocketException('unavailable'),
          shown: shown,
        ).run();
        expect(
            (await store.readState())['rooms'][room.id]['live'], previousLive);
        await _runner(store, check: (_) async => true, shown: shown).run();
        expect(shown, previousLive ? isEmpty : [room.id]);
      });
    }

    test('a failed first sample cannot make a later live baseline an alert',
        () async {
      final room = _room('a');
      final store = _MemoryStore([room]);
      final shown = <String>[];
      await _runner(
        store,
        check: (_) async => throw const SocketException('unavailable'),
      ).run();
      await _runner(store, check: (_) async => true, shown: shown).run();
      expect(shown, isEmpty);
    });

    for (final runWhileDisabled in [false, true]) {
      test(
          're-subscribing resets the baseline (disabled run: $runWhileDisabled)',
          () async {
        final first = _room('a');
        final second = _room('a', generation: 'resubscribed');
        final store = _MemoryStore([first]);
        final shown = <String>[];
        await _runner(store, check: (_) async => false).run();
        store.config = const NotificationConfig();
        if (runWhileDisabled) {
          await _runner(store, check: (_) async => true, shown: shown).run();
          expect((await store.readState())['rooms'], isEmpty);
        }
        store.config = NotificationConfig(rooms: [second]);
        await _runner(store, check: (_) async => true, shown: shown).run();
        expect(shown, isEmpty);
        expect((await store.readState())['rooms'][second.id]['generation'],
            second.generation);
        await _runner(store, check: (_) async => false).run();
        await _runner(store, check: (_) async => true, shown: shown).run();
        expect(shown, [second.id]);
      });
    }

    for (final resubscribe in [false, true]) {
      test(
          'opt-out during a request suppresses its result (re-add: $resubscribe)',
          () async {
        final first = _room('a');
        final store = _MemoryStore([first]);
        final shown = <String>[];
        await _runner(store, check: (_) async => false).run();
        final entered = Completer<void>();
        final result = Completer<bool>();
        final running = _runner(
          store,
          check: (_) {
            entered.complete();
            return result.future;
          },
          shown: shown,
        ).run();
        await entered.future;
        store.config = NotificationConfig(
          rooms: resubscribe ? [_room('a', generation: 'new')] : [],
        );
        result.complete(true);
        await running;
        await _runner(store, check: (_) async => true, shown: shown).run();
        expect(shown, isEmpty);
        if (!resubscribe) {
          expect((await store.readState())['rooms'], isEmpty);
        }
      });
    }

    test('opt-out after persisting a transition still prevents delivery',
        () async {
      final room = _room('a');
      final store = _MemoryStore([room]);
      final shown = <String>[];
      await _runner(store, check: (_) async => false).run();
      store.afterWrite = () async {
        store.config = const NotificationConfig();
      };
      await _runner(store, check: (_) async => true, shown: shown).run();
      expect(shown, isEmpty);
    });

    test('opt-out while native delivery is pending cancels that alert',
        () async {
      final room = _room('a');
      final store = _MemoryStore([room]);
      final shown = <String>[];
      final cancelled = <String>[];
      await _runner(store, check: (_) async => false).run();
      final entered = Completer<void>();
      final delivered = Completer<void>();
      final running = _runner(
        store,
        check: (_) async => true,
        show: (room) async {
          shown.add(room.id);
          entered.complete();
          await delivered.future;
        },
        cancelled: cancelled,
      ).run();
      await entered.future;
      store.config = const NotificationConfig();
      delivered.complete();
      await running;
      expect(shown, [room.id]);
      expect(cancelled, [room.id]);
    });

    test('room failures and transitions remain independent', () async {
      final rooms = [_room('a'), _room('b'), _room('c')];
      final store = _MemoryStore(rooms);
      final shown = <String>[];
      await _runner(store, check: (room) async => room.roomId == 'c').run();
      final checked = <String>[];
      await _runner(
        store,
        check: (room) async {
          checked.add(room.id);
          if (room.roomId == 'a') throw const SocketException('unavailable');
          return true;
        },
        shown: shown,
      ).run();
      expect(checked, rooms.map((room) => room.id));
      expect(shown, [rooms[1].id]);
      final states = (await store.readState())['rooms'] as Map;
      expect(states[rooms[0].id]['live'], isFalse);
      expect(states[rooms[1].id]['live'], isTrue);
      expect(states[rooms[2].id]['live'], isTrue);
    });

    test('a timed-out room does not prevent the next room being checked',
        () async {
      final rooms = [_room('a'), _room('b')];
      final store = _MemoryStore(rooms);
      await _runner(store, check: (_) async => false).run();
      final shown = <String>[];
      final neverCompletes = Completer<bool>();
      await _runner(
        store,
        check: (room) => room.roomId == 'a'
            ? neverCompletes.future
            : Future<bool>.value(true),
        shown: shown,
        roomTimeout: const Duration(milliseconds: 10),
      ).run().timeout(const Duration(seconds: 2));
      expect(shown, [rooms[1].id]);
      expect((await store.readState())['rooms'][rooms[0].id]['live'], isFalse);
    });

    test('the total budget bounds a slow request and rotates the next run',
        () async {
      final rooms = [_room('a'), _room('b'), _room('c')];
      final store = _MemoryStore(rooms);
      final checked = <String>[];
      final neverCompletes = Completer<bool>();
      await _runner(
        store,
        check: (room) {
          checked.add(room.id);
          return neverCompletes.future;
        },
        roomTimeout: const Duration(minutes: 1),
        budget: const Duration(milliseconds: 100),
      ).run().timeout(const Duration(seconds: 2));
      expect(checked, [rooms[0].id]);
      checked.clear();
      await _runner(
        store,
        check: (room) async {
          checked.add(room.id);
          return false;
        },
      ).run();
      expect(checked, [rooms[1].id, rooms[2].id, rooms[0].id]);
    });
  });

  group('FileNotificationStore', () {
    test('a new worker retains the baseline and already-delivered transitions',
        () async {
      final directory = await _temporaryDirectory();
      final room = _room('a');
      final initial = FileNotificationStore(directory);
      await initial.writeConfig(NotificationConfig(rooms: [room]));
      await _runner(initial, check: (_) async => false).run();
      final shown = <String>[];
      await _runner(FileNotificationStore(directory),
              check: (_) async => true, shown: shown)
          .run();
      expect(shown, [room.id]);
      await _runner(FileNotificationStore(directory),
              check: (_) async => true, shown: shown)
          .run();
      expect(shown, [room.id]);
    });

    test('readers ignore partially written snapshots until replacement',
        () async {
      final directory = await _temporaryDirectory();
      final writer = FileNotificationStore(directory);
      final reader = FileNotificationStore(directory);
      final old = NotificationConfig(
        rooms: [_room('old')],
        bilibiliCookie: 'old cookie',
        douyinCookie: 'old second cookie',
      );
      final next = NotificationConfig(
        rooms: [_room('new', generation: 'new generation')],
        bilibiliCookie: 'new cookie',
        douyinCookie: 'new second cookie',
      );
      await writer.writeConfig(old);
      await writer.writeState({'rooms': {}, 'cursor': 'old cursor'});
      await File('${directory.path}/subscriptions.json.tmp')
          .writeAsString('{"rooms":[');
      await File('${directory.path}/state.json.tmp').writeAsString('{"rooms":');
      expect((await reader.readConfig()).toJson(), old.toJson());
      expect(await reader.readState(), {'rooms': {}, 'cursor': 'old cursor'});
      await writer.writeConfig(next);
      await writer.writeState({'rooms': {}, 'cursor': 'new cursor'});
      expect((await reader.readConfig()).toJson(), next.toJson());
      expect(await reader.readState(), {'rooms': {}, 'cursor': 'new cursor'});
    });
  });
}
