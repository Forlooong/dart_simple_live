import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/player/player_command_queue.dart';

void main() {
  test('commands run one at a time, in submission order', () async {
    final queue = PlayerCommandQueue();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final events = <String>[];

    final first = queue.run(() async {
      events.add('first start');
      firstStarted.complete();
      await releaseFirst.future;
      events.add('first end');
    });
    final second = queue.run(() async => events.add('second'));
    await firstStarted.future;
    expect(events, ['first start']);

    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(events, ['first start', 'first end', 'second']);
  });

  test(
    'close skips pending and future commands and waits for active work',
    () async {
      final queue = PlayerCommandQueue();
      final started = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];

      final running = queue.run(() async {
        events.add('running');
        started.complete();
        await release.future;
        events.add('finished');
      });
      await started.future;
      final pending = queue.run(() async => events.add('stale'));
      final closed = queue.close(() async => events.add('disposed'));
      expect(queue.isClosing, isTrue);
      await queue.run(() async => events.add('after close'));
      expect(events, ['running']);

      release.complete();
      await Future.wait([running, pending, closed]);
      expect(events, ['running', 'finished', 'disposed']);
    },
  );

  test('close before a command starts prevents its execution', () async {
    final queue = PlayerCommandQueue();
    var executed = false;
    final pending = queue.run(() async => executed = true);
    await queue.close(() async {});
    await pending;
    expect(executed, isFalse);
  });

  test(
    'synchronous close guard also rejects commands during UI cleanup',
    () async {
      final queue = PlayerCommandQueue();
      var executed = false;
      queue.stopAcceptingCommands();
      expect(queue.isClosing, isTrue);
      await queue.run(() async => executed = true);
      await queue.close(() async {});
      expect(executed, isFalse);
    },
  );

  test('close is idempotent and returns the same disposal future', () async {
    final queue = PlayerCommandQueue();
    var disposals = 0;
    final first = queue.close(() async => disposals++);
    final second = queue.close(() async => disposals++);
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(disposals, 1);
  });

  test(
    'failed commands remain observable but do not poison later commands',
    () async {
      final errors = <Object>[];
      final queue = PlayerCommandQueue(
        onError: (error, _) => errors.add(error),
      );
      final error = StateError('native command failed');
      var nextExecuted = false;
      final failed = queue.run(() => throw error);
      final next = queue.run(() async => nextExecuted = true);

      await expectLater(failed, throwsA(same(error)));
      await next;
      expect(nextExecuted, isTrue);
      expect(errors, [error]);
    },
  );

  test('failed active command still permits disposal', () async {
    final queue = PlayerCommandQueue();
    final started = Completer<void>();
    final release = Completer<void>();
    final error = StateError('open failed');
    var disposed = false;
    final failed = queue.run(() async {
      started.complete();
      await release.future;
      throw error;
    });
    final failureExpectation = expectLater(failed, throwsA(same(error)));
    await started.future;
    final closed = queue.close(() async => disposed = true);
    release.complete();
    await failureExpectation;
    await closed;
    expect(disposed, isTrue);
  });

  test('fire-and-forget command failures are observed', () async {
    final errors = <Object>[];
    final queue = PlayerCommandQueue(onError: (error, _) => errors.add(error));
    final error = StateError('volume failed');
    unawaited(queue.run(() async => throw error));
    await queue.run(() async {});
    expect(errors, [error]);
  });

  test('a failed error reporter cannot block cleanup', () async {
    final queue = PlayerCommandQueue(
      onError: (_, __) {
        throw StateError('logger failed');
      },
    );
    final error = StateError('native command failed');
    final failed = queue.run(() async => throw error);
    await expectLater(failed, throwsA(same(error)));
    var disposed = false;
    await queue.close(() async => disposed = true);
    expect(disposed, isTrue);
  });

  test(
    'a disposal failure is reported once without allowing a retry',
    () async {
      final errors = <Object>[];
      final queue = PlayerCommandQueue(
        onError: (error, _) => errors.add(error),
      );
      final error = StateError('dispose failed');
      var disposals = 0;
      final closed = queue.close(() async {
        disposals++;
        throw error;
      });
      await expectLater(closed, throwsA(same(error)));
      expect(identical(queue.close(() async => disposals++), closed), isTrue);
      expect(disposals, 1);
      expect(errors, [error]);
    },
  );

  test('different players are not blocked by another player cleanup', () async {
    final first = PlayerCommandQueue();
    final second = PlayerCommandQueue();
    final release = Completer<void>();
    final closed = first.close(() => release.future);
    var executed = false;
    await second.run(() async => executed = true);
    expect(executed, isTrue);
    release.complete();
    await closed;
  });
}
