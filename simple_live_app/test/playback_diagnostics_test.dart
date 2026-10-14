import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/player/playback_diagnostics.dart';

void main() {
  late Duration now;
  late PlaybackDiagnostics diagnostics;

  setUp(() {
    now = Duration.zero;
    diagnostics = PlaybackDiagnostics(now: () => now);
  });

  test('uninitialized and first timestamps do not claim playback progress', () {
    expect(diagnostics.snapshot(), contains('尚未观察到连续推进'));
    diagnostics.opened();
    diagnostics.position(const Duration(seconds: 1200));
    expect(diagnostics.snapshot(), contains('尚未观察到连续推进'));
    now = const Duration(seconds: 1);
    diagnostics.position(const Duration(seconds: 1201));
    expect(diagnostics.snapshot(), contains('距上次播放时间推进: 0ms'));
  });

  test(
    'stale buffering flag and advancing position remain distinct signals',
    () {
      diagnostics.opened();
      diagnostics.playing(true);
      diagnostics.buffering(true);
      diagnostics.position(Duration.zero);
      now = const Duration(seconds: 1);
      diagnostics.position(const Duration(seconds: 1));
      now = const Duration(seconds: 2);

      expect(diagnostics.snapshot(), contains('buffering: true'));
      expect(diagnostics.snapshot(), contains('playing: true'));
      expect(diagnostics.snapshot(), contains('距上次播放时间推进: 1000ms'));
      expect(diagnostics.snapshot(), contains('本播放器自动恢复尝试: 0'));
    },
  );

  test(
    'progress events are coalesced without losing last observed progress',
    () {
      diagnostics.position(Duration.zero);
      for (var second = 1; second <= 12; second++) {
        now = Duration(seconds: second);
        diagnostics.position(now);
      }
      expect(
        diagnostics.events.where((event) => event.contains('progress=')),
        hasLength(3),
      );
      expect(diagnostics.snapshot(), contains('position: 12000ms'));
      expect(diagnostics.snapshot(), contains('距上次播放时间推进: 0ms'));
    },
  );

  test('repeated states do not fill the bounded history', () {
    for (var i = 0; i < 100; i++) {
      diagnostics.buffering(true);
      diagnostics.playing(true);
    }
    expect(diagnostics.events, hasLength(2));
    for (var i = 0; i < 100; i++) {
      now = Duration(milliseconds: i);
      diagnostics.buffering(i.isEven);
    }
    expect(diagnostics.events, hasLength(PlaybackDiagnostics.maxEvents));
    expect(diagnostics.events.last, '99ms buffering=false');
    expect(() => diagnostics.events.clear(), throwsUnsupportedError);
  });

  test('new open resets progress without changing recovery totals', () {
    diagnostics.opened();
    diagnostics.position(Duration.zero);
    diagnostics.position(const Duration(seconds: 1));
    diagnostics.recoveryAttempt();
    diagnostics.opened();
    expect(diagnostics.snapshot(), contains('尚未观察到连续推进'));
    expect(diagnostics.snapshot(), contains('buffering: 未知'));
    expect(diagnostics.snapshot(), contains('本播放器打开次数: 2'));
    expect(diagnostics.snapshot(), contains('本播放器自动恢复尝试: 1'));
  });

  test(
    'closed player ignores late events and cannot contaminate next player',
    () {
      diagnostics.opened();
      diagnostics.position(Duration.zero);
      now = const Duration(seconds: 1);
      diagnostics.position(const Duration(seconds: 1));
      diagnostics.close();
      final closed = diagnostics.snapshot();
      now = const Duration(seconds: 30);
      diagnostics.playing(true);
      diagnostics.buffering(true);
      diagnostics.position(const Duration(seconds: 2));
      diagnostics.opened();
      diagnostics.recoveryAttempt();
      expect(diagnostics.snapshot(), closed);
      final next = PlaybackDiagnostics(now: () => now);
      expect(next.events, isEmpty);
      expect(next.snapshot(), contains('本播放器自动恢复尝试: 0'));
    },
  );

  test('summary contains only local fixed labels and typed numeric data', () {
    diagnostics.opened();
    diagnostics.playing(true);
    diagnostics.buffering(false);
    diagnostics.position(Duration.zero);
    diagnostics.recoveryAttempt();
    final summary = diagnostics.snapshot();
    for (final sensitive in [
      'https://',
      'http://',
      'token',
      'Referer',
      'roomId',
    ]) {
      expect(summary, isNot(contains(sensitive)));
    }
    expect(summary, contains('不代表故障判定'));
  });
}
