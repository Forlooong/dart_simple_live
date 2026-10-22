import 'package:dio/dio.dart';

import 'core_log.dart';

/// Only fixed transport metadata enters logs. Headers, paths, query values,
/// bodies, redirects and raw exception messages can all contain credentials.
class CustomInterceptor extends Interceptor {
  String _endpoint(RequestOptions options) {
    final uri = options.uri;
    return '${uri.scheme}://${uri.host}:${uri.port}';
  }

  int _elapsed(RequestOptions options) =>
      (options.extra['core.requestClock'] as Stopwatch?)?.elapsedMilliseconds ??
      0;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra['core.requestClock'] = Stopwatch()..start();
    if (CoreLog.requestLogType != RequestLogType.none) {
      CoreLog.i('[HTTP Request] [${options.method}] ${_endpoint(options)}');
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (CoreLog.requestLogType != RequestLogType.none) {
      CoreLog.e(
        '[HTTP Error] [${err.type.name}] [${err.response?.statusCode}] '
        '[${_elapsed(err.requestOptions)}ms] ${_endpoint(err.requestOptions)}',
        StackTrace.empty,
      );
    }
    handler.next(err);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (CoreLog.requestLogType != RequestLogType.none) {
      CoreLog.i(
        '[HTTP Response] [${response.statusCode}] '
        '[${_elapsed(response.requestOptions)}ms] ${_endpoint(response.requestOptions)}',
      );
    }
    handler.next(response);
  }
}
