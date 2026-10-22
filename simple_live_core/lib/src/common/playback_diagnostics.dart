import 'dart:collection';

enum PlaybackStage { room, quality, urls, open }

enum PlaybackTerminal { error, eof }

/// Passive, local-only playback observations. Never accepts source URLs,
/// headers, room IDs, error messages, or other provider-controlled text.
class PlaybackDiagnostics {
  PlaybackDiagnostics({Duration Function()? now}) {
    final stopwatch = Stopwatch()..start();
    _now = now ?? (() => stopwatch.elapsed);
  }

  static int _nextSession = 0;
  final int session = ++_nextSession;
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
  Duration? _bufferingSince;
  List<String>? _bufferingSummary;
  bool _firstProgress = false;

  Future<T> measure<T>(
    PlaybackStage stage,
    Future<T> Function() operation,
  ) async {
    final started = _now();
    if (!_closed) _record('stage=${stage.name} started attempt=$_opens');
    try {
      final result = await operation();
      if (!_closed) {
        _record(
          'stage=${stage.name} completed elapsed=${(_now() - started).inMilliseconds}ms',
        );
      }
      return result;
    } catch (_) {
      if (!_closed) {
        _record(
          'stage=${stage.name} failed elapsed=${(_now() - started).inMilliseconds}ms',
        );
      }
      rethrow;
    }
  }

  void terminal(PlaybackTerminal reason) {
    if (!_closed) _record('terminal=${reason.name} attempt=$_opens');
  }

  void _captureLongBuffering() {
    if (_bufferingSummary == null &&
        _bufferingSince != null &&
        _now() - _bufferingSince! >= const Duration(seconds: 15)) {
      _bufferingSummary = List.unmodifiable(_events);
    }
  }

  List<String> get events => List.unmodifiable(_events);

  void _record(String event) {
    _captureLongBuffering();
    _events.addLast('${_now().inMilliseconds}ms $event');
    while (_events.length > maxEvents) {
      _events.removeFirst();
    }
  }

  void opened() {
    if (_closed) return;
    _opens++;
    _firstProgress = false;
    _bufferingSince = null;
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
    _captureLongBuffering();
    _buffering = value;
    _bufferingSince = value ? _now() : null;
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
    if (!_firstProgress) {
      _firstProgress = true;
      _record('stage=firstProgress attempt=$_opens');
    }
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
    _captureLongBuffering();
    final elapsed = _lastProgress == null
        ? '尚未观察到连续推进'
        : '${((_closedAt ?? _now()) - _lastProgress!).inMilliseconds}ms';
    return [
      '播放状态（本地诊断，不代表故障判定）',
      '本地会话: $session',
      'playing: ${_playing ?? "未知"}',
      'buffering: ${_buffering ?? "未知"}',
      'position: ${_position?.inMilliseconds ?? "未知"}ms',
      '距上次播放时间推进: $elapsed',
      '本播放器打开次数: $_opens',
      '本播放器自动恢复尝试: $_recoveryAttempts',
      '最近事件（最多 $maxEvents 条，相对时间）:',
      ..._events,
      if (_bufferingSummary != null) ...[
        '持续缓冲摘要（首次观察到至少15秒，仅诊断，不触发恢复）:',
        ..._bufferingSummary!,
      ],
    ].join('\n');
  }
}
