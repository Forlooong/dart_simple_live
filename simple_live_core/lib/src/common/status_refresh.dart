import 'dart:async';
import 'dart:collection';

import '../model/live_room_status.dart';

/// Single-flight refresh with a dynamically adjustable admission limit.
/// Already admitted requests drain when the limit decreases or [pause] is used.
class StatusRefreshQueue {
  int _concurrency = 4;
  int get concurrency => _concurrency;
  set concurrency(int value) {
    _concurrency = value.clamp(1, 8);
    _pump?.call();
  }

  Future<void>? _running;
  Future<void>? get running => _running;
  bool get isRunning => _running != null;
  void Function()? _pump;
  Queue<Future<void> Function()>? _pending;

  bool _paused = false;

  /// Stop admission while retaining the current round's unstarted tasks.
  void pause() => _paused = true;

  void resume() {
    _paused = false;
    _pump?.call();
  }

  /// Discard unstarted tasks; already admitted requests still drain.
  void cancel() {
    _pending?.clear();
    _paused = false;
    _pump?.call();
  }

  /// Append members discovered during an active refresh.
  void add(Iterable<Future<void> Function()> tasks) {
    _pending?.addAll(tasks);
    _pump?.call();
  }

  Future<void> run(Iterable<Future<void> Function()> tasks) {
    if (_running != null) return _running!;
    final done = Completer<void>();
    _running = done.future;
    final pending = Queue<Future<void> Function()>.of(tasks);
    _pending = pending;
    var active = 0;
    Object? firstError;
    StackTrace? firstStack;
    void pump() {
      while (!_paused && active < _concurrency && pending.isNotEmpty) {
        final task = pending.removeFirst();
        active++;
        Future<void>.sync(task)
            .then(
              (_) {},
              onError: (Object e, StackTrace s) {
                firstError ??= e;
                firstStack ??= s;
              },
            )
            .whenComplete(() {
              active--;
              pump();
            });
      }
      if (active == 0 && pending.isEmpty && !done.isCompleted) {
        _running = null;
        _pending = null;
        _pump = null;
        if (firstError == null) {
          done.complete();
        } else {
          done.completeError(firstError!, firstStack);
        }
      }
    }

    _pump = pump;
    pump();
    return done.future;
  }
}

/// Bounded per-isolate request deduplication; does not coordinate OS workers.
class LiveRoomStatusCache {
  LiveRoomStatusCache({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _pending = <(String, int), Future<LiveRoomStatus>>{};
  final _values = <(String, int), (DateTime, LiveRoomStatus)>{};
  var _generation = 0;

  void clear() {
    _generation++;
    _values.clear();
    _pending.clear();
  }

  Future<LiveRoomStatus> get(
    String roomId,
    int configurationVersion,
    Future<LiveRoomStatus> Function() load, {
    bool automatic = false,
  }) {
    final key = (roomId, configurationVersion);
    final pending = _pending[key];
    if (pending != null) return pending;
    final cached = _values[key];
    if (automatic &&
        cached != null &&
        _now().difference(cached.$1) < const Duration(seconds: 30)) {
      return Future.value(cached.$2);
    }
    final generation = _generation;
    final done = Completer<LiveRoomStatus>();
    _pending[key] = done.future;
    Future<LiveRoomStatus>.sync(load).then(
      (status) {
        if (generation == _generation) {
          _values.remove(key);
          _values[key] = (_now(), status);
          while (_values.length > 512) {
            _values.remove(_values.keys.first);
          }
        }
        if (identical(_pending[key], done.future)) _pending.remove(key);
        done.complete(status);
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_pending[key], done.future)) _pending.remove(key);
        done.completeError(error, stack);
      },
    );
    return done.future;
  }
}
