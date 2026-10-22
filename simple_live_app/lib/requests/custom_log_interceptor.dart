import 'package:dio/dio.dart';
import 'package:simple_live_app/app/log.dart';

class CustomLogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra['logStarted'] = Stopwatch()..start();
    super.onRequest(options, handler);
  }

  String _metadata(RequestOptions options, int? status) {
    final elapsed =
        (options.extra['logStarted'] as Stopwatch?)?.elapsedMilliseconds;
    // Paths, query strings, headers and bodies may contain credentials.
    return '${options.method} ${options.uri.host} status=$status elapsed=${elapsed}ms';
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    Log.w(
      '[HTTP ${err.type.name}] ${_metadata(err.requestOptions, err.response?.statusCode)}',
    );
    super.onError(err, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    Log.i('[HTTP] ${_metadata(response.requestOptions, response.statusCode)}');
    super.onResponse(response, handler);
  }
}
