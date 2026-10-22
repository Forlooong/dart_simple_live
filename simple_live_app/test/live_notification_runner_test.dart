import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
  Future<void> Function()? beforeReadConfig;

  @override
  Future<NotificationConfig> readConfig() async {
    await beforeReadConfig?.call();
    return NotificationConfig.fromJson(config.toJson());
  }

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
  Stopwatch Function()? createStopwatch,
}) =>
    LiveCheckRunner(
      store: store,
      check: check,
      show: show ?? (room) async => shown?.add(room.id),
      cancel: (room) async => cancelled?.add(room.id),
      roomTimeout: roomTimeout,
      budget: budget,
      createStopwatch: createStopwatch,
    );

// Drive elapsed time separately from Flutter's fake timers to reproduce a
// budget timer firing while the monotonic clock still reads just below it.
class _ManualStopwatch implements Stopwatch {
  @override
  Duration elapsed = Duration.zero;
  @override
  bool isRunning = false;
  @override
  int get elapsedMicroseconds => elapsed.inMicroseconds;
  @override
  int get elapsedMilliseconds => elapsed.inMilliseconds;
  @override
  int get elapsedTicks => elapsedMicroseconds;
  @override
  int get frequency => Duration.microsecondsPerSecond;
  @override
  void start() => isRunning = true;
  @override
  void stop() => isRunning = false;
  @override
  void reset() => elapsed = Duration.zero;
}

Future<Directory> _temporaryDirectory() async {
  final directory =
      await Directory.systemTemp.createTemp('simple-live-notifications-');
  addTearDown(() async {
    await directory.delete(recursive: true);
  });
  return directory;
}

void main() {
  setUp(() { FlutterSecureStorage.setMockInitialValues({}); });
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

    testWidgets('a room timeout continues without applying its late result',
        (tester) async {
      final rooms = [_room('a'), _room('b')];
      final store = _MemoryStore(rooms);
      await _runner(store, check: (_) async => false).run();
      final shown = <String>[];
      final lateResult = Completer<bool>();
      var finished = false;
      final running = _runner(
        store,
        check: (room) => room.roomId == 'a'
            ? lateResult.future
            : Future<bool>.value(true),
        shown: shown,
        roomTimeout: const Duration(milliseconds: 10),
        createStopwatch: _ManualStopwatch.new,
      ).run().then((_) => finished = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(finished, isTrue);
      await running;
      expect(shown, [rooms[1].id]);
      final timedOutState = await store.readState();
      expect(timedOutState['rooms'][rooms[0].id]['live'], isFalse);
      lateResult.complete(true);
      await tester.pump();
      expect(await store.readState(), timedOutState);
      expect(shown, [rooms[1].id]);
    });

    for (final roomTimeout in [
      const Duration(milliseconds: 100),
      const Duration(minutes: 1),
    ]) {
      testWidgets(
          'a budget timeout stops and rotates even when elapsed reads low '
          '($roomTimeout)', (tester) async {
        final rooms = [_room('a'), _room('b'), _room('c')];
        final store = _MemoryStore(rooms);
        await _runner(store, check: (_) async => false).run();
        final checked = <String>[];
        final shown = <String>[];
        final lateResult = Completer<bool>();
        final stopwatch = _ManualStopwatch();
        var finished = false;
        final running = _runner(
          store,
          check: (room) {
            checked.add(room.id);
            return lateResult.future;
          },
          shown: shown,
          roomTimeout: roomTimeout,
          budget: const Duration(milliseconds: 100),
          createStopwatch: () => stopwatch,
        ).run().then((_) => finished = true);
        await tester.pump();
        stopwatch.elapsed = const Duration(microseconds: 99999);
        await tester.pump(const Duration(milliseconds: 100));
        expect(finished, isTrue);
        await running;
        expect(checked, [rooms[0].id]);
        final timedOutState = await store.readState();
        expect(timedOutState['cursor'], rooms[0].id);
        lateResult.complete(true);
        await tester.pump();
        expect(await store.readState(), timedOutState);
        expect(shown, isEmpty);
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
    }

    testWidgets('a result at the deadline is discarded before state or alerts',
        (tester) async {
      final rooms = [_room('a'), _room('b')];
      final store = _MemoryStore(rooms);
      await _runner(store, check: (_) async => false).run();
      final checked = <String>[];
      final shown = <String>[];
      final result = Completer<bool>();
      final stopwatch = _ManualStopwatch();
      final running = _runner(
        store,
        check: (room) {
          checked.add(room.id);
          return result.future;
        },
        shown: shown,
        budget: const Duration(milliseconds: 100),
        createStopwatch: () => stopwatch,
      ).run();
      await tester.pump();
      stopwatch.elapsed = const Duration(milliseconds: 100);
      // Complete before the fake timer is dispatched: the elapsed deadline
      // still wins over a successful Future.
      result.complete(true);
      await tester.pump();
      await running;
      expect(checked, [rooms[0].id]);
      expect(shown, isEmpty);
      expect((await store.readState())['rooms'][rooms[0].id]['live'], isFalse);
    });

    for (final slowRead in [1, 2, 3, 4]) {
      test('config read $slowRead cannot start work beyond the budget', () async {
        final room = _room('a');
        final store = _MemoryStore([room]);
        await _runner(store, check: (_) async => false).run();
        final stopwatch = _ManualStopwatch();
        var reads = 0;
        store.beforeReadConfig = () async {
          if (++reads == slowRead) {
            stopwatch.elapsed = const Duration(milliseconds: 100);
          }
        };
        final checked = <String>[];
        final shown = <String>[];
        await _runner(
          store,
          check: (room) async {
            checked.add(room.id);
            return true;
          },
          shown: shown,
          budget: const Duration(milliseconds: 100),
          createStopwatch: () => stopwatch,
        ).run();
        expect(checked, slowRead <= 2 ? isEmpty : [room.id]);
        expect(shown, isEmpty);
        expect((await store.readState())['rooms'][room.id]['live'], slowRead == 4);
      });
    }

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
      expect(await File('${directory.path}/subscriptions.json').readAsString(),
          isNot(contains('cookie')));
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
