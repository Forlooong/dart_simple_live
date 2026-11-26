import 'dart:collection';

/// Limits automatic recovery attempts even when each replacement briefly plays.
class PlaybackRecoveryWindow {
  PlaybackRecoveryWindow({Duration Function()? now})
    : _now = now ?? _monotonicClock();

  static const _interval = Duration(minutes: 5);
  static const _maxAttempts = 6;
  final Duration Function() _now;
  final _attempts = Queue<Duration>();

  static Duration Function() _monotonicClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  bool tryStart() {
    final now = _now();
    final cutoff = now - _interval;
    while (_attempts.isNotEmpty && _attempts.first <= cutoff) {
      _attempts.removeFirst();
    }
    if (_attempts.length >= _maxAttempts) return false;
    _attempts.addLast(now);
    return true;
  }

  void reset() => _attempts.clear();
}
