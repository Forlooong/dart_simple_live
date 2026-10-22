import 'dart:async';

import 'package:dio/dio.dart';

import 'core_error.dart';

/// One playback attempt shares a real transport cancellation token and deadline.
class RequestContext {
  static final Object _zoneKey = Object();
  static RequestContext? get current =>
      Zone.current[_zoneKey] as RequestContext?;

  final CancelToken cancelToken = CancelToken();
  final Duration timeout;
  final Stopwatch _clock = Stopwatch()..start();
  late final Timer _timer;
  CoreError? _failure;

  RequestContext({this.timeout = const Duration(seconds: 30)}) {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    _timer = Timer(timeout, () {
      _failure = CoreError('请求超时', kind: CoreErrorKind.timeout);
      cancelToken.cancel(_failure);
    });
  }

  Duration get remaining => timeout - _clock.elapsed;
  bool get isCancelled => cancelToken.isCancelled;

  void cancel() {
    if (isCancelled) return;
    _failure = CoreError('请求已取消', kind: CoreErrorKind.cancelled);
    cancelToken.cancel(_failure);
    _timer.cancel();
  }

  void check() {
    if (_failure != null) throw _failure!;
    if (remaining <= Duration.zero) {
      _failure = CoreError('请求超时', kind: CoreErrorKind.timeout);
      cancelToken.cancel(_failure);
      throw _failure!;
    }
  }

  Future<T> run<T>(Future<T> Function() operation) async {
    try {
      check();
      final value = await runZoned(operation, zoneValues: {_zoneKey: this});
      check();
      return value;
    } catch (_) {
      if (_failure != null) throw _failure!;
      rethrow;
    } finally {
      _timer.cancel();
    }
  }
}
