import 'dart:async';

import 'package:simple_live_core/src/common/status_refresh.dart';
import 'package:simple_live_core/src/model/live_room_status.dart';
import 'package:test/test.dart';

void main() {
  test('concurrent refreshes share one bounded round', () async {
    final queue = StatusRefreshQueue();
    var active = 0;
    var peak = 0;
    var calls = 0;
    final gates = List.generate(20, (_) => Completer<void>());
    Future<void> task() async {
      final index = calls++;
      active++;
      if (active > peak) peak = active;
      await gates[index].future;
      active--;
    }

    final first = queue.run(List.generate(20, (_) => task));
    final duplicates = List.generate(20, (_) => queue.run([task]));
    expect(duplicates.every((future) => identical(first, future)), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 4);
    for (final gate in gates) {
      gate.complete();
      await Future<void>.delayed(Duration.zero);
    }
    await first;
    expect(calls, 20);
    expect(peak, 4);
    expect(queue.isRunning, isFalse);
  });

  test(
    'watch cap affects new admission while existing requests drain',
    () async {
      final queue = StatusRefreshQueue();
      final gates = List.generate(8, (_) => Completer<void>());
      var calls = 0;
      final round = queue.run(
        List.generate(
          8,
          (_) => () async {
            await gates[calls++].future;
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 4);
      queue.concurrency = 2;
      gates[0].complete();
      gates[1].complete();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 4);
      gates[2].complete();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 5);
      for (final gate in gates.skip(3)) {
        gate.complete();
        await Future<void>.delayed(Duration.zero);
      }
      await round;
    },
  );

  test(
    'cancel discards unstarted tasks and failure does not wedge next round',
    () async {
      final queue = StatusRefreshQueue()..concurrency = 1;
      final gate = Completer<void>();
      var calls = 0;
      final round = queue.run([
        () async {
          calls++;
          await gate.future;
          throw StateError('request failed');
        },
        () async => calls++,
      ]);
      final failure = expectLater(round, throwsStateError);
      queue.cancel();
      gate.complete();
      await failure;
      expect(calls, 1);
      expect(queue.isRunning, isFalse);
      await queue.run([() async => calls++]);
      expect(calls, 2);
    },
  );

  test(
    'pause retains pending tasks, accepts new work, and resumes one round',
    () async {
      final queue = StatusRefreshQueue()..concurrency = 1;
      final gate = Completer<void>();
      final calls = <int>[];
      final round = queue.run([
        () async {
          calls.add(1);
          await gate.future;
        },
        () async {
          calls.add(2);
        },
      ]);
      queue.pause();
      queue.add([
        () async {
          calls.add(3);
        },
      ]);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(calls, [1]);
      expect(queue.isRunning, isTrue);
      queue.resume();
      await round;
      expect(calls, [1, 2, 3]);
    },
  );

  test(
    'automatic status cache expires, manual refresh joins in flight',
    () async {
      var now = DateTime(2026);
      final cache = LiveRoomStatusCache(now: () => now);
      var calls = 0;
      final gate = Completer<LiveRoomStatus>();
      Future<LiveRoomStatus> load() {
        calls++;
        return gate.future;
      }

      final automatic = cache.get('room', 0, load, automatic: true);
      final manual = cache.get('room', 0, load);
      expect(identical(automatic, manual), isTrue);
      gate.complete(const LiveRoomStatus(live: true, showTime: '100'));
      await automatic;
      await cache.get('room', 0, load, automatic: true);
      expect(calls, 1);
      await cache.get('room', 0, load);
      expect(calls, 2);
      now = now.add(const Duration(seconds: 31));
      await cache.get('room', 0, load, automatic: true);
      expect(calls, 3);
      await cache.get('room', 1, load, automatic: true);
      expect(calls, 4);
    },
  );

  test('old account completion cannot repopulate invalidated cache', () async {
    final cache = LiveRoomStatusCache();
    final old = Completer<LiveRoomStatus>();
    final future = cache.get('room', 0, () => old.future);
    cache.clear();
    old.complete(const LiveRoomStatus(live: true));
    await future;
    final current = await cache.get(
      'room',
      0,
      () async => const LiveRoomStatus(live: false),
      automatic: true,
    );
    expect(current.live, isFalse);
  });
}
