import 'dart:collection';

/// Passive, local-only playback observations. Never accepts source URLs,
/// headers, room IDs, error messages, or other provider-controlled text.
class PlaybackDiagnostics {
  PlaybackDiagnostics({Duration Function()? now}) {
    final stopwatch = Stopwatch()..start();
    _now = now ?? (() => stopwatch.elapsed);
  }

  static const maxEvents = 32;
  static const progressEventInterval = Duration(seconds: 5);
  late final Duration Function() _now;
  final _events = ListQueue<String>();
  bool? _playing;
  bool? _buffering;
  Duration? _position;
  Duration? _lastProgress;
  Duration? _lastProgressEvent;
  int _opens = 0;
  int _recoveryAttempts = 0;
  bool _closed = false;
  Duration? _closedAt;

  List<String> get events => List.unmodifiable(_events);

  void _record(String event) {
    _events.addLast('${_now().inMilliseconds}ms $event');
    while (_events.length > maxEvents) {
      _events.removeFirst();
    }
  }

  void opened() {
    if (_closed) return;
    _opens++;
    _position = null;
    _lastProgress = null;
    _lastProgressEvent = null;
    _playing = null;
    _buffering = null;
    _record('open #$_opens');
  }

  void playing(bool value) {
    if (_closed || value == _playing) return;
    _playing = value;
    _record('playing=$value');
  }

  void buffering(bool value) {
    if (_closed || value == _buffering) return;
    _buffering = value;
    _record('buffering=$value');
  }

  void position(Duration value) {
    if (_closed) return;
    final previous = _position;
    _position = value;
    // An initial timestamp or a seek/discontinuity backwards does not prove
    // that playback is advancing. Do not label it a stall either.
    if (previous == null || value <= previous) return;
    final now = _now();
    _lastProgress = now;
    if (_lastProgressEvent == null ||
        now - _lastProgressEvent! >= progressEventInterval) {
      _lastProgressEvent = now;
      _record('progress=${value.inMilliseconds}ms');
    }
  }

  void recoveryAttempt() {
    if (_closed) return;
    _recoveryAttempts++;
    _record('recovery #$_recoveryAttempts');
  }

  void close() {
    if (_closed) return;
    _closedAt = _now();
    _record('closed');
    _closed = true;
  }

  /// All fields are allowlisted local numbers, booleans, or fixed labels.
  /// Time is monotonic time since this player was created, not wall-clock time.
  String snapshot() {
    final elapsed = _lastProgress == null
        ? '尚未观察到连续推进'
        : '${((_closedAt ?? _now()) - _lastProgress!).inMilliseconds}ms';
    return [
      '播放状态（本地诊断，不代表故障判定）',
      'playing: ${_playing ?? "未知"}',
      'buffering: ${_buffering ?? "未知"}',
      'position: ${_position?.inMilliseconds ?? "未知"}ms',
      '距上次播放时间推进: $elapsed',
      '本播放器打开次数: $_opens',
      '本播放器自动恢复尝试: $_recoveryAttempts',
      '最近事件（最多 $maxEvents 条，相对时间）:',
      ..._events,
    ].join('\n');
  }
}
