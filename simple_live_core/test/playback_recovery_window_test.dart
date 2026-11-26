import 'package:simple_live_core/src/common/playback_recovery_window.dart';
import 'package:test/test.dart';

void main() {
  test('only attempts outside the five minute window expire', () {
    var now = Duration.zero;
    final window = PlaybackRecoveryWindow(now: () => now);
    for (var index = 0; index < 6; index++) {
      now = Duration(seconds: index * 10);
      expect(window.tryStart(), isTrue);
    }

    now = const Duration(minutes: 5) - const Duration(milliseconds: 1);
    expect(window.tryStart(), isFalse);
    now = const Duration(minutes: 5);
    expect(window.tryStart(), isTrue);
    expect(window.tryStart(), isFalse);

    window.reset();
    expect(window.tryStart(), isTrue);
  });
}
