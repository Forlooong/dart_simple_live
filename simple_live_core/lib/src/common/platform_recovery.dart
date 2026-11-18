import 'dart:async';
import 'dart:io';

import 'core_error.dart';
import 'request_context.dart';

/// One instance per operation. A failure for one site never gates another.
class PlatformRecovery {
  PlatformRecovery({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _failures =
      <
        String,
        ({CoreErrorKind kind, int count, DateTime? retryAt, int version})
      >{};

  CoreErrorKind? blocked(String site, int version) {
    final failure = _failures[site];
    if (failure == null) return null;
    if (failure.version != version) {
      _failures.remove(site);
      return null;
    }
    if (failure.kind == CoreErrorKind.authRequired) return failure.kind;
    final retry = failure.retryAt;
    return retry != null && _now().isBefore(retry) ? failure.kind : null;
  }

  void succeeded(String site) => _failures.remove(site);

  static CoreErrorKind classify(Object error) => switch (error) {
    CoreError error => error.kind,
    TimeoutException() => CoreErrorKind.timeout,
    SocketException() => CoreErrorKind.transport,
    FormatException() || TypeError() => CoreErrorKind.schemaChanged,
    _ => CoreErrorKind.unknown,
  };

  void failed(String site, int version, Object error) {
    final kind = classify(error);
    final initial = switch (kind) {
      CoreErrorKind.transport || CoreErrorKind.timeout => 30,
      CoreErrorKind.rateLimited => 60,
      CoreErrorKind.authRequired => 0,
      _ => null,
    };
    if (initial == null) return;
    final old = _failures[site];
    // Concurrent failures in the same cooldown count as one failed attempt.
    if (blocked(site, version) == kind) return;
    final count = old != null && old.kind == kind && old.version == version
        ? (old.count + 1).clamp(1, 5)
        : 1;
    final now = _now();
    final retryAfter = error is CoreError ? error.retryAfter : null;
    final retryAt = initial == 0
        ? null
        : now.add(
            kind == CoreErrorKind.rateLimited && retryAfter != null
                ? retryAfter
                : Duration(
                    seconds: (initial * (1 << (count - 1))).clamp(0, 300),
                  ),
          );
    _failures[site] = (
      kind: kind,
      count: count,
      retryAt: retryAt,
      version: version,
    );
  }

  void restore(String site, Map data, {int version = 0}) {
    final name = data['kind'];
    final count = data['count'];
    final retryAt = data['retryAt'];
    final matching = CoreErrorKind.values.where((value) => value.name == name);
    if (matching.isEmpty ||
        count is! int ||
        count < 1 ||
        (data['version'] ?? 0) != version)
      return;
    final kind = matching.first;
    final retry = retryAt is String ? DateTime.tryParse(retryAt) : null;
    if (retry != null || kind == CoreErrorKind.authRequired)
      _failures[site] = (
        kind: kind,
        count: count,
        retryAt: retry,
        version: version,
      );
  }

  Map<String, dynamic>? snapshot(String site) {
    final failure = _failures[site];
    if (failure == null) return null;
    return {
      'kind': failure.kind.name,
      'count': failure.count,
      'version': failure.version,
      'retryAt': failure.retryAt?.toUtc().toIso8601String(),
    };
  }

  void networkRestored() => _failures.removeWhere(
    (_, failure) =>
        failure.kind == CoreErrorKind.transport ||
        failure.kind == CoreErrorKind.timeout,
  );

  Future<T> run<T>(
    String site,
    int version,
    Future<T> Function() request, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final gate = blocked(site, version);
    if (gate != null) throw CoreError('平台暂不可用', kind: gate);
    final context = RequestContext(timeout: timeout);
    try {
      final result = await context.run(request).timeout(timeout);
      succeeded(site);
      return result;
    } catch (error) {
      context.cancel();
      failed(site, version, error);
      rethrow;
    }
  }
}
