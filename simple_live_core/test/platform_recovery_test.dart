import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  test('backoff is isolated by site and credentials revision', () {
    var now = DateTime.utc(2026);
    final policy = PlatformRecovery(now: () => now);
    CoreError timeout() => CoreError('timeout', kind: CoreErrorKind.timeout);
    policy.failed('douyu', 0, timeout());
    policy.failed('douyu', 0, timeout());
    expect(policy.blocked('douyu', 0), CoreErrorKind.timeout);
    expect(policy.blocked('huya', 0), isNull);
    now = now.add(const Duration(seconds: 30));
    expect(policy.blocked('douyu', 0), isNull);
    policy.failed('douyu', 0, timeout());
    now = now.add(const Duration(seconds: 59));
    expect(policy.blocked('douyu', 0), CoreErrorKind.timeout);
    policy.networkRestored();
    expect(policy.blocked('douyu', 0), isNull);
    policy.failed(
      'bilibili',
      0,
      CoreError('expired', kind: CoreErrorKind.authRequired),
    );
    expect(policy.blocked('bilibili', 0), CoreErrorKind.authRequired);
    expect(policy.blocked('bilibili', 1), isNull);
  });

  test('Retry-After takes precedence and survives a worker restart', () {
    var now = DateTime.utc(2026);
    final previous = PlatformRecovery(now: () => now);
    previous.failed(
      'douyin',
      0,
      CoreError(
        'limited',
        kind: CoreErrorKind.rateLimited,
        retryAfter: const Duration(minutes: 12),
      ),
    );
    final restarted = PlatformRecovery(now: () => now)
      ..restore('douyin', previous.snapshot('douyin')!);
    now = now.add(const Duration(minutes: 11));
    expect(restarted.blocked('douyin', 0), CoreErrorKind.rateLimited);
    now = now.add(const Duration(minutes: 1));
    expect(restarted.blocked('douyin', 0), isNull);
  });
}
